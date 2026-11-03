class_name ArpgDungeon
extends RefCounted
## 随机地牢生成 v2：**BSP 分区 → 每片叶子放房间 → k 近邻图 + MST(+环路) → A* 走廊 → 距离分级**
##
## 为什么换掉旧算法（"随机撒矩形 + 按 x 排序连成链"）：
##  · 一条链 = 线性流程，玩家永远在"回头走同一条走廊"，没有环路、没有可选择的路线；
##  · 房间数写死 8、尺寸 5~9 × 4~7，每层长得几乎一样；
##  · 走廊是房间中心到中心的 L 形，常常一条长直道横穿整张图，节奏死板。
##
## 新算法分层（每层都能单独替换/调参）：
##  1. BSP：把地图递归二分成若干叶子（优先切长边、切点 38%~62% 随机），保证叶子能放下房间；
##  2. 房间：每片叶子里留 1 格墙的边距后随机摆一个房间（尺寸/位置都有抖动）；
##  3. 连通图：每个房间连最近的 3 个邻居 → Kruskal 求 MST（保证全连通、没有孤立房间），
##     再补 `CORRIDOR_EXTRA` 比例的次短边形成**环路**（少走回头路、多拉扯空间）；
##  4. 走廊：用 AStarGrid2D 在"代价网格"上找路（已有地板/贴墙/贴边都加代价），
##     走廊自然绕开房间、不贴地图边缘，2 格宽保证 8 人小队不堵门；
##  5. 分級：从起点做 BFS，房间按"可达距离"排序 → `rooms[0]` 永远是出发房间、
##     `rooms[-1]` 永远是最远房间（楼梯），叶节点房间标成宝箱房。
##
## 生成结果对旧调用方完全兼容：`w/h/grid/rooms/start_cell/boss_floor/is_floor/random_cell_in`。

enum { WALL = 0, FLOOR = 1 }
enum RoomKind { START = 0, NORMAL = 1, TREASURE = 2, STAIRS = 3 }

const MIN_LEAF := 10                 # BSP 叶子最小边长（房间 5~8 格 + 两侧留白）
const MIN_ROOM := Vector2i(5, 4)     # 房间最小尺寸
const MAX_ROOM := Vector2i(10, 8)    # 房间最大尺寸
const CORRIDOR_EXTRA := 0.30         # 额外环路比例（MST 之外再连的比例）
const KNN := 3                       # 每个房间先连最近的 k 个邻居
const BORDER_COST := 9.0             # 走廊贴地图边的代价（越大越靠内）
const ROOM_COST := 2.4               # 走廊穿过已有房间的代价

const _N4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var w := 0
var h := 0
var grid := []            # grid[x][y] -> WALL / FLOOR
var rooms := []           # [Rect2i]（按距起点距离升序：0 = 出发房，-1 = 最远房/楼梯房）
var room_kind := []       # 与 rooms 对齐：RoomKind
var start_cell := Vector2i.ZERO
var stair_cell := Vector2i(-1, -1)     # 楼梯格（最远房间中心）；Boss 层为 -1
var boss_floor := false
var rng := RandomNumberGenerator.new()

var _nav: AStarGrid2D
var _edges := []          # 最终走廊边 [[i, j], ...]（用于判定叶节点房间）
var _loot_cursor := 0


# ———————— 入口 ————————

func generate(floor: int, seed_val: int = -1) -> void:
	if seed_val >= 0:
		rng.seed = seed_val
	else:
		rng.randomize()
	boss_floor = floor >= ArpgBalance.MAX_FLOOR
	if boss_floor:
		w = 36
		h = 26
	else:
		# 越深越大一点：给"绕路/环路"留空间，也让每层的体感不一样
		var grow := mini(maxi(floor - 1, 0), 3)
		w = 44 + grow
		h = 32 + (grow / 2)
	_reset_grid()
	rooms = []
	room_kind = []
	_edges = []
	_loot_cursor = 0
	stair_cell = Vector2i(-1, -1)

	if boss_floor:
		# Boss 层保持"一间大房"：开阔、无走廊，方便 Boss 战与弹幕走位
		_add_room(Rect2i(5, 4, 26, 18), RoomKind.START)
		start_cell = Vector2i(8, 12)
		return

	_generate_rooms(floor)
	_build_pathfinder()
	_connect_rooms()
	_finalize_rooms()


func _reset_grid() -> void:
	grid = []
	for x in w:
		var col := []
		col.resize(h)
		col.fill(WALL)
		grid.append(col)


