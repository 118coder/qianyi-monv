class_name ArpgPickupSystem
extends Node2D
## 掉落物数据系统：SoA + 批次渲染（菱形宝石 + 呼吸浮动）。玩家走近自动拾取。

const MAX := 200
const TILE := ArpgData.TILE

var world: Node

var count := 0
var pos := PackedVector2Array()
var item := PackedStringArray()
var t := PackedFloat32Array()
var alive := PackedByteArray()
var ids := PackedInt64Array()     # 掉落稳定 ID（仲裁认领用，压缩时随槽位移动）
var _next_id := 1


func setup(w: Node) -> void:
	world = w
	pos.resize(MAX)
	item.resize(MAX)
	t.resize(MAX)
	alive.resize(MAX)
	ids.resize(MAX)


## 返回掉落稳定 ID（供 PickupArbiter 认领）
func spawn(p: Vector2, item_id: String) -> int:
	var i := -1
	if count < MAX:
		i = count
		count += 1
	else:
		for j in count:
			if alive[j] == 1:
				i = j
				break
	if i < 0:
		return -1
	alive[i] = 1
	pos[i] = p + Vector2(randf_range(-10, 10), randf_range(-8, 8))
	item[i] = item_id
	t[i] = randf() * TAU
	ids[i] = _next_id
	_next_id += 1
	return ids[i]


func nearest(from: Vector2, r: float) -> int:
	var best := -1
	var bd := r
	for i in count:
		if alive[i] == 0:
			continue
		var d: float = pos[i].distance_to(from)
		if d < bd:
			bd = d
			best = i
	return best


## 仲裁用接口：按稳定 ID 查询/定位/收取
func nearest_id(from: Vector2, r: float) -> int:
	var i := nearest(from, r)
	return ids[i] if i >= 0 else -1


func pos_of(drop_id: int) -> Vector2:
	var i := _index_of_id(drop_id)
	return pos[i] if i >= 0 else Vector2(-9999, -9999)


func take_by_id(drop_id: int) -> String:
	return take(_index_of_id(drop_id))


func item_of(drop_id: int) -> String:
	var i := _index_of_id(drop_id)
	return item[i] if i >= 0 else ""


func _index_of_id(drop_id: int) -> int:
	for i in count:
		if alive[i] == 1 and ids[i] == drop_id:
			return i
	return -1


func take(i: int) -> String:
	var item_str: String = item[i]
	alive[i] = 0
	var j := 0
	for k in count:
		if alive[k] == 1:
			if j != k:
				pos[j] = pos[k]
				item[j] = item[k]
				t[j] = t[k]
				ids[j] = ids[k]
				alive[j] = 1
			j += 1
	count = j
	return item_str


func _physics_process(delta: float) -> void:
	if world.main == null or world.main.state != world.main.State.PLAY:
		return
	var pl = world.player
	if pl == null or pl.dead:
		return
	for i in count:
		if alive[i] == 1:
			t[i] += delta
	# 拾取：玩家优先（覆盖任何 AI 认领）；背包满留在地上并提示（节流）
	var i2 := nearest(pl.position, 17.0)
	if i2 >= 0:
		if not world.main.rpg.inventory.is_full():
			var drop_id: int = ids[i2]
			var item_id := take(i2)
			world.main.arbiter.player_took(drop_id)
			world.main.on_player_pickup(item_id)
		else:
			world.main.bag_full_warn()
	queue_redraw()


func _draw() -> void:
	for i in count:
		if alive[i] == 0:
			continue
		var bob := sin(t[i] * 4.0) * 2.0
		var tint: Color = ArpgBalance.ITEMS[item[i]]["tint"]
		draw_circle(pos[i] + Vector2(0, bob), 9.0, Color(tint.r, tint.g, tint.b, 0.22))
		draw_circle(pos[i] + Vector2(0, 9.0), 4.0, Color(0, 0, 0, 0.22))
		var pts := PackedVector2Array([
			pos[i] + Vector2(0, -7 + bob), pos[i] + Vector2(5.5, bob),
			pos[i] + Vector2(0, 7 + bob), pos[i] + Vector2(-5.5, bob),
		])
		draw_colored_polygon(pts, tint)
		draw_colored_polygon(PackedVector2Array([
			pos[i] + Vector2(0, -7 + bob), pos[i] + Vector2(0, 7 + bob), pos[i] + Vector2(-5.5, bob),
		]), tint.darkened(0.25))
