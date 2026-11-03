class_name ArpgPlayer
extends CharacterBody2D
## 玩家：加速度移动（起步/刹车有过渡）+ 攻击前冲 + 冲刺残影 + squash&stretch。
## 三种武器手感：melee 近战弧斩 / ranged 射箭 / magic 法弹。

const DIR_ROW := {"down": 0, "left": 1, "right": 2, "up": 3}
const WALK_SEQ := [0, 1, 2, 1]
const ACCEL := 2600.0        # 起步加速度（越大越跟手）
const FRICTION := 2100.0     # 松手刹车
const DASH_SPEED := 690.0
const DASH_TIME := 0.19

var main: Node
var world: Node

var uid := "player"
var faction := "player"      # 事件引擎 zone 触发按阵营过滤
var uname := ""
var command := "follow"

## 事件引擎（zone 触发）用：实时换算所在格（main._process 跨格时上报）
var cell: Vector2i:
	get:
		return Vector2i((position / float(ArpgData.TILE)).floor())
var command_queue: ArpgCommandQueue
var ai: ArpgAIController          # 被切下主控时的大脑（与队友同一套）
var state := "idle"               # 调试面板用
var in_combat_until := 0.0

# AI 执行接口（AIController 写入，physics 消费）——与 ArpgFriendUnit 同构
var ai_goal := Vector2.ZERO
var ai_has_goal := false
var ai_path := PackedVector2Array()
var ai_path_i := 0
var ai_attack_pos := Vector2.ZERO
var ai_want_attack := false
var ai_want_skill := false
var ai_face := Vector2.ZERO
var ai_target := -1            # 当前索敌 mob 下标（调试用）
var _think_t := 0.0

var char_id := "fencer"
var tpl := {}
var level := 1
var xp := 0
var equip_hp := 0            # 装备 HP 上限增量（换装回退再加）
var dash_dmg_mult := 1.7     # 冲斩倍率（技能表参数化）
var max_hp := 100
var hp := 100
var max_sp := 50
var sp := 50
var atk := 10
var spd := 150.0
var atk_range := 38.0

var facing := Vector2.DOWN
var facing_name := "down"
var dead := false

var atk_timer := 0.0
var skill_cd := 0.0
var stun := 0.0
var iframes := 0.0
var dash_t := 0.0
var dash_dir := Vector2.DOWN
var dash_hit := {}
var dash_ghost_t := 0.0
var lunge := Vector2.ZERO       # 攻击前冲冲量
var knock := Vector2.ZERO
var _move_vel := Vector2.ZERO   # 平滑移动分量（不含击退/前冲）

var sprite: Sprite2D
var hp_bar: HpBar
var block := Vector2i.ZERO
var _walk_t := 0.0
var _moving := false