# ———————— 1) BSP 分区 + 房间 ————————

func _generate_rooms(floor: int) -> void:
	var target := clampi(7 + floor, 8, 12)
	var leaves := _bsp_split(target)
	for leaf in leaves:
		var r := _room_in_leaf(leaf)
		if r.size.x >= MIN_ROOM.x and r.size.y >= MIN_ROOM.y:
			_add_room(r, RoomKind.NORMAL)
	if rooms.size() < 5:
		# 保底：BSP 因随机切分退化时，退回"随机撒房间"（仍然走后面的 MST + A* 连通）
		_fallback_rooms(target)
	if rooms.is_empty():
		# 极端兜底：至少给一间房，避免后续 rooms[0] 崩
		_add_room(Rect2i(4, 4, 12, 9), RoomKind.START)
	start_cell = _center(rooms[0])


## 递归二分：每次优先切面积最大、且还切得动的叶子；切点限制在 38%~62%
func _bsp_split(target: int) -> Array:
	var leaves: Array = [Rect2i(1, 1, w - 2, h - 2)]
	var guard := 0
	while leaves.size() < target and guard < 400:
		guard += 1
		var idx := -1
		var best := -1.0
		for i in leaves.size():
			var r: Rect2i = leaves[i]
			if not _can_split(r):
				continue
			var area := float(r.size.x * r.size.y)
			if area > best:
				best = area
				idx = i
		if idx < 0:
			break
		var r2: Rect2i = leaves[idx]
		var vertical := r2.size.x >= r2.size.y
		if r2.size.x < MIN_LEAF * 2:
			vertical = false
		elif r2.size.y < MIN_LEAF * 2:
			vertical = true
		var span := r2.size.x if vertical else r2.size.y
		var cut_min := MIN_LEAF
		var cut_max := span - MIN_LEAF
		if cut_max <= cut_min:
			break
		var lo := cut_min + int(round(float(cut_max - cut_min) * 0.18))
		var hi := cut_max - int(round(float(cut_max - cut_min) * 0.18))
		var cut := rng.randi_range(maxi(lo, cut_min), maxi(hi, cut_min))
		if vertical:
			leaves[idx] = Rect2i(r2.position, Vector2i(cut, r2.size.y))
			leaves.append(Rect2i(r2.position + Vector2i(cut, 0),
				Vector2i(r2.size.x - cut, r2.size.y)))
		else:
			leaves[idx] = Rect2i(r2.position, Vector2i(r2.size.x, cut))
			leaves.append(Rect2i(r2.position + Vector2i(0, cut),
				Vector2i(r2.size.x, r2.size.y - cut)))
	return leaves


func _can_split(r: Rect2i) -> bool:
	return r.size.x >= MIN_LEAF * 2 or r.size.y >= MIN_LEAF * 2


## 在叶子里摆房间：四边各留 1 格（保证房间之间有墙），尺寸与位置都带抖动
func _room_in_leaf(leaf: Rect2i) -> Rect2i:
	var avail := Rect2i(leaf.position + Vector2i(1, 1), leaf.size - Vector2i(2, 2))
	if avail.size.x < MIN_ROOM.x or avail.size.y < MIN_ROOM.y:
		avail = leaf
	var max_w := mini(MAX_ROOM.x, avail.size.x)
	var max_h := mini(MAX_ROOM.y, avail.size.y)
	if max_w < MIN_ROOM.x or max_h < MIN_ROOM.y:
		return Rect2i(0, 0, 0, 0)
	var rw := rng.randi_range(MIN_ROOM.x, max_w)
	var rh := rng.randi_range(MIN_ROOM.y, max_h)
	var rx := avail.position.x + rng.randi_range(0, avail.size.x - rw)
	var ry := avail.position.y + rng.randi_range(0, avail.size.y - rh)
	return Rect2i(rx, ry, rw, rh)


## 保底随机撒房间（旧算法的思路，只作为兜底）
func _fallback_rooms(target: int) -> void:
	var tries := 0
	while rooms.size() < target and tries < 400:
		tries += 1
		var rw := rng.randi_range(MIN_ROOM.x, MAX_ROOM.x)
		var rh := rng.randi_range(MIN_ROOM.y, MAX_ROOM.y)
		var r := Rect2i(rng.randi_range(1, w - rw - 2), rng.randi_range(1, h - rh - 2), rw, rh)
		var overlap := false
		for o in rooms:
			if Rect2i(r).grow(2).intersects(Rect2i(o)):
				overlap = true
				break
		if not overlap:
			_add_room(r, RoomKind.NORMAL)


