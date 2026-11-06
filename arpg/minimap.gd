class_name ArpgMinimap
extends Control
## 小地图：灰白配色的迷宫轮廓 + 战争迷雾（逐格记忆，实时更新）
##
## 设计要点：
##  · 纯灰阶：地板浅灰、墙体中灰、未探索完全不画（露出深色底板）——"轮廓"靠明暗对比读出来；
##  · 迷雾按**格**记忆（`_seen` 位图），换层/换图自动重置；
##  · 探索用「以主控单位为中心、限半径的 BFS」而不是"圆形半径"：
##    只穿过地板扩散，所以隔墙不会点亮，绕过一个拐角则会把拐角后那一段记下来——
##    这正是"已探索区域"的语义，也不会出现"墙后一片亮"；
##  · 只在有新格点亮 / 主控移动 / 10Hz 节拍时重绘，静止时几乎零开销；
##  · 同屏绘制把同一行连续的同类格合并成一个矩形（一行最多十几笔，而不是 1400 个格子）。
##
## 参数在 balance.json 的 `minimap` 段：width / height / reveal_radius / reveal_interval。

const COL_BG := Color(0.075, 0.082, 0.092, 0.90)
const COL_BORDER := Color(0.66, 0.70, 0.74, 0.40)
const COL_FLOOR := Color(0.83, 0.85, 0.88, 1.0)
const COL_WALL := Color(0.33, 0.35, 0.38, 1.0)
const COL_SELF := Color(1, 1, 1, 1)
const COL_ALLY := Color(0.78, 0.81, 0.85, 0.85)
const COL_MARK := Color(1, 0.98, 0.92, 0.95)
const _N4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var host: Node                # HUD（从中取 game）
var game: Node

var _seen := PackedByteArray()   # w*h，1 = 已探索
var _visit := PackedInt32Array() # 本次 BFS 的访问标记（不能用 _seen 兼任，见 _reveal 注释）
var _stamp := 0
var _w := 0
var _h := 0
var _dungeon_id := 0
var _reveal_t := 0.0
var _tick := 0.0
var _last_focus := Vector2(-9999, -9999)
var _dirty := true
var _sb: StyleBoxFlat
var _time := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_sb = StyleBoxFlat.new()
	_sb.bg_color = COL_BG
	_sb.border_color = COL_BORDER
	_sb.set_border_width_all(1)
	_sb.set_corner_radius_all(10)
	_sb.anti_aliasing = true


## 由 HUD 调用：绑定宿主 + 按配置摆放（右下角）
func bind_hud(h: Node) -> void:
	host = h
	var w := float(_cfg("width", 184.0))
	var hh := float(_cfg("height", 132.0))
	custom_minimum_size = Vector2(w, hh)
	size = Vector2(w, hh)
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = -w - 10.0
	offset_right = -10.0
	offset_top = -hh - 10.0
	offset_bottom = -10.0
	var m: Dictionary = ArpgBalance.data.get("minimap", {})
	if not bool(m.get("enabled", true)):
		visible = false
	_dirty = true


func _process(delta: float) -> void:
	if host == null or not visible:
		return
	var g = host.get("game")
	if g == null or g.state != g.State.PLAY:
		return
	game = g
	var d = game.dungeon
	if d == null or d.grid.is_empty():
		return
	_time += delta
	if d.get_instance_id() != _dungeon_id:
		_reset(d)
	var focus = _focus()
	if focus == null:
		return
	# 探索：按节拍推进（不必每帧）
	_reveal_t -= delta
	if _reveal_t <= 0.0:
		_reveal_t = float(_cfg("reveal_interval", 0.12))
		if _reveal(d, focus.position):
			_dirty = true
	# 主控在动 → 光点要跟；静止时也以 10Hz 重绘，保证队友光点/标记更新
	if focus.position.distance_to(_last_focus) > 0.6:
		_last_focus = focus.position
		_dirty = true
	_tick += delta
	if _tick >= 0.1:
		_tick = 0.0
		_dirty = true
	if _dirty:
		_dirty = false
		queue_redraw()


func _focus():
	if game == null:
		return null
	if game.possession != null and is_instance_valid(game.possession.current_unit):
		return game.possession.current_unit
	if game.player != null and is_instance_valid(game.player):
		return game.player
	return null