class HpBar extends Node2D:
	var ratio := 1.0
	var sp_ratio := 1.0

	func update_values(hp_ratio: float, sp_ratio_: float) -> void:
		ratio = clampf(hp_ratio, 0.0, 1.0)
		sp_ratio = clampf(sp_ratio_, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		var bw := 34.0
		draw_rect(Rect2(-bw / 2, -30, bw, 5), Color(0.05, 0.05, 0.09, 0.9), true)
		var col := Color(0.35, 0.85, 0.35)
		if ratio <= 0.25:
			col = Color(0.9, 0.25, 0.2)
		elif ratio <= 0.5:
			col = Color(0.95, 0.8, 0.25)
		draw_rect(Rect2(-bw / 2, -30, bw * ratio, 5), col, true)
		draw_rect(Rect2(-bw / 2, -24, bw * sp_ratio, 3), Color(0.4, 0.65, 1.0), true)


func setup(id: String, m: Node, w: Node) -> void:
	main = m
	world = w
	char_id = id
	tpl = ArpgBalance.CHARS[id]
	uname = tpl["name"]
	max_hp = tpl["hp"]
	hp = max_hp
	max_sp = tpl["sp"]
	sp = max_sp
	atk = tpl["atk"]
	spd = float(tpl["spd"])
	atk_range = float(tpl["atk_range"])

	command_queue = ArpgCommandQueue.new()
	command_queue.push("follow")
	ai = ArpgAIController.new()

	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	collision_layer = 2
	collision_mask = 1
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 9.0
	cs.shape = shape
	add_child(cs)

	block = Vector2i(tpl["sprite"][1], tpl["sprite"][2])
	sprite = Sprite2D.new()
	sprite.texture = load(tpl["sprite"][0])
	sprite.region_enabled = true
	sprite.region_rect = Rect2(block.x, block.y, 48, 48)
	sprite.offset = Vector2(0, -5)
	add_child(sprite)

	hp_bar = HpBar.new()
	add_child(hp_bar)
	hp_bar.update_values(1.0, 1.0)
	_set_frame(0)


func _physics_process(delta: float) -> void:
	if dead or main.state != main.State.PLAY:
		velocity = Vector2.ZERO
		return
	atk_timer = maxf(0.0, atk_timer - delta)
	skill_cd = maxf(0.0, skill_cd - delta)
	stun = maxf(0.0, stun - delta)
	iframes = maxf(0.0, iframes - delta)
	if in_combat_until > 0.0:
		in_combat_until -= delta

	var possessed: bool = main.possession == null or main.possession.is_possessed(self)
	var dir := Vector2.ZERO
	if possessed:
		dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	else:
		# —— 被切下主控：AI 接管（同一套 ArpgAIController）——
		_think_t += delta * _think_mult()
		if _think_t >= float(ArpgPartyConfig.cfg("think_interval")):
			_think_t = 0.0
			if ai != null:
				ai.think(self, main, delta)
		dir = _ai_dir()
		if main.party != null:
			var sep := Vector2.ZERO
			for other in main.party.friends:
				if not is_instance_valid(other) or other.dead:
					continue
				var dsp: Vector2 = position - other.position
				var lsp: float = dsp.length()
				if lsp < 28.0 and lsp > 0.01:
					sep += dsp / lsp * (1.0 - lsp / 28.0)
			# 与敌群也推开（AI 态玩家不再和怪叠影）
			if world != null and world.mobs != null:
				var mi: int = world.mobs.nearest(position, 40.0)
				if mi >= 0:
					var dm: Vector2 = position - world.mobs.pos[mi]
					var lm: float = dm.length()
					if lm < 28.0 and lm > 0.01:
						sep += dm / lm * (1.0 - lm / 28.0) * 0.9
			dir = (dir + sep).normalized() if (dir + sep).length_squared() > 0.001 else dir
		if ai_want_attack:
			ai_want_attack = false
			try_attack(ai_attack_pos)
		if ai_want_skill:
			ai_want_skill = false
			try_skill(ai_attack_pos)

	if dash_t > 0.0:
		# 冲刺：匀速突进 + 残影
		dash_t -= delta
		dash_ghost_t -= delta
		if dash_ghost_t <= 0.0:
			dash_ghost_t = 0.035
			world.spawn_ghost(sprite, position + Vector2(0, -6), Color(0.72, 0.88, 1.0, 0.55))
		velocity = dash_dir * DASH_SPEED
		_move_vel = dash_dir * spd * 0.5   # 冲刺结束保留部分动量，衔接更顺
		_dash_hits()
	elif stun > 0.0:
		velocity = knock
		_move_vel = Vector2.ZERO
	else:
		var target := dir * spd
		_move_vel = _move_vel.move_toward(target, (ACCEL if dir != Vector2.ZERO else FRICTION) * delta)
		velocity = _move_vel + knock + lunge
		if dir != Vector2.ZERO:
			facing = dir.normalized()
			_update_facing_name(dir)
	knock = knock.move_toward(Vector2.ZERO, 1100.0 * delta)
	lunge = lunge.move_toward(Vector2.ZERO, 1500.0 * delta)
	move_and_slide()
	_moving = dir != Vector2.ZERO and stun <= 0.0
	_animate(delta)

	if stun <= 0.0 and possessed:
		if Input.is_action_just_pressed("attack") and atk_timer <= 0.0:
			_do_attack()
		if Input.is_action_just_pressed("skill"):
			use_skill(0)
		if Input.is_action_just_pressed("skill2"):
			use_skill(1)

	if iframes > 0.0:
		sprite.visible = int(iframes * 14.0) % 2 == 0
	else:
		sprite.visible = true


## AI 移动执行：沿寻路路点走（与队友同构）
func _ai_dir() -> Vector2:
	if ai_path_i < ai_path.size():
		var wp := ai_path[ai_path_i]
		if position.distance_to(wp) < 22.0:
			ai_path_i += 1
			return _ai_dir()
		return (wp - position).normalized()
	if ai_has_goal:
		var g := ai_goal - position
		if g.length() < 12.0:
			ai_has_goal = false
			state = "idle"
			return Vector2.ZERO
		state = "move"
		return g.normalized()
	return Vector2.ZERO


## 离主控单位越远，思考越稀疏（性能 LOD，需求书 §6）
func _think_mult() -> float:
	var ref := position
	if main.possession != null and main.possession.current_unit != null:
		ref = main.possession.current_unit.position
	if position.distance_to(ref) > float(ArpgPartyConfig.cfg("far_unit_distance")):
		return float(ArpgPartyConfig.cfg("far_think_multiplier"))
	return 1.0


## AI 攻击包装（AIController 调用）
func try_attack(target_pos: Vector2) -> void:
	if atk_timer > 0.0:
		return
	var to_t := target_pos - position
	if to_t.length_squared() > 1.0:
		facing = to_t.normalized()
		_update_facing_name(to_t)
	_do_attack()


func try_skill(target_pos: Vector2) -> void:
	if skill_cd > 0.0:
		return
	var to_t := target_pos - position
	if to_t.length_squared() > 1.0:
		facing = to_t.normalized()
		_update_facing_name(to_t)
	use_skill(0)


func heal_flash() -> void:
	hp_bar.update_values(float(hp) / max_hp, float(sp) / max_sp)
	sprite.modulate = Color(0.55, 1, 0.65)
	var tw := create_tween()
	tw.tween_property(sprite, "modulate", Color.WHITE, 0.25)


func teleport_to(p: Vector2) -> void:
	position = p
	knock = Vector2.ZERO
	_move_vel = Vector2.ZERO
	ai_path.clear()
	ai_path_i = 0
	ai_has_goal = false


func _update_facing_name(d: Vector2) -> void:
	if absf(d.x) > absf(d.y):
		facing_name = "right" if d.x > 0 else "left"
	else:
		facing_name = "down" if d.y > 0 else "up"


func _animate(delta: float) -> void:
	if _moving:
		_walk_t += delta
		_set_frame(WALK_SEQ[int(_walk_t / 0.11) % 4])
	else:
		_walk_t = 0.0
		_set_frame(0)
	# 待机呼吸：轻微上下浮动（移动时不叠加）
	if not _moving and dash_t <= 0.0:
		sprite.offset.y = -5.0 + sin(Time.get_ticks_msec() * 0.0045) * 1.3
	else:
		sprite.offset.y = -5.0


func _set_frame(f: int) -> void:
	var row: int = DIR_ROW[facing_name]
	sprite.region_rect = Rect2(block.x + f * 48, block.y + row * 48, 48, 48)


## squash & stretch：压扁后弹回（保留体积感）
func pop(sx: float, sy: float) -> void:
	sprite.scale = Vector2(sx, sy)
	var tw := sprite.create_tween()
	tw.tween_property(sprite, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# ———————— 普攻 ————————

func _do_attack() -> void:
	atk_timer = float(tpl["atk_cd"])
	var weapon: String = tpl["weapon"]
	if weapon == "melee":
		lunge = facing * 210.0            # 攻击带一小段前冲，出刀更"扎"
		pop(1.14, 0.9)
		world.spawn_slash(position + facing * 13.0, facing.angle())
		for i in world.mobs_in_arc(position, facing.angle(), atk_range):
			world.damage_mob(i, eff_atk(), position)
	elif weapon == "ranged":
		lunge = -facing * 70.0            # 射击微微后坐
		world.spawn_projectile(position + facing * 14.0, facing, float(tpl["proj_spd"]), eff_atk(), "player", Color(1.0, 0.92, 0.55), "arrow")
	else:
		lunge = -facing * 50.0
		world.spawn_projectile(position + facing * 14.0, facing, float(tpl["proj_spd"]), eff_atk(), "player", Color(0.85, 0.55, 1.0), "orb")
	world.main.play_sfx("magic" if weapon == "magic" else "attack", -10.0 if weapon == "magic" else -6.0)


# ———————— 技能系统 v2（数据驱动：balance.skills + char_skills + 等级解锁） ————————

func use_skill(slot: int) -> void:
	var ids: Array = available_skills()
	if slot >= ids.size():
		return
	var def: Dictionary = ArpgBalance.data.get("skills", {}).get(str(ids[slot]), {})
	if def.is_empty() or skill_cd > 0.0 or stun > 0.0:
		return
	if sp < int(def["sp"]):
		world.spawn_popup("SP不足", position, Color(0.6, 0.8, 1.0))
		return
	sp -= int(def["sp"])
	skill_cd = float(def["cd"])
	var mult := float(def.get("dmg_mult", 1.0))
	var kind := str(def.get("kind", "nova"))
	match kind:
		"dash":
			dash_t = DASH_TIME
			dash_dir = facing
			dash_hit = {}
			dash_ghost_t = 0.0
			dash_dmg_mult = mult
			pop(1.3, 0.75)
			world.spawn_slash(position + facing * 10.0, facing.angle(), Color(0.75, 0.92, 1.0))
		"volley":
			lunge = -facing * 130.0
			pop(0.9, 1.1)
			for i in 5:
				world.spawn_projectile(position + facing * 14.0, facing.rotated(deg_to_rad(-24.0 + i * 12.0)),
					float(tpl["proj_spd"]), int(eff_atk() * mult), "player", Color(0.62, 1.0, 0.8), "arrow")
		"heal":
			var heal := int(max_hp * float(def.get("heal", 0.3)))
			hp = mini(max_hp, hp + heal)
			hp_bar.update_values(float(hp) / max_hp, float(sp) / max_sp)
			world.spawn_popup("+%d" % heal, position, Color(0.5, 1, 0.55))
			world.spawn_nova(position, Color(0.55, 1, 0.65))
		_:
			pop(1.25, 0.85)
			for i in world.mobs_in_radius(position, 95.0):
				world.damage_mob(i, int(eff_atk() * mult), position, 300.0, true)
			for i in 12:
				world.spawn_projectile(position, Vector2.RIGHT.rotated(TAU * i / 12.0), 275.0, eff_atk(), "player", Color(1.0, 0.6, 0.28), "bullet")
			world.spawn_nova(position, Color(1.0, 0.55, 0.25))
	main.play_sfx("fire" if kind == "nova" else "skill")
	main.rumble(0.22, 0.48, 0.2)
	if kind == "nova":
		main.add_shake(0.3)


func _dash_hits() -> void:
	for i in world.mobs_in_radius(position, 30.0):
		if dash_hit.has(i):
			continue
		dash_hit[i] = true
		world.damage_mob(i, int(eff_atk() * dash_dmg_mult), position, 260.0, true)


# ———————— 受击 / 成长 ————————

func take_damage(dmg: int, from_pos: Vector2) -> void:
	if dead or iframes > 0.0 or main.state != main.State.PLAY:
		return
	hp = maxi(0, hp - maxi(1, dmg - eff_def()))
	iframes = 0.55
	in_combat_until = 4.0
	knock = (position - from_pos).normalized() * 250.0
	_move_vel = Vector2.ZERO
	dash_t = 0.0                    # 受击打断冲刺
	sprite.modulate = Color(1, 0.35, 0.35)
	pop(1.2, 0.8)
	var tw := create_tween()
	tw.tween_property(sprite, "modulate", Color.WHITE, 0.25)
	world.spawn_popup("-%d" % dmg, position, Color(1, 0.5, 0.4))
	world.spawn_hit_spark(position, Color(1, 0.5, 0.4))
	world.main.play_sfx("damage")
	world.main.add_shake(0.34)
	world.main.hit_stop(0.06, 0.1)
	world.main.rumble(0.4, 0.85, 0.3)
	hp_bar.update_values(float(hp) / max_hp, float(sp) / max_sp)
	if hp <= 0:
		dead = true
		main.on_player_dead()


## 装备派生属性（装备系统）：背包/装备挂在 RPG 元状态层
func eff_atk() -> int:
	return atk + main.rpg.equip_bonus("atk")


func eff_def() -> int:
	return main.rpg.equip_bonus("def")


func recalc_equipment() -> void:
	var bonus: int = main.rpg.equip_bonus("hp")
	max_hp = max_hp - equip_hp + bonus
	equip_hp = bonus
	hp = mini(hp, max_hp)
	hp_bar.update_values(float(hp) / max_hp, float(sp) / max_sp)


## 已解锁技能（等级 + 职业技能表，技能系统 v2）
func available_skills() -> Array:
	var ids: Array = ArpgBalance.data.get("char_skills", {}).get(char_id, [])
	var out := []
	for sid in ids:
		var def: Dictionary = ArpgBalance.data.get("skills", {}).get(str(sid), {})
		if not def.is_empty() and level >= int(def.get("unlock_level", 1)):
			out.append(sid)
	return out


func gain_xp(x: int) -> void:
	xp += x
	while xp >= ArpgBalance.xp_need(level):
		xp -= ArpgBalance.xp_need(level)
		level += 1
		var g: Dictionary = tpl["growth"]
		max_hp += int(g["hp"])
		atk += int(g["atk"])
		hp = max_hp          # 升级完全回满（策划案核心爽点）
		sp = max_sp
		hp_bar.update_values(1.0, 1.0)
		for sid in available_skills():
			var sd: Dictionary = ArpgBalance.data.get("skills", {}).get(str(sid), {})
			if int(sd.get("unlock_level", 99)) == level:
				world.spawn_popup("解锁技能「%s」！" % sd.get("name", sid), position + Vector2(0, -52), Color(0.7, 0.95, 1.0))
		world.spawn_popup("LEVEL UP!", position + Vector2(0, -30), Color(1, 0.9, 0.3))
		world.spawn_nova(position, Color(1, 0.95, 0.5))
		pop(0.8, 1.25)
		world.main.play_sfx("heal")
		world.main.rumble(0.2, 0.55, 0.3)


func restore_sp(v: int) -> void:
	sp = mini(max_sp, sp + v)
	hp_bar.update_values(float(hp) / max_hp, float(sp) / max_sp)


func set_stun(t: float) -> void:
	stun = maxf(stun, t)
