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
var slow_t := 0.0                # 冰霜词缀减速剩余秒（命中时由 mob_system 设置）
var hurt_amp_t := 0.0            # 易伤词缀增伤剩余秒（受伤 ×1.3）
var burn_t := 0.0                # 燃烧 DoT 剩余秒
var burn_dps := 0.0              # 燃烧每秒伤害
var _burn_tick := 0.0            # 燃烧视觉节拍（0.6s 一次火色火花）
var dash_t := 0.0
var dash_dir := Vector2.DOWN
var dash_hit := {}
var dash_ghost_t := 0.0
# —— 耐力 / 方向闪避（影之刃方案批 3：Shift 闪避，前快短/后慢长/侧中等）——
var max_st := 100.0
var st := 100.0
var st_regen_t := 0.0           # 体力回复延迟（消耗动作后 0.6s 才开始回）
var dodge_t := 0.0
var dodge_dir := Vector2.DOWN
var dodge_spd := 0.0
var dodge_ghost_t := 0.0
# —— 弹反（影之刃方案批 4：Space 短窗口架势，连按惩罚，完美弹反重置）——
var parry_t := 0.0              # 弹反窗口剩余秒（>0 = 架势中）
var parry_elapsed := 0.0        # 本次窗口已进行时间（完美窗判定用）
var parry_perfect_until := 0.0  # 本次窗口的完美段阈值（elapsed <= 它 = 完美弹反）
var parry_mash_n := 0           # 0.4s 内连续按压次数（窗口缩小档位）
var parry_mash_t := 0.0         # 距上次按压的计时
var parry_cd := 0.0             # 空挥/普通弹反后的冷却
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
	max_st = float(ArpgBalance.data.get("stamina", {}).get("max", 100.0))
	st = max_st

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
	slow_t = maxf(0.0, slow_t - delta)
	hurt_amp_t = maxf(0.0, hurt_amp_t - delta)
	# 耐力回复：消耗动作后延迟 regen_delay 才开始回（防「消耗-瞬间回满」刷循环）
	if st_regen_t > 0.0:
		st_regen_t -= delta
	else:
		st = minf(max_st, st + float(ArpgBalance.data.get("stamina", {}).get("regen", 20.0)) * delta)
	# 弹反窗口/冷却/连按计时
	if parry_t > 0.0:
		parry_t -= delta
		parry_elapsed += delta
		if parry_t <= 0.0:
			parry_t = 0.0
			parry_cd = float(ArpgBalance.data.get("parry", {}).get("whiff_cd", 0.6))   # 空挥惩罚
	parry_cd = maxf(0.0, parry_cd - delta)
	parry_mash_t = maxf(0.0, parry_mash_t - delta)
	# 燃烧 DoT：每秒灼烧（绕护甲的持续伤害；触发死亡流程），0.6s 一次火色火花提示
	if burn_t > 0.0:
		burn_t = maxf(0.0, burn_t - delta)
		hp = maxi(0, hp - int(ceil(burn_dps * delta)))
		_burn_tick -= delta
		if _burn_tick <= 0.0:
			_burn_tick = 0.6
			main.world.spawn_hit_spark(position, Color(1.0, 0.5, 0.1))
		if hp <= 0 and not dead:
			dead = true
			main.on_player_dead()
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
	elif dodge_t > 0.0:
		# 方向闪避：匀速位移 + 绿白残影（无敌帧走 iframes，take_damage 自动豁免）
		dodge_t -= delta
		dodge_ghost_t -= delta
		if dodge_ghost_t <= 0.0:
			dodge_ghost_t = 0.035
			world.spawn_ghost(sprite, position + Vector2(0, -6), Color(0.85, 1.0, 0.9, 0.5))
		velocity = dodge_dir * dodge_spd
		_move_vel = dodge_dir * spd * 0.5
	elif stun > 0.0:
		velocity = knock
		_move_vel = Vector2.ZERO
	else:
		var target := dir * spd
		_move_vel = _move_vel.move_toward(target, (ACCEL if dir != Vector2.ZERO else FRICTION) * delta)
		# 冰霜减速：slow_t 期间移速 ×0.6（移动输入被冻僵的观感）
		var slow_mul := 0.6 if slow_t > 0.0 else 1.0
		velocity = _move_vel * slow_mul + knock + lunge
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
		if Input.is_action_just_pressed("dodge"):
			_do_dodge(dir)
		if Input.is_action_just_pressed("parry"):
			_do_parry()
		if Input.is_action_just_pressed("skill"):
			use_skill(0)
		if Input.is_action_just_pressed("skill2"):
			use_skill(1)
		if Input.is_action_just_pressed("skill3"):
			use_skill(2)

	if iframes > 0.0:
		sprite.visible = int(iframes * 14.0) % 2 == 0
	else:
		sprite.visible = true