# ———————— 2) 连通图：k 近邻 + MST + 环路 ————————

func _connect_rooms() -> void:
	var n := rooms.size()
	if n < 2:
		return
	var centers: Array = []
	for r in rooms:
		centers.append(_center(r))
	# k 近邻边（无向去重）
	var edges: Array = []
	var seen := {}
	for i in n:
		var order: Array = []
		for j in n:
			if i == j:
				continue
			order.append([centers[i].distance_squared_to(centers[j]), j])
		order.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
		for k in mini(KNN, order.size()):
			var j2: int = int(order[k][1])
			var lo := mini(i, j2)
			var hi := maxi(i, j2)
			var key := "%d-%d" % [lo, hi]
			if seen.has(key):
				continue
			seen[key] = true
			edges.append([lo, hi, float(order[k][0])])
	edges.sort_custom(func(a, b): return float(a[2]) < float(b[2]))
	# Kruskal：先保证全连通
	var parent: Array = []
	for i in n:
		parent.append(i)
	var mst: Array = []
	var rest: Array = []
	for e in edges:
		var ra := _find(parent, int(e[0]))
		var rb := _find(parent, int(e[1]))
		if ra == rb:
			rest.append(e)
			continue
		parent[ra] = rb
		mst.append(e)
	# 再补环路：取最短的若干条"多余边"（次短优先，避免绕大圈）
	var extra := int(ceil(float(n) * CORRIDOR_EXTRA))
	for e in rest:
		if extra <= 0:
			break
		# 太长的环路没意义（会变成第二条主干道，玩家只觉得绕），按格数截断
		if float(e[2]) > float(18 * 18):
			continue
		mst.append(e)
		extra -= 1
	_edges = []
	for e in mst:
		_edges.append([int(e[0]), int(e[1])])
		_carve_corridor(centers[int(e[0])], centers[int(e[1])])


func _find(parent: Array, i: int) -> int:
	var p := i
	var guard := 0
	while int(parent[p]) != p and guard < 64:
		p = int(parent[p])
		guard += 1
	# 路径压缩
	while int(parent[i]) != p:
		var nxt := int(parent[i])
		parent[i] = p
		i = nxt
	return p


# ———————— 3) A* 走廊 ————————

## 代价网格只建一次（基于房间层）：已有房间越"贵"，走廊就越愿意绕开而不是横穿
func _build_pathfinder() -> void:
	_nav = AStarGrid2D.new()
	_nav.size = Vector2i(w, h)
	_nav.cell_size = Vector2.ONE
	_nav.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_nav.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_nav.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_nav.update()
	for x in w:
		for y in h:
			var c := Vector2i(x, y)
			var cost := 1.0
			if grid[x][y] == FLOOR:
				cost = ROOM_COST
			elif x <= 1 or y <= 1 or x >= w - 2 or y >= h - 2:
				cost = BORDER_COST
			else:
				# 贴着房间/走廊打洞会粘连成大片空地 → 稍微加价
				var near := false
				for d in _N4:
					var nb: Vector2i = c + d
					if nb.x >= 0 and nb.y >= 0 and nb.x < w and nb.y < h and grid[nb.x][nb.y] == FLOOR:
						near = true
						break
				if near:
					cost = 1.6
			_nav.set_point_weight_scale(c, cost)


func _carve_corridor(a: Vector2i, b: Vector2i) -> void:
	if _nav == null:
		_corridor_l(a, b)
		return
	var pts = _nav.get_id_path(a, b)
	if pts == null or pts.size() == 0:
		_corridor_l(a, b)     # 兜底：A* 不可用时退回 L 形
		return
	for p in pts:
		_carve(Vector2i(int(p.x), int(p.y)))


## 旧式 L 形走廊（只在 A* 异常时兜底）
func _corridor_l(a: Vector2i, b: Vector2i) -> void:
	var p := a
	while p.x != b.x:
		p.x += 1 if b.x > p.x else -1
		_carve(p)
	while p.y != b.y:
		p.y += 1 if b.y > p.y else -1
		_carve(p)


# ———————— 4) 分级：起点/楼梯/宝箱房 ————————

