class_name ArpgWorld
extends Node2D
## 地牢世界门面：图块/墙体渲染 + 三大数据系统（敌群/投射物/掉落）+ 有上限的特效池。
## 敌群为数据实体（无节点）；命中反馈 = 火花 + 顿帧 + 震屏 + 震动 + 数字，分层分级。

const TILE := ArpgData.TILE
const TEX_FLOOR := preload("res://assets/tiles/Dungeon_Cave_TileA2.png")
const TEX_WALL := preload("res://assets/tiles/Dungeon_TileA4.png")

# 特效贴图（经 LRU 懒加载缓存，可承载上千张贴图）
const FX_SLASH_PATH := "res://assets/fx/Slash1.png"
const FX_SHOCKWAVE_RING_PATH := "res://assets/fx/ShockWaveRing1.png"
const FX_SHOCKWAVE_PATH := "res://assets/fx/ShockWave1.png"
const FX_PARTICLE_PATH := "res://assets/fx/Particle100.png"
const FX_RING_PATH := "res://assets/fx/Ring.png"
const FX_LIGHT_RING_PATH := "res://assets/fx/LightRing.png"
const FX_FOG_PATH := "res://assets/fx/Fog.png"

const FX_CAP := 64          # 同时存活的贴图特效上限（超出释放最旧）
const POPUP_CAP := 16       # 伤害数字上限

var main: Node
var dungeon: ArpgDungeon
var player: ArpgPlayer
var mobs: ArpgMobSystem
var projs: ArpgProjSystem
var pickups: ArpgPickupSystem
var actors_root: Node2D
var fx_root: Node2D
var chests := []
var stairs_cell := Vector2i(-1, -1)
var portal_cell := Vector2i(-1, -1)
var ui_font: SystemFont


func build(d: ArpgDungeon, m: Node) -> void:
	main = m
	dungeon = d
	ui_font = SystemFont.new()
	ui_font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "sans-serif"])
	_build_wall_bodies()

	actors_root = Node2D.new()
	add_child(actors_root)
	mobs = ArpgMobSystem.new()
	mobs.setup(main, self, dungeon)
	actors_root.add_child(mobs)
	projs = ArpgProjSystem.new()
	projs.setup(self)
	actors_root.add_child(projs)
	pickups = ArpgPickupSystem.new()
	pickups.setup(self)
	actors_root.add_child(pickups)

	fx_root = Node2D.new()
	fx_root.z_index = 40
	add_child(fx_root)


func _draw() -> void:
	if dungeon == null:
		return
	for x in dungeon.w:
		for y in dungeon.h:
			var r := Rect2(x * TILE, y * TILE, TILE, TILE)
			if dungeon.grid[x][y] == ArpgDungeon.FLOOR:
				draw_texture_rect_region(TEX_FLOOR, r, ArpgData.SRC_FLOOR)
			else:
				draw_texture_rect_region(TEX_WALL, r, ArpgData.SRC_WALL)


## 墙体碰撞：每行连续墙段合并成矩形碰撞体（只有玩家一个动态体用物理）
func _build_wall_bodies() -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	for y in dungeon.h:
		var run_start := -1
		for x in dungeon.w + 1:
			var is_wall: bool = x < dungeon.w and dungeon.grid[x][y] == ArpgDungeon.WALL
			if is_wall and run_start < 0:
				run_start = x
			elif not is_wall and run_start >= 0:
				var cs := CollisionShape2D.new()
				var shape := RectangleShape2D.new()
				shape.size = Vector2((x - run_start) * TILE, TILE)
				cs.shape = shape
				cs.position = Vector2((run_start + (x - run_start) / 2.0) * TILE, (y + 0.5) * TILE)
				body.add_child(cs)
				run_start = -1
	add_child(body)


func spawn_player(char_id: String) -> void:
	player = ArpgPlayer.new()
	player.setup(char_id, main, self)
	player.position = ArpgDungeon.cell_to_pos(dungeon.start_cell)
	actors_root.add_child(player)


# ———————— 实体门面 ————————

func spawn_mob(tpl_id: String, cell: Vector2i, elite: bool = false, boss: bool = false) -> int:
	return mobs.spawn(tpl_id, cell, elite, boss)


func mob_count() -> int:
	return mobs.count