## AI 移动执行：沿寻路路点走（与队友同构：迭代推进 + 提前跳点，不再递归）
func _ai_dir() -> Vector2:
	var guard := 0
	while ai_path_i < ai_path.size() and guard < 8:
		guard += 1
		var wp: Vector2 = ai_path[ai_path_i]
		var d := wp - position
		var dl := d.length()
		if dl < 18.0:
			ai_path_i += 1
			continue
		if ai_path_i + 1 < ai_path.size() and dl < 46.0 and main.party != null \
				and main.party.line_clear(position, ai_path[ai_path_i + 1]):
			ai_path_i += 1
			continue
		return d / dl
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
	if main.possession != null and is_instance_valid(main.possession.current_unit):
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


## 按等级重算派生属性：基础值 + 每级成长 ×(等级-1)，再叠加当前装备加成。
## 换层重建节点、读档后都必须走这里，否则 level 是 3 但 max_hp/atk 还是 1 级的值。
func apply_level_stats() -> void:
	var g: Dictionary = tpl.get("growth", {})
	var lv := maxi(level - 1, 0)
	max_hp = int(tpl.get("hp", max_hp)) + int(g.get("hp", 0)) * lv
	atk = int(tpl.get("atk", atk)) + int(g.get("atk", 0)) * lv
	equip_hp = 0
	recalc_equipment()
	hp = mini(hp, max_hp)
	refresh_bars()


## 血条/SP 条刷新（换层重建节点、恢复等级与装备加成后调用）
func refresh_bars() -> void:
	hp_bar.update_values(float(hp) / maxf(float(max_hp), 1.0), float(sp) / maxf(float(max_sp), 1.0))


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
	if main.threat != null:
		main.threat.on_skill(float(sp) / float(max_sp))   # 威胁值：放技能=嚣张信号
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
			var n_arrows := int(def.get("count", 5))
			var spread := float(def.get("spread_deg", 24.0))
			for i in n_arrows:
				world.spawn_projectile(position + facing * 14.0, facing.rotated(deg_to_rad(-spread + i * (2.0 * spread / float(n_arrows - 1 if n_arrows > 1 else 1)))),
					float(tpl["proj_spd"]), int(eff_atk() * mult), "player", Color(0.62, 1.0, 0.8), "arrow")
		"heal":
			var heal := int(max_hp * float(def.get("heal", 0.3)))
			hp = mini(max_hp, hp + heal)
			hp_bar.update_values(float(hp) / max_hp, float(sp) / max_sp)
			world.spawn_popup("+%d" % heal, position, Color(0.5, 1, 0.55))
			world.spawn_nova(position, Color(0.55, 1, 0.65))
			world.spawn_pxfx("heal", position + Vector2(0, -6), {"scale": 0.7, "speed": 1.3})
		_:
			pop(1.25, 0.85)
			for i in world.mobs_in_radius(position, 95.0):
				world.damage_mob(i, int(eff_atk() * mult), position, 300.0, true)
			for i in 12:
				world.spawn_projectile(position, Vector2.RIGHT.rotated(TAU * i / 12.0), 275.0, eff_atk(), "player", Color(1.0, 0.6, 0.28), "bullet")
			world.spawn_nova(position, Color(1.0, 0.55, 0.25))
			world.spawn_pxfx("mana", position, {"scale": 0.8, "speed": 1.5})
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


## 方向闪避（Shift）：前闪快而短 / 后闪慢而长且无敌帧更长 / 侧闪中等——方向取舍。
## 无敌帧复用 iframes（take_damage 自动豁免）；残影复用 world.spawn_ghost；
## 消耗耐力（不足拒绝）；成功闪避减压（threat.on_dodge，影之刃方案「闪避成功扣分」的映射）。
func _do_dodge(move_dir: Vector2) -> void:
	if dead or dodge_t > 0.0 or dash_t > 0.0 or stun > 0.0:
		return
	var dcfg: Dictionary = ArpgBalance.data.get("dodge", {})
	var cost := float(dcfg.get("cost", 25.0))
	if st < cost:
		world.spawn_popup("体力不足", position, Color(0.75, 0.75, 0.75))
		return
	# 方向分类：移动输入与朝向的点积 → 前/后/侧（无输入默认前闪）
	var d := move_dir.normalized() if move_dir.length_squared() > 0.001 else facing
	var dotv := d.dot(facing)
	var bname := "side"
	if dotv > 0.5:
		bname = "forward"
	elif dotv < -0.5:
		bname = "back"
	var bcfg: Dictionary = dcfg.get(bname, {})
	dodge_spd = float(bcfg.get("speed", 640.0))
	dodge_t = float(bcfg.get("time", 0.20))
	iframes = maxf(iframes, float(bcfg.get("iframes", 0.15)))
	dodge_dir = d
	dodge_ghost_t = 0.0
	st -= cost
	st_regen_t = float(ArpgBalance.data.get("stamina", {}).get("regen_delay", 0.6))
	pop(0.9, 1.1)
	main.play_sfx("attack", -12.0)
	# 成功闪避部分重置弹反连按惩罚（影之刃方案「闪避成功也重置一部分」）
	parry_mash_n = maxi(0, parry_mash_n - 1)
	if main.threat != null:
		main.threat.on_dodge()