## 分级 + 排序。最终 rooms 顺序是：
##   [0] 出发房  [1] 楼梯房（最远）  [2..] 其余按可达距离由近到远（叶节点标为宝箱房）
## 这样 main 侧"起点/楼梯"都有稳定语义，而"越靠后越深"对刷怪/宝箱也成立。
func _finalize_rooms() -> void:
	if rooms.is_empty():
		return
	if not is_floor(start_cell):
		start_cell = _nearest_floor(start_cell)
	var n := rooms.size()
	var dist := _bfs_dist(start_cell)
	# 叶节点（只连一条走廊）要在排序前判定：_edges 用的是排序前的下标
	var deg := _degrees()
	var start_i := 0
	var far_i := 0
	var far_d := -1
	var start_d := 1 << 29
	for i in n:
		var dd := _room_dist(rooms[i], dist)
		if dd < start_d:
			start_d = dd
			start_i = i
		if dd > far_d:
			far_d = dd
			far_i = i
	if far_i == start_i:
		far_i = start_i
	var rest: Array = []
	for i in n:
		if i != start_i and i != far_i:
			rest.append(i)
	rest.sort_custom(func(a, b): return _room_dist(rooms[a], dist) < _room_dist(rooms[b], dist))
	var order: Array = [start_i]
	if n >= 2:
		order.append(far_i)
	for i in rest:
		order.append(i)
	var nr: Array = []
	var nk: Array = []
	for pos in n:
		var oi: int = int(order[pos])
		nr.append(rooms[oi])
		if pos == 0:
			nk.append(RoomKind.START)
		elif pos == 1 and n >= 2:
			nk.append(RoomKind.STAIRS)
		elif int(deg.get(oi, 0)) <= 1:
			nk.append(RoomKind.TREASURE)
		else:
			nk.append(RoomKind.NORMAL)
	rooms = nr
	room_kind = nk
	start_cell = _center(rooms[0])
	stair_cell = _center(rooms[1]) if n >= 2 else Vector2i(-1, -1)


## 每个房间挂了几条走廊（下标为排序前）
func _degrees() -> Dictionary:
	var deg := {}
	for i in rooms.size():
		deg[i] = 0
	for e in _edges:
		deg[int(e[0])] = int(deg.get(int(e[0]), 0)) + 1
		deg[int(e[1])] = int(deg.get(int(e[1]), 0)) + 1
	return deg


# ———————— 查询 / 工具 ————————

## BFS 距离场（4 邻；-1 = 不可达）。也用于 debug_stats 的连通率统计
func _bfs_dist(from: Vector2i) -> PackedInt32Array:
	var n := maxi(1, w * h)
	var dist := PackedInt32Array()
	dist.resize(n)
	dist.fill(-1)
	if from.x < 0 or from.y < 0 or from.x >= w or from.y >= h:
		return dist
	if not is_floor(from):
		return dist
	var q := PackedInt32Array()
	q.resize(n)
	var qh := 0
	var qt := 0
	var si: int = from.y * w + from.x
	dist[si] = 0
	q[qt] = si
	qt += 1
	while qh < qt:
		var c: int = q[qh]
		qh += 1
		var cx: int = c % w
		var cy: int = c / w
		var nd: int = dist[c] + 1
		if cx + 1 < w and grid[cx + 1][cy] == FLOOR:
			var i1: int = cy * w + cx + 1
			if dist[i1] < 0:
				dist[i1] = nd
				q[qt] = i1
				qt += 1
		if cx > 0 and grid[cx - 1][cy] == FLOOR:
			var i2: int = cy * w + cx - 1
			if dist[i2] < 0:
				dist[i2] = nd
				q[qt] = i2
				qt += 1
		if cy + 1 < h and grid[cx][cy + 1] == FLOOR:
			var i3: int = (cy + 1) * w + cx
			if dist[i3] < 0:
				dist[i3] = nd
				q[qt] = i3
				qt += 1
		if cy > 0 and grid[cx][cy - 1] == FLOOR:
			var i4: int = (cy - 1) * w + cx
			if dist[i4] < 0:
				dist[i4] = nd
				q[qt] = i4
				qt += 1
	return dist


func _room_dist(r: Rect2i, dist: PackedInt32Array) -> int:
	var best := 1 << 30
	for x in range(r.position.x, r.end.x):
		for y in range(r.position.y, r.end.y):
			var d := dist[y * w + x]
			if d >= 0 and d < best:
				best = d
	return best if best < (1 << 30) else (1 << 29)


func _nearest_floor(c: Vector2i) -> Vector2i:
	for radius in range(0, 8):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				var n := c + Vector2i(dx, dy)
				if is_floor(n):
					return n
	return c