## 扇形范围查询（近战）：含敌人自身半径
func mobs_in_arc(pos: Vector2, angle: float, reach: float, half_angle: float = 1.15) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in mobs.in_radius(pos, reach):
		var v := mobs.pos[i] - pos
		if v.length() <= reach + mobs.radius[i] and absf(angle - v.angle()) <= half_angle:
			out.append(i)
	return out


func mobs_in_radius(pos: Vector2, r: float) -> PackedInt32Array:
	return mobs.in_radius(pos, r)


## 伤害入口：浮动 + 火花 + 顿帧 + 震屏 + 震动；斩杀加重
func damage_mob(i: int, base: int, from: Vector2, knock: float = 150.0, heavy: bool = false) -> void:
	var dmg := maxi(1, roundi(base * randf_range(0.85, 1.15)))
	var lethal := dmg >= mobs.hp[i]
	spawn_hit_spark(mobs.pos[i] + (from - mobs.pos[i]).normalized() * -6.0, Color(1.0, 0.95, 0.75))
	main.add_shake(0.14 if not heavy else 0.22)
	main.hit_stop(0.09 if lethal else (0.055 if heavy else 0.035), 0.08 if lethal else 0.15)
	if lethal:
		main.rumble(0.35, 0.75, 0.26)
	else:
		main.rumble(0.1, 0.35 if heavy else 0.18, 0.12)
	mobs.damage(i, dmg, from, knock)


func spawn_projectile(p: Vector2, d: Vector2, speed: float, dmg: int, faction: String, tint: Color, kind: String = "orb") -> void:
	projs.spawn(p, d, speed, dmg, faction, tint, kind)


func spawn_pickup(p: Vector2, item_id: String) -> void:
	pickups.spawn(p, item_id)


func spawn_chest(cell: Vector2i) -> void:
	var c := ArpgChest.new()
	c.setup(main, self)
	c.position = ArpgDungeon.cell_to_pos(cell)
	actors_root.add_child(c)
	chests.append(c)


# ———————— 楼梯 / 传送门 ————————

func set_stairs(cell: Vector2i) -> void:
	stairs_cell = cell
	var s := StairNode.new()
	s.position = ArpgDungeon.cell_to_pos(cell)
	add_child(s)


func set_portal(pos: Vector2) -> void:
	portal_cell = Vector2i((pos / TILE).floor())
	var p := PortalNode.new()
	p.position = ArpgDungeon.cell_to_pos(portal_cell)
	add_child(p)


func portal_dist(pos: Vector2) -> float:
	if portal_cell.x < 0:
		return INF
	return ArpgDungeon.cell_to_pos(portal_cell).distance_to(pos)


class StairNode extends Node2D:
	func _draw() -> void:
		draw_rect(Rect2(-14, -12, 28, 26), Color(0.05, 0.04, 0.07), true)
		for i in 4:
			var w := 22.0 - i * 4.0
			draw_rect(Rect2(-w / 2, -10 + i * 6, w, 3), Color(0.35, 0.3, 0.28, 0.9), true)
		draw_rect(Rect2(-14, -12, 28, 26), Color(0, 0, 0, 0.6), false, 2.0)


class PortalNode extends Node2D:
	var t := 0.0

	func _process(delta: float) -> void:
		t += delta
		queue_redraw()

	func _draw() -> void:
		for i in 3:
			var r := 8.0 + i * 7.0
			var col := Color(0.6, 0.5, 1.0, 0.85 - i * 0.22)
			draw_arc(Vector2.ZERO, r, t * (1.5 + i), t * (1.5 + i) + TAU * 0.72, 24, col, 3.0)
		draw_circle(Vector2.ZERO, 5.0 + sin(t * 5.0) * 1.5, Color(0.9, 0.85, 1.0, 0.9))


# ———————— 特效（有上限池：超出释放最旧，保证帧率恒定） ————————

func _fx_guard() -> void:
	while fx_root.get_child_count() >= FX_CAP:
		fx_root.get_child(0).free()


func _popup_guard() -> void:
	while fx_root.get_child_count() >= FX_CAP + POPUP_CAP:
		fx_root.get_child(0).free()


