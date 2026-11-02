class_name ArpgDungeon
extends RefCounted
## 随机地牢生成：不重叠矩形房间 + 按序 L 形走廊连接。
## 第 5 层为 Boss 层（单个大房间）。

enum { WALL = 0, FLOOR = 1 }

var w := 0
var h := 0
var grid := []            # grid[x][y] -> WALL / FLOOR
var rooms := []           # [Rect2i]
var start_cell := Vector2i.ZERO
var boss_floor := false
var rng := RandomNumberGenerator.new()


func generate(floor: int, seed_val: int = -1) -> void:
	if seed_val >= 0:
		rng.seed = seed_val
	else:
		rng.randomize()
	boss_floor = floor >= ArpgBalance.MAX_FLOOR
	w = 36 if boss_floor else 44
	h = 26 if boss_floor else 32
	grid = []
	for x in w:
		var col := []
		col.resize(h)
		col.fill(WALL)
		grid.append(col)
	rooms = []

	if boss_floor:
		_add_room(Rect2i(5, 4, 26, 18))
		start_cell = Vector2i(8, 12)
	else:
		var tries := 0
		while rooms.size() < 8 and tries < 300:
			tries += 1
			var rw := rng.randi_range(5, 9)
			var rh := rng.randi_range(4, 7)
			var r := Rect2i(rng.randi_range(1, w - rw - 2), rng.randi_range(1, h - rh - 2), rw, rh)
			var overlap := false
			for o in rooms:
				if r.grow(2).intersects(o):
					overlap = true
					break
			if not overlap:
				_add_room(r)
		rooms.sort_custom(_room_cmp)
		for i in rooms.size() - 1:
			_corridor(_center(rooms[i]), _center(rooms[i + 1]))
		start_cell = _center(rooms[0])


func _room_cmp(a: Rect2i, b: Rect2i) -> bool:
	return a.position.x < b.position.x


func _center(r: Rect2i) -> Vector2i:
	return Vector2i(r.position.x + r.size.x / 2, r.position.y + r.size.y / 2)


func _add_room(r: Rect2i) -> void:
	rooms.append(r)
	for x in range(r.position.x, r.end.x):
		for y in range(r.position.y, r.end.y):
			grid[x][y] = FLOOR


func _carve(c: Vector2i) -> void:
	for dx in 2:
		for dy in 2:
			var cc := c + Vector2i(dx, dy)
			if cc.x > 0 and cc.y > 0 and cc.x < w - 1 and cc.y < h - 1:
				grid[cc.x][cc.y] = FLOOR


func _corridor(a: Vector2i, b: Vector2i) -> void:
	var p := a
	while p.x != b.x:
		p.x += 1 if b.x > p.x else -1
		_carve(p)
	while p.y != b.y:
		p.y += 1 if b.y > p.y else -1
		_carve(p)


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


## 压测斗兽场：一大块开阔场地 + 少量石柱阵（供 --stress 生成上万敌人）
func generate_arena(aw := 170, ah := 120) -> void:
	rng.randomize()
	boss_floor = false
	w = aw
	h = ah
	grid = []
	for x in w:
		var col := []
		col.resize(h)
		col.fill(WALL)
		grid.append(col)
	rooms = []
	var r := Rect2i(2, 2, w - 4, h - 4)
	_add_room(r)
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