func _reset(d: ArpgDungeon) -> void:
	_dungeon_id = d.get_instance_id()
	_w = d.w
	_h = d.h
	_seen.resize(maxi(_w * _h, 1))
	_seen.fill(0)
	_visit.resize(maxi(_w * _h, 1))
	_visit.fill(0)
	_stamp = 0
	_reveal_t = 0.0
	_dirty = true


## 限半径 BFS 点灯（穿地板扩散，不穿墙）。返回是否有新格被点亮。
## ⚠️ 访问标记必须用独立的 `_visit`（时间戳），**不能**拿 `_seen` 兼任：
## 玩家沿走廊走一段后，前方新格与"已探索格"相邻，若用 _seen 判重就会在旧区域边缘直接停住，
## 表现为"走进新房间，地图只亮门口一格"。
func _reveal(d: ArpgDungeon, p: Vector2) -> bool:
	var c := Vector2i((p / float(ArpgData.TILE)).floor())
	if not d.is_floor(c):
		c = _nearest_floor(d, c)
	var radius := int(_cfg("reveal_radius", 7.0))
	var n := _w * _h
	if _visit.size() != n:
		_visit.resize(n)
		_visit.fill(0)
	_stamp += 1
	if _stamp >= 2000000000:
		_visit.fill(0)
		_stamp = 1
	var changed := false
	var queue: Array = [c]
	var dist: Array = [0]
	var head := 0
	_visit[c.y * _w + c.x] = _stamp
	while head < queue.size():
		var cur: Vector2i = queue[head]
		var dd: int = dist[head]
		head += 1
		var idx: int = cur.y * _w + cur.x
		if _seen[idx] == 0:
			_seen[idx] = 1
			changed = true
		if dd >= radius:
			continue
		for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: Vector2i = cur + off
			if nb.x < 0 or nb.y < 0 or nb.x >= _w or nb.y >= _h:
				continue
			if not d.is_floor(nb):
				continue
			var ni: int = nb.y * _w + nb.x
			if _visit[ni] == _stamp:
				continue
			_visit[ni] = _stamp
			queue.append(nb)
			dist.append(dd + 1)
	return changed


func _nearest_floor(d: ArpgDungeon, c: Vector2i) -> Vector2i:
	for r in range(0, 5):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var n := c + Vector2i(dx, dy)
				if d.is_floor(n):
					return n
	return c


func _cfg(key: String, def: float) -> float:
	var m: Dictionary = ArpgBalance.data.get("minimap", {})
	return float(m.get(key, def))


func explored_ratio() -> float:
	if _seen.is_empty():
		return 0.0
	var n := 0
	for i in _seen.size():
		if _seen[i] == 1:
			n += 1
	return float(n) / float(_seen.size())


func debug_info() -> String:
	return "小地图 已探 %.0f%%" % (explored_ratio() * 100.0)


# ———————— 绘制 ————————