func _center(r: Rect2i) -> Vector2i:
	return Vector2i(r.position.x + r.size.x / 2, r.position.y + r.size.y / 2)


func _add_room(r: Rect2i, kind: int = RoomKind.NORMAL) -> void:
	rooms.append(r)
	room_kind.append(kind)
	for x in range(r.position.x, r.end.x):
		for y in range(r.position.y, r.end.y):
			if x > 0 and y > 0 and x < w - 1 and y < h - 1:
				grid[x][y] = FLOOR


## 2×2 打洞：单人 32px 走廊太窄，8 人小队跟随时会堵门
## 已经是地板的格子直接跳过：否则走廊擦着房间走时会把房间外墙一起啃掉，
## 两个房间被"融"成一大间，BSP 的分区就白做了
func _carve(c: Vector2i) -> void:
	if c.x < 0 or c.y < 0 or c.x >= w or c.y >= h or grid[c.x][c.y] == FLOOR:
		return
	for dx in 2:
		for dy in 2:
			var cc := c + Vector2i(dx, dy)
			if cc.x > 0 and cc.y > 0 and cc.x < w - 1 and cc.y < h - 1:
				grid[cc.x][cc.y] = FLOOR


func is_floor(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < w and c.y < h and grid[c.x][c.y] == FLOOR


static func cell_to_pos(c: Vector2i) -> Vector2:
	return Vector2(c) * float(ArpgData.TILE) + Vector2.ONE * (ArpgData.TILE * 0.5)


## 房间内随机地板格；room 传空矩形则全图随机
func random_cell_in(room: Rect2i) -> Vector2i:
	for i in 120:
		var c := Vector2i.ZERO
		if room.size.x > 0:
			c = Vector2i(rng.randi_range(room.position.x, room.end.x - 1),
				rng.randi_range(room.position.y, room.end.y - 1))
		else:
			c = Vector2i(rng.randi_range(1, w - 2), rng.randi_range(1, h - 2))
		if is_floor(c):
			return c
	return start_cell


## 宝箱房：优先叶节点房间（跑一趟有回报），轮转避免两个箱子堆同一间
func loot_room(gen_rng: RandomNumberGenerator) -> Rect2i:
	var pool: Array = []
	for i in rooms.size():
		if room_kind[i] == RoomKind.TREASURE:
			pool.append(i)
	if pool.is_empty():
		for i in range(1, rooms.size() - 1):
			pool.append(i)
	if pool.is_empty():
		return rooms[0]
	if gen_rng != null and _loot_cursor == 0:
		_loot_cursor = gen_rng.randi_range(0, pool.size() - 1)   # 每层起点不同，避免固定在同一个房
	var pick: int = int(pool[_loot_cursor % pool.size()])
	_loot_cursor += 1
	return rooms[pick]


## 生成质量自检（F1 调试面板用）：房间数 / 地板占比 / 可达率
func debug_stats() -> String:
	var floors := 0
	for x in w:
		for y in h:
			if grid[x][y] == FLOOR:
				floors += 1
	var reach := _bfs_dist(start_cell)
	var reachable := 0
	for i in reach.size():
		if reach[i] >= 0:
			reachable += 1
	var total := maxi(w * h, 1)
	return "房间 %d · 地板 %d%% · 可达 %d%%" % [
		rooms.size(), int(100.0 * float(floors) / float(total)),
		int(100.0 * float(reachable) / float(maxi(floors, 1)))]


## 压测斗兽场：一大块开阔场地 + 少量石柱阵（供 --stress 生成上万敌人）
func generate_arena(aw := 170, ah := 120) -> void:
	rng.randomize()
	boss_floor = false
	w = aw
	h = ah
	_reset_grid()
	rooms = []
	room_kind = []
	_edges = []
	var r := Rect2i(2, 2, w - 4, h - 4)
	_add_room(r, RoomKind.START)
	# 石柱阵：每 14 格一个 2x2 柱子，打散纯平地
	for px in range(8, w - 8, 14):
		for py in range(8, h - 8, 14):
			for dx in 2:
				for dy in 2:
					grid[px + dx][py + dy] = WALL
	start_cell = Vector2i(w / 2, h / 2)


## 全部地板格（压测用：一次性拿全图可走格，洗牌后批量刷怪）
func floor_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for x in w:
		for y in h:
			if grid[x][y] == FLOOR:
				out.append(Vector2i(x, y))
	return out
