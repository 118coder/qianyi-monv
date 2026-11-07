class_name ArpgSceneLoader
extends RefCounted
## 手搭场景 → ArpgDungeon 转换层（P1-1 方案 C：独立试玩模式）。
##
## 设计：
##  · 创作工坊场景编辑器存 data/scenes/xxx.json（多图层行优先 int 数组，-1 空）；
##  · 本加载器把「画了图块的格子」转成 FLOOR、空的转成 WALL——即手搭布局决定走位，
##    视觉仍用默认地砖（图块视觉接入是后续工作，需要 tileset 渲染管线）；
##  · grid_size != 32 的场景按比例换算（1 图块 → grid_size/32 格，向上取整）；
##  · rooms 由地板连通块（flood fill 包围盒）近似，起点=面积最大块中心，楼梯=最远块中心；
##    build_floor 依赖的 rooms/start_cell/stair_cell/random_cell_in/_center/is_floor 全部可用。
##
## 已知取舍（方案 C 边界，见 docs/下一轮交接.md）：
##  · 图块索引不参与渲染——本层只验证「手搭布局 → 碰撞/寻路/怪物/宝箱」的管线正确性；
##  · Boss 层不走场景（boss_floor 仍随机单间，场景模式禁 Boss 层）。

const CELL := 32   # ArpgData.GRID 的本地镜像（避免跨系统依赖常量初始化顺序）


## 读取场景 JSON 并转成可用的 ArpgDungeon；失败返回 null（调用方回退随机生成）
static func load_dungeon(path: String) -> ArpgDungeon:
	if not FileAccess.file_exists(path):
		print("[SceneLoader] 场景文件不存在：%s" % path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		print("[SceneLoader] 场景 JSON 解析失败：%s" % path)
		return null
	var d: Dictionary = parsed
	var sw: int = int(d.get("width", 0))
	var sh: int = int(d.get("height", 0))
	var gs: int = int(d.get("grid_size", 32))
	if sw <= 0 or sh <= 0:
		print("[SceneLoader] 场景尺寸非法（%d×%d）" % [sw, sh])
		return null
	# 图层归一：找第一个含非空数据的可见层（没有就整图视为墙）
	var src: Array = []
	for L in d.get("layers", []):
		if bool(L.get("visible", true)):
			var arr: Array = L.get("data", [])
			if arr.size() >= sw * sh:
				src = arr
				break
	# 比例换算：1 图块 = ratio×ratio 个逻辑格（grid_size 是图块边长像素）
	var ratio: int = maxi(1, int(round(float(gs) / float(CELL))))
	var w: int = sw * ratio
	var h: int = sh * ratio
	var dun := ArpgDungeon.new()
	dun.w = w
	dun.h = h
	dun.grid = []
	for x in w:
		var col: Array = []
		col.resize(h)
		col.fill(ArpgDungeon.WALL)
		dun.grid.append(col)
	# 铺地板：图块 (tx,ty) → 逻辑格 [tx*ratio .. tx*ratio+ratio)
	for ty in sh:
		for tx in sw:
			if int(src[ty * sw + tx]) >= 0:
				for ox in ratio:
					for oy in ratio:
						var gx: int = tx * ratio + ox
						var gy: int = ty * ratio + oy
						if gx < w and gy < h:
							dun.grid[gx][gy] = ArpgDungeon.FLOOR
	# 连通块 → rooms（flood fill，包围盒，按面积降序）
	var rooms := _rooms_from(dun)
	if rooms.is_empty():
		print("[SceneLoader] 场景没有可用地板")
		return null
	dun.rooms = rooms
	dun.room_kind = []
	for i in rooms.size():
		dun.room_kind.append(ArpgDungeon.RoomKind.NORMAL)
	# 起点 = 最大房间中心
	var start_room: Rect2i = rooms[0]
	dun.start_cell = Vector2i(int(start_room.position.x + start_room.size.x * 0.5),
		int(start_room.position.y + start_room.size.y * 0.5))
	if not dun.is_floor(dun.start_cell):
		dun.start_cell = dun.random_cell_in(start_room)
	# 楼梯 = BFS 距离场最远的地板格（不依赖房间结构；手搭场景常是单个大连通块）
	var dist_map := {}
	var q: Array = [dun.start_cell]
	dist_map[dun.start_cell] = 0
	var head := 0
	var far := dun.start_cell
	var far_d := 0
	while head < q.size():
		var c: Vector2i = q[head]
		head += 1
		for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: Vector2i = c + off
			if nb.x < 0 or nb.y < 0 or nb.x >= w or nb.y >= h:
				continue
			if dist_map.has(nb) or dun.grid[nb.x][nb.y] != ArpgDungeon.FLOOR:
				continue
			dist_map[nb] = int(dist_map[c]) + 1
			if int(dist_map[nb]) > far_d:
				far_d = int(dist_map[nb])
				far = nb
			q.append(nb)
	dun.stair_cell = far
	dun.boss_floor = false      # 方案 C：场景试玩不进 Boss 层
	print("[SceneLoader] %s → %d×%d（比例 ×%d）· %d 个房间 · 起点 %s 楼梯 %s" % [
		str(d.get("name", path)), w, h, ratio, rooms.size(), dun.start_cell, dun.stair_cell])
	return dun


## flood fill 地板连通块 → 包围盒列表（面积降序）
static func _rooms_from(dun: ArpgDungeon) -> Array:
	var out: Array = []
	var seen := {}
	for x in dun.w:
		for y in dun.h:
			var key := Vector2i(x, y)
			if seen.has(key) or dun.grid[x][y] != ArpgDungeon.FLOOR:
				continue
			# BFS 这一块
			var q: Array = [key]
			seen[key] = true
			var minv := key
			var maxv := key
			var head := 0
			while head < q.size():
				var c: Vector2i = q[head]
				head += 1
				minv = Vector2i(mini(minv.x, c.x), mini(minv.y, c.y))
				maxv = Vector2i(maxi(maxv.x, c.x), maxi(maxv.y, c.y))
				for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nb: Vector2i = c + off
					if nb.x < 0 or nb.y < 0 or nb.x >= dun.w or nb.y >= dun.h:
						continue
					if seen.has(nb) or dun.grid[nb.x][nb.y] != ArpgDungeon.FLOOR:
						continue
					seen[nb] = true
					q.append(nb)
			var rect := Rect2i(minv, maxv - minv + Vector2i.ONE)
			if rect.get_area() >= 9:   # 过滤零碎小碎块（<3×3）
				out.append(rect)
	out.sort_custom(func(a, b): return b.get_area() < a.get_area())
	return out