## 弹反（Space）：短窗口架势——窗口内受击无效；前 45% 为完美段（硬直+SP/体力返还）。
## 连按惩罚：0.4s 内连续按压 → 窗口逐次 ×0.6（第三次近归零）；完美弹反清零惩罚；
## 空挥 0.6s 冷却。近战/敌弹/Boss 震地全走 take_damage，天然全部可弹反。
func _do_parry() -> void:
	if dead or stun > 0.0 or dash_t > 0.0 or dodge_t > 0.0:
		return
	var pcfg: Dictionary = ArpgBalance.data.get("parry", {})
	if parry_cd > 0.0:
		return
	var cost := float(pcfg.get("stamina_cost", 12.0))
	if st < cost:
		world.spawn_popup("体力不足", position, Color(0.75, 0.75, 0.75))
		return
	# 连按惩罚：距上次按压 0.4s 内再按 → 窗口逐次缩小
	if parry_mash_t > 0.0:
		parry_mash_n += 1
	else:
		parry_mash_n = 0
	parry_mash_t = float(pcfg.get("mash_window", 0.4))
	var win := float(pcfg.get("window", 0.24)) * pow(float(pcfg.get("mash_shrink", 0.6)), parry_mash_n)
	win = maxf(win, float(pcfg.get("min_window", 0.04)))
	parry_t = win
	parry_elapsed = 0.0
	parry_perfect_until = win * float(pcfg.get("perfect_frac", 0.45))
	st -= cost
	st_regen_t = float(ArpgBalance.data.get("stamina", {}).get("regen_delay", 0.6))
	pop(0.85, 1.05)


## 弹反结算（take_damage 窗口内调用）：perfect = 完美段内接敌
func _resolve_parry(dmg: int, from_pos: Vector2) -> void:
	var pcfg: Dictionary = ArpgBalance.data.get("parry", {})
	var perfect := parry_elapsed <= parry_perfect_until
	parry_t = 0.0
	if perfect:
		# 完美弹反：敌人硬直 + 惩罚清零 + SP/体力返还 + 顿帧（应对连按惩罚的「重置」）
		parry_mash_n = 0
		parry_cd = 0.0
		st = minf(max_st, st + float(pcfg.get("stamina_cost", 12.0)))
		sp = mini(max_sp, sp + int(pcfg.get("sp_refund", 8)))
		hp_bar.update_values(float(hp) / max_hp, float(sp) / max_sp)
		if world.mobs != null:
			world.mobs.stagger_nearest(from_pos, float(pcfg.get("stagger_t", 0.9)),
				float(pcfg.get("stagger_knock", 260.0)))
		world.spawn_popup("完美弹反！", position + Vector2(0, -36), Color(1.0, 0.85, 0.35), 22)
		world.spawn_nova(position, Color(1.0, 0.85, 0.4))
		main.hit_stop(0.08, 0.05)
		main.play_sfx("magic", -4.0)
		main.add_shake(0.25)
	else:
		# 普通弹反：仅抵消这一下，轻硬直 + 小冷却（连按惩罚不清零）
		parry_cd = float(pcfg.get("parry_cd", 0.3))
		if world.mobs != null:
			world.mobs.stagger_nearest(from_pos, float(pcfg.get("parry_stagger_t", 0.3)),
				float(pcfg.get("parry_stagger_knock", 120.0)))
		world.spawn_popup("弹反", position + Vector2(0, -36), Color(0.8, 0.88, 1.0), 18)
	main.rumble(0.3, 0.6, 0.2)
	if main.threat != null:
		main.threat.on_parry(perfect)   # 弹反成功减压（完美 -6 / 普通 -2）


# ———————— 受击 / 成长 ————————

func take_damage(dmg: int, from_pos: Vector2) -> void:
	if dead or iframes > 0.0 or main.state != main.State.PLAY:
		return
	# 弹反窗口：伤害无效——近战/敌弹/Boss 震地全走本入口，天然全部可弹反
	if parry_t > 0.0:
		_resolve_parry(dmg, from_pos)
		return
	# 易伤状态：受伤 ×1.3（brittle 词缀命中后 3s）
	if hurt_amp_t > 0.0:
		dmg = roundi(dmg * float(ArpgBalance.data.get("affixes", {}).get("brittle", {}).get("amp_mult", 1.3)))
	hp = maxi(0, hp - maxi(1, dmg - eff_def()))
	iframes = 0.55
	in_combat_until = 4.0
	if main.threat != null:
		main.threat.on_player_hurt()   # 威胁值：受击=压力信号（只有真实命中的这口算）
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