func _draw() -> void:
	draw_style_box(_sb, Rect2(Vector2.ZERO, size))
	if game == null or game.dungeon == null or _w <= 0:
		return
	var d: ArpgDungeon = game.dungeon
	var pad := 8.0
	var inner := Vector2(maxf(size.x - pad * 2.0, 8.0), maxf(size.y - pad * 2.0, 8.0))
	var cell: float = minf(inner.x / float(_w), inner.y / float(_h))
	if cell <= 0.0:
		return
	var ox: float = (size.x - cell * float(_w)) * 0.5
	var oy: float = (size.y - cell * float(_h)) * 0.5

	# 逐行合并同类格：一行最多十几笔
	for y in _h:
		var x := 0
		while x < _w:
			var kind := _kind(d, x, y)
			var x2 := x
			while x2 + 1 < _w and _kind(d, x2 + 1, y) == kind:
				x2 += 1
			if kind != 0:
				var col: Color = COL_WALL if kind == 2 else COL_FLOOR
				draw_rect(Rect2(ox + float(x) * cell, oy + float(y) * cell,
					float(x2 - x + 1) * cell, cell), col, true)
			x = x2 + 1

	# 楼梯 / 传送门（只画已探索的）
	if game.world != null:
		_mark(d, game.world.stairs_cell, cell, ox, oy, false)
		_mark(d, game.world.portal_cell, cell, ox, oy, true)
		# 宝箱（金点）/ 神秘商人（紫点）：找路不再瞎逛（视觉走查后追加）
		for c in game.world.chests:
			if c == null or not is_instance_valid(c) or c.opened:
				continue
			var cc := Vector2i((c.position / float(ArpgData.TILE)).floor())
			if not _is_seen(cc):
				continue
			var cp := Vector2(ox + (float(cc.x) + 0.5) * cell, oy + (float(cc.y) + 0.5) * cell)
			draw_circle(cp, maxf(cell * 0.3, 1.5),
				Color(0.78, 0.5, 1.0, 0.95) if c.merchant else Color(1.0, 0.85, 0.35, 0.95))
		# Boss 血量可见时画大红点（BOSS 层的方位感）
		var bi: int = game.world.mobs.find_boss() if game.world.mobs != null else -1
		if bi >= 0:
			var bc := Vector2i((game.world.mobs.pos[bi] / float(ArpgData.TILE)).floor())
			if _is_seen(bc):
				draw_circle(Vector2(ox + (float(bc.x) + 0.5) * cell, oy + (float(bc.y) + 0.5) * cell),
					maxf(cell * 0.45, 2.2), Color(1.0, 0.25, 0.25, 0.95))

	# 队友（只画已探索的）
	if game.party != null:
		for f in game.party.friends:
			if f == null or not is_instance_valid(f) or f.dead:
				continue
			var fc := Vector2i((f.position / float(ArpgData.TILE)).floor())
			if not _is_seen(fc):
				continue
			draw_circle(Vector2(ox + f.position.x / float(ArpgData.TILE) * cell,
				oy + f.position.y / float(ArpgData.TILE) * cell), maxf(cell * 0.28, 1.4), COL_ALLY)

	# 主控光点（呼吸环）
	var focus = _focus()
	if focus != null:
		var fp: Vector2 = Vector2(ox + focus.position.x / float(ArpgData.TILE) * cell,
			oy + focus.position.y / float(ArpgData.TILE) * cell)
		var pulse: float = 0.6 + 0.4 * sin(_time * 4.0)
		draw_circle(fp, maxf(cell * 0.85, 3.0) * pulse, Color(1, 1, 1, 0.20))
		draw_circle(fp, maxf(cell * 0.42, 1.8), COL_SELF)


## 0 = 迷雾（不画） / 1 = 已探索地板 / 2 = 已探索墙体
## 墙的显形规则：自己已探索，或紧挨着已探索的地板 —— 否则只画地板，"迷宫轮廓"就只剩几条亮带，
## 看不出房间边界。墙本身不参与 BFS 扩散，所以隔墙依然不会被点亮。
func _kind(d: ArpgDungeon, x: int, y: int) -> int:
	if _seen.is_empty():
		return 0
	if d.grid[x][y] == ArpgDungeon.FLOOR:
		return 1 if _seen[y * _w + x] == 1 else 0
	if _seen[y * _w + x] == 1:
		return 2
	for off in _N4:
		var nx: int = x + off.x
		var ny: int = y + off.y
		if nx < 0 or ny < 0 or nx >= _w or ny >= _h:
			continue
		if d.grid[nx][ny] == ArpgDungeon.FLOOR and _seen[ny * _w + nx] == 1:
			return 2
	return 0


func _is_seen(c: Vector2i) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= _w or c.y >= _h or _seen.is_empty():
		return false
	return _seen[c.y * _w + c.x] == 1


func _mark(d: ArpgDungeon, c: Vector2i, cell: float, ox: float, oy: float, ring: bool) -> void:
	if c.x < 0 or not _is_seen(c):
		return
	var p := Vector2(ox + (float(c.x) + 0.5) * cell, oy + (float(c.y) + 0.5) * cell)
	var r: float = maxf(cell * 0.55, 2.0)
	if ring:
		draw_arc(p, r, 0.0, TAU, 12, COL_MARK, 1.4)
	else:
		draw_rect(Rect2(p - Vector2(r, r) * 0.8, Vector2(r, r) * 1.6), COL_MARK, false, 1.2)
