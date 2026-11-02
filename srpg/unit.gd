class_name SrpgUnit
extends Node2D
## 场上单位：RPG Maker 行走图切片、移动/朝向动画、血条、受击与死亡表现。

const FRAME := 48        # MZ 单帧 48x48；一个角色块 3 帧 x 4 朝向
const WALK_SEQ := [0, 1, 2, 1]
const DIR_ROW := {"down": 0, "left": 1, "right": 2, "up": 3}

var uid := ""            # 场上唯一 id（ placements 的 uid 或自动生成的 spawn_N）
var tpl_id := ""         # 模板 id（对应 SrpgData.UNITS 的键）
var uname := ""
var faction := "player"
var max_hp := 1
var hp := 1
var atk := 1
var def := 1
var mov := 4
var rmin := 1
var rmax := 1
var is_magic := false
var heal_power := 0
var is_boss := false
var cell := Vector2i.ZERO
var acted := false

var sprite: Sprite2D
var hp_bar: HpBar
var block := Vector2i.ZERO   # 角色块左上角像素坐标
var facing := "down"
var selected := false

var _walking := false
var _walk_t := 0.0


## 血条画在 sprite 之上（子节点顺序靠后 = 绘制在上）
class HpBar extends Node2D:
	var ratio := 1.0

	func set_ratio(r: float) -> void:
		ratio = clampf(r, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		var bw := 26.0
		draw_rect(Rect2(-bw / 2, -27, bw, 4), Color(0.05, 0.05, 0.09, 0.9), true)
		var col := Color(0.35, 0.85, 0.35)
		if ratio <= 0.25:
			col = Color(0.9, 0.25, 0.2)
		elif ratio <= 0.5:
			col = Color(0.95, 0.8, 0.25)
		draw_rect(Rect2(-bw / 2, -27, bw * ratio, 4), col, true)


func setup(id: String, template_id: String, tpl: Dictionary, start_cell: Vector2i) -> void:
	uid = id
	tpl_id = template_id
	uname = tpl["name"]
	faction = tpl["faction"]
	max_hp = tpl["hp"]
	hp = max_hp
	atk = tpl["atk"]
	def = tpl["def"]
	mov = tpl["mov"]
	rmin = tpl["rmin"]
	rmax = tpl["rmax"]
	is_magic = tpl.get("magic", false)
	heal_power = tpl.get("heal", 0)
	is_boss = tpl.get("boss", false)
	cell = start_cell
	position = SrpgBattleMap.cell_to_pos(start_cell)
	if is_boss:
		scale = Vector2(1.1, 1.1)

	var tex: Texture2D = load(tpl["sprite"][0])
	block = Vector2i(tpl["sprite"][1], tpl["sprite"][2])
	sprite = Sprite2D.new()
	sprite.texture = tex
	sprite.region_enabled = true
	sprite.region_rect = Rect2(block.x, block.y, FRAME, FRAME)
	sprite.offset = Vector2(0, -5)   # 脚底对齐格心
	add_child(sprite)

	hp_bar = HpBar.new()
	add_child(hp_bar)
	_set_frame(0)


func _process(delta: float) -> void:
	if _walking:
		_walk_t += delta
		_set_frame(WALK_SEQ[int(_walk_t / 0.12) % WALK_SEQ.size()])


func _set_frame(f: int) -> void:
	var row: int = DIR_ROW[facing]
	sprite.region_rect = Rect2(block.x + f * FRAME, block.y + row * FRAME, FRAME, FRAME)


func face_towards(p: Vector2) -> void:
	var d := p - position
	if d.length_squared() < 1.0:
		return
	if absf(d.x) > absf(d.y):
		facing = "right" if d.x > 0 else "left"
	else:
		facing = "down" if d.y > 0 else "up"
	_set_frame(0)


## 沿像素点序列逐格行走（await 走完才返回）
func walk_to(points: Array) -> void:
	_walking = true
	for p in points:
		face_towards(p)
		var tw := create_tween()
		tw.tween_property(self, "position", p, 0.13)
		await tw.finished
	_walking = false
	_walk_t = 0.0
	_set_frame(0)
	cell = SrpgBattleMap.pos_to_cell(position)


## 攻击突进：扑向目标再弹回
func lunge(target_pos: Vector2) -> void:
	var back := position
	var tw := create_tween()
	tw.tween_property(self, "position", position.move_toward(target_pos, 15.0), 0.08)
	tw.tween_property(self, "position", back, 0.12)
	await tw.finished


func flash(col: Color) -> void:
	sprite.modulate = col
	var tw := create_tween()
	tw.tween_property(sprite, "modulate", Color.WHITE, 0.28)


func set_acted(v: bool) -> void:
	acted = v
	modulate = Color(0.62, 0.62, 0.68) if v else Color.WHITE


func set_selected(v: bool) -> void:
	selected = v
	queue_redraw()


func take_damage(dmg: int) -> void:
	hp = maxi(0, hp - dmg)
	hp_bar.set_ratio(float(hp) / max_hp)


func heal_by(amount: int) -> void:
	hp = mini(max_hp, hp + amount)
	hp_bar.set_ratio(float(hp) / max_hp)


func die() -> void:
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(sprite, "scale", Vector2(0.05, 0.05), 0.32)
	tw.tween_property(sprite, "rotation_degrees", 130.0, 0.32)
	tw.tween_property(self, "modulate:a", 0.0, 0.32)
	await tw.finished


func _draw() -> void:
	# 影子（压扁的圆）
	draw_set_transform(Vector2(0, 13), 0.0, Vector2(1.0, 0.45))
	draw_circle(Vector2.ZERO, 9.0, Color(0, 0, 0, 0.28))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if selected:
		draw_arc(Vector2(0, 13), 11.0, 0, TAU, 40, Color(1, 0.95, 0.5, 0.95), 2.5)