## 通用贴图特效：出现 → 缩放 + 旋转扫动 + 淡出 → 自毁
func fx_tex(pos: Vector2, tex: Texture2D, rot: float, s0: float, s1: float, dur: float, tint: Color, sweep: float = 0.0, additive: bool = false) -> void:
	_fx_guard()
	var s := Sprite2D.new()
	s.texture = tex
	s.position = pos
	s.rotation = rot
	s.modulate = tint
	s.scale = Vector2.ONE * s0
	if additive:
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		s.material = mat
	fx_root.add_child(s)
	var tw := s.create_tween()
	tw.set_parallel(true)
	tw.tween_property(s, "scale", Vector2.ONE * s1, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(s, "rotation", rot + sweep, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(s, "modulate:a", 0.0, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(s.queue_free)


## 粒子爆发（一次性）
func burst(pos: Vector2, tex: Texture2D, tint: Color, amount: int, spd: float, life: float, psize: float) -> void:
	_fx_guard()
	var p := CPUParticles2D.new()
	p.position = pos
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 1.0
	p.texture = tex
	p.direction = Vector2.RIGHT
	p.spread = 180.0
	p.initial_velocity_min = spd * 0.45
	p.initial_velocity_max = spd
	p.gravity = Vector2.ZERO
	p.damping_min = spd * 1.2
	p.damping_max = spd * 2.2
	p.scale_amount_min = psize * 0.4
	p.scale_amount_max = psize
	p.color = tint
	fx_root.add_child(p)
	p.emitting = true
	get_tree().create_timer(life + 0.3).timeout.connect(p.queue_free)


## 近战剑气：Slash1 沿挥砍方向扫动
func spawn_slash(pos: Vector2, angle: float, col: Color = Color(1, 1, 1, 0.95)) -> void:
	var t := ArpgTex.tex(FX_SLASH_PATH)
	fx_tex(pos, t, angle + PI / 2.0, 0.55, 0.95, 0.20, col, 0.9)
	fx_tex(pos, t, angle + PI / 2.0 - 0.35, 0.35, 0.7, 0.16, Color(col.r, col.g, col.b, col.a * 0.6), 0.7)


## 冲击环
func spawn_nova(pos: Vector2, col: Color) -> void:
	_fx_guard()
	fx_tex(pos, ArpgTex.tex(FX_SHOCKWAVE_RING_PATH), randf() * TAU, 0.25, 1.7, 0.32, col, 0.0, true)
	fx_tex(pos, ArpgTex.tex(FX_RING_PATH), randf() * TAU, 0.2, 1.3, 0.28, Color(col.r, col.g, col.b, col.a * 0.7), 0.0, true)
	burst(pos, ArpgTex.tex(FX_PARTICLE_PATH), col, 10, 180.0, 0.4, 0.10)


## 命中火花
func spawn_hit_spark(pos: Vector2, col: Color) -> void:
	fx_tex(pos, ArpgTex.tex(FX_SHOCKWAVE_PATH), randf() * TAU, 0.12, 0.4, 0.16, Color(col.r, col.g, col.b, 0.9), 0.0, true)
	burst(pos, ArpgTex.tex(FX_PARTICLE_PATH), col, 7, 240.0, 0.3, 0.09)


## 死亡烟尘
func spawn_death_poof(pos: Vector2, col: Color) -> void:
	fx_tex(pos, ArpgTex.tex(FX_FOG_PATH), randf() * TAU, 0.4, 1.15, 0.38, Color(col.r, col.g, col.b, 0.75))
	burst(pos, ArpgTex.tex(FX_PARTICLE_PATH), Color(col.r, col.g, col.b, 0.9), 12, 150.0, 0.45, 0.11)


## 冲斩残影
func spawn_ghost(sprite: Sprite2D, pos: Vector2, col: Color) -> void:
	_fx_guard()
	var g := Sprite2D.new()
	g.texture = sprite.texture
	g.region_enabled = true
	g.region_rect = sprite.region_rect
	g.offset = sprite.offset
	g.scale = sprite.global_scale
	g.position = pos
	g.modulate = col
	g.z_index = 20
	fx_root.add_child(g)
	var tw := g.create_tween()
	tw.tween_property(g, "modulate:a", 0.0, 0.26).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_callback(g.queue_free)


func spawn_popup(text: String, pos: Vector2, col: Color) -> void:
	_popup_guard()
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", ui_font)
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 4)
	l.position = pos + Vector2(-14, -40)
	l.z_index = 60
	fx_root.add_child(l)
	var tw := l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position:y", l.position.y - 28.0, 0.7)
	tw.tween_property(l, "modulate:a", 0.0, 0.45).set_delay(0.25)
	tw.chain().tween_callback(l.queue_free)


static func cell_to_pos(c: Vector2i) -> Vector2:
	return Vector2(c) * float(ArpgData.TILE) + Vector2.ONE * (ArpgData.TILE * 0.5)
