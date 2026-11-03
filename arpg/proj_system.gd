class_name ArpgProjSystem
extends Node2D
## 投射物数据系统：SoA 数组 + 主线程步进（数量有限）+ 批次渲染。
## 玩家弹命中查 MobSystem 的空间哈希（O(1) 邻域），敌方弹查玩家圆。容量 800，超出淘汰最旧。

const MAX := 800
const TILE := ArpgData.TILE

var world: Node

var count := 0
var pos := PackedVector2Array()
var dir := PackedVector2Array()
var spd := PackedFloat32Array()
var dmg := PackedInt32Array()
var faction := PackedByteArray()      # 0 player 1 enemy
var kind := PackedByteArray()         # 0 orb 1 arrow 2 bullet
var tint := PackedColorArray()
var life := PackedFloat32Array()
var alive := PackedByteArray()

var _tex_arrow: Texture2D
var _tex_circle: Texture2D
var _tex_particle: Texture2D


func setup(w: Node) -> void:
	world = w
	pos.resize(MAX)
	dir.resize(MAX)
	spd.resize(MAX)
	dmg.resize(MAX)
	faction.resize(MAX)
	kind.resize(MAX)
	tint.resize(MAX)
	life.resize(MAX)
	alive.resize(MAX)
	_tex_arrow = ArpgTex.tex("res://assets/fx/Arrow.png")
	_tex_circle = ArpgTex.tex("res://assets/fx/Circle.png")
	_tex_particle = ArpgTex.tex("res://assets/fx/Particle100.png")


func spawn(p: Vector2, d: Vector2, speed: float, dmg_v: int, fac: String, t: Color, k: String) -> void:
	var i := -1
	if count < MAX:
		i = count
		count += 1
	else:
		# 池满：抢最旧的一格
		for j in count:
			if alive[j] == 1:
				i = j
				break
		if i < 0:
			return
	alive[i] = 1
	pos[i] = p
	dir[i] = d.normalized()
	spd[i] = speed
	dmg[i] = dmg_v
	faction[i] = 0 if fac == "player" else 1
	kind[i] = 1 if k == "arrow" else (2 if k == "bullet" else 0)
	tint[i] = t
	life[i] = 1.9


func _physics_process(delta: float) -> void:
	if world.main == null or world.main.state != world.main.State.PLAY:
		return
	var pl = world.player
	for i in count:
		if alive[i] == 0:
			continue
		# —— 扫掠步进：弹丸这一帧走的是「线段 p0→p1」，命中/撞墙都按线段判定 ——
		# 旧实现只判 p1 这一个点：高速弹（430px/s ≈ 7px/帧，掉帧时 14px+）会整帧
		# 跨过目标（目标圆直径 ~20px）而不触发命中，表现为"从怪身上穿过去没伤害"。
		var p0: Vector2 = pos[i]
		var p1: Vector2 = p0 + dir[i] * spd[i] * delta
		pos[i] = p1
		life[i] -= delta
		if life[i] <= 0.0:
			alive[i] = 0
			continue
		if not _seg_open(p0, p1):
			world.burst(p1, ArpgTex.tex(ArpgWorld.FX_PARTICLE_PATH), tint[i], 4, 120.0, 0.22, 0.07)
			alive[i] = 0
			continue
		if faction[i] == 0:
			var hit := _sweep_mob(p0, p1, 7.0)
			if hit >= 0:
				world.damage_mob(hit, dmg[i], pos[i], 120.0)
				alive[i] = 0
		else:
			if pl != null and not pl.dead and _seg_hits(p0, p1, pl.position, 15.0):
				pl.take_damage(dmg[i], pos[i])
				alive[i] = 0
			elif world.main.party != null:
				# 敌方弹也会打队友（AI 队友/APC 同样处于危险中）
				for f in world.main.party.friends:
					if is_instance_valid(f) and not f.dead and _seg_hits(p0, p1, f.position, 13.0):
						f.take_damage(dmg[i], pos[i])
						alive[i] = 0
						break
	# 紧凑化
	var j2 := 0
	for i in count:
		if alive[i] == 1:
			if j2 != i:
				_copy(i, j2)
			j2 += 1
	count = j2
	queue_redraw()


## 线段是否全程在地板格上（12px 采样）：高速弹一帧能跨半格，只查端点会漏墙
func _seg_open(a: Vector2, b: Vector2) -> bool:
	var dv := b - a
	var steps := int(dv.length() / 12.0) + 1
	var step := dv / float(steps)
	var p := a
	for s in steps:
		p += step
		if not world.dungeon.is_floor(Vector2i((p / float(TILE)).floor())):
			return false
	return true


## 线段 → 敌人（取沿路径最先命中的那一只）；用空间哈希取候选，再对候选做圆-线段判定
func _sweep_mob(a: Vector2, b: Vector2, r: float) -> int:
	if world.mobs == null or world.mobs.count == 0:
		return -1
	var mid := (a + b) * 0.5
	var reach := a.distance_to(b) * 0.5 + r + 26.0
	var best := -1
	var best_d := 1e18
	for j in world.mobs.in_radius(mid, reach):
		var c: Vector2 = world.mobs.pos[j]
		var cp: Vector2 = Geometry2D.get_closest_point_to_segment(c, a, b)
		if cp.distance_to(c) > r + world.mobs.radius[j]:
			continue
		var along := a.distance_squared_to(cp)
		if along < best_d:
			best_d = along
			best = j
	return best


## 线段 → 圆形单位（玩家/队友）
func _seg_hits(a: Vector2, b: Vector2, c: Vector2, r: float) -> bool:
	return Geometry2D.get_closest_point_to_segment(c, a, b).distance_to(c) <= r


func _copy(src: int, dst: int) -> void:
	pos[dst] = pos[src]
	dir[dst] = dir[src]
	spd[dst] = spd[src]
	dmg[dst] = dmg[src]
	faction[dst] = faction[src]
	kind[dst] = kind[src]
	tint[dst] = tint[src]
	life[dst] = life[src]
	alive[dst] = 1


func _draw() -> void:
	for i in count:
		if alive[i] == 0:
			continue
		var t: Color = tint[i]
		match kind[i]:
			1:
				# 箭矢：贴图朝上，旋转对齐方向；贴图视觉中心约 (128,182)，偏移修正
				draw_set_transform(pos[i], dir[i].angle() + PI / 2.0, Vector2.ONE * 0.32)
				draw_texture_rect_region(_tex_arrow, Rect2(Vector2(-128, -128 - 54), Vector2(256, 256)), Rect2(0, 0, 256, 256), t)
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			2:
				draw_circle(pos[i], 5.5, Color(t.r, t.g, t.b, 0.35))
				draw_circle(pos[i], 3.5, t)
			_:
				var pulse := 10.5 + sin(Time.get_ticks_msec() * 0.018 + i * 1.7) * 1.5
				draw_circle(pos[i], pulse + 4.0, Color(t.r, t.g, t.b, 0.25))
				draw_circle(pos[i], pulse, t)
