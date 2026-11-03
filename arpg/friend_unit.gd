class_name ArpgFriendUnit
extends CharacterBody2D
## 友方单位基类（需求书 §7 FriendUnit）：AI 队友与 APC 共享，能力靠 tags 区分。
## 被主控时读玩家输入；否则由 ArpgAIController 驱动（决策与执行分离）。
## 战斗/拾取/跟随/避障/卡住恢复全部内置；死亡 → 换层按配置复活。

const DIR_ROW := {"down": 0, "left": 1, "right": 2, "up": 3}
const WALK_SEQ := [0, 1, 2, 1]

var uid := ""                  # 稳定 ID（存档用）：friend_1 / apc_1
var tpl := {}                  # 模板引用（成长/技能读取）
var unit_name := ""
var char_id := ""              # 角色模板 id；APC 为 "apc:标签id"
var is_apc := false
var tags := {}                 # APC 能力标签（can_command/can_possess/counts_to_cap/temporary）

var max_hp := 100
var hp := 100
var max_sp := 50
var sp := 50
var atk := 10
var spd := 150.0
var atk_range := 38.0
var weapon := "melee"
var proj_spd := 400.0

var command := "follow"        # active / follow / hold（指令队列头，见 ArpgCommandQueue）
var command_queue: ArpgCommandQueue
var ai: ArpgAIController       # 决策器（主线程 tick）
var level := 1
var xp := 0

var dead := false
var state := "idle"            # idle/move/attack/pickup/retreat/dead/stuck（调试面板用）
var ai_target := -1            # 当前索敌的 mob 下标（调试用）
var in_combat_until := 0.0     # 被攻击后的战斗状态计时

# AI 执行接口（controller 写入，physics 消费）
var ai_goal := Vector2.ZERO
var ai_has_goal := false
var ai_path := PackedVector2Array()
var ai_path_i := 0
var ai_repath_t := 0.0
var ai_attack_pos := Vector2.ZERO
var ai_want_attack := false
var ai_want_skill := false
var ai_face := Vector2.ZERO

var atk_timer := 0.0
var skill_cd := 0.0
var iframes := 0.0
var knock := Vector2.ZERO
var lunge := Vector2.ZERO
var _move_vel := Vector2.ZERO
var _speed_scale := 1.0        # 到达减速（避免"冲过头—回头"抖动）
var _slide_bias := Vector2.ZERO  # 贴墙时的切向偏置（下一拍混入方向，治"顶墙原地抖"）
var _slide_t := 0.0

var main: Node
var world: Node
var sprite: Sprite2D
var hp_bar: HpBar
var block := Vector2i.ZERO
var facing_name := "down"
var _walk_t := 0.0
var _moving := false
var _think_t := 0.0


## 离主控单位越远，思考越稀疏（性能 LOD，需求书 §6）
func _think_mult() -> float:
	var ref := position
	if main.possession != null and is_instance_valid(main.possession.current_unit):
		ref = main.possession.current_unit.position
	if position.distance_to(ref) > float(ArpgPartyConfig.cfg("far_unit_distance")):
		return float(ArpgPartyConfig.cfg("far_think_multiplier"))
	return 1.0


class HpBar extends Node2D:
	var ratio := 1.0

	func set_ratio(r: float) -> void:
		ratio = clampf(r, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		var bw := 30.0
		draw_rect(Rect2(-bw / 2, -29, bw, 4), Color(0.05, 0.05, 0.09, 0.9), true)
		var col := Color(0.4, 0.7, 1.0)
		if ratio <= 0.25:
			col = Color(0.9, 0.3, 0.25)
		draw_rect(Rect2(-bw / 2, -29, bw * ratio, 4), col, true)


func setup(m: Node, w: Node, unit_uid: String, template: Dictionary, apc: bool, unit_tags: Dictionary) -> void:
	main = m
	world = w
	uid = unit_uid
	tpl = template
	is_apc = apc
	tags = unit_tags
	char_id = template.get("id", uid)
	unit_name = template["name"]
	max_hp = template["hp"]
	hp = max_hp
	max_sp = template.get("sp", 50)
	sp = max_sp
	atk = template["atk"]
	spd = float(template["spd"])
	atk_range = float(template.get("atk_range", 38.0))
	weapon = template.get("weapon", "melee")
	proj_spd = float(template.get("proj_spd", 400.0))
	command_queue = ArpgCommandQueue.new()
	command_queue.push("follow")
	# 决策节拍错相：多名队友不在同一帧思考（避免同帧寻路尖峰 + 集体同步动作）
	_think_t = randf() * float(ArpgPartyConfig.cfg("think_interval"))

	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	collision_layer = 2
	collision_mask = 1
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 9.0
	cs.shape = shape
	add_child(cs)

	block = Vector2i(template["sprite"][1], template["sprite"][2])
	sprite = Sprite2D.new()
	sprite.texture = ArpgTex.tex(template["sprite"][0])
	sprite.region_enabled = true
	sprite.region_rect = Rect2(block.x, block.y, 48, 48)
	sprite.offset = Vector2(0, -5)
	add_child(sprite)

	hp_bar = HpBar.new()
	add_child(hp_bar)
	hp_bar.set_ratio(1.0)
	_set_frame(0)


func _physics_process(delta: float) -> void:
	if dead:
		velocity = Vector2.ZERO
		return
	atk_timer = maxf(0.0, atk_timer - delta)
	skill_cd = maxf(0.0, skill_cd - delta)
	iframes = maxf(0.0, iframes - delta)
	sp = mini(max_sp, sp + int(float(ArpgPartyConfig.cfg("friend_sp_regen")) * delta))

	var dir := Vector2.ZERO
	if main.possession.is_possessed(self):
		_speed_scale = 1.0
		dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
		if dir != Vector2.ZERO:
			facing_name = _dir_name(dir)
		if Input.is_action_just_pressed("attack") and atk_timer <= 0.0:
			try_attack(position + _face_vec() * 20.0)
		if Input.is_action_just_pressed("skill") and skill_cd <= 0.0:
			try_skill(position + _face_vec() * 20.0)
	else:
		# —— AI 驱动：决策器按节拍思考，这里负责执行 ——
		_think_t += delta * _think_mult()
		if _think_t >= float(ArpgPartyConfig.cfg("think_interval")):
			_think_t = 0.0
			if ai != null:
				ai.think(self, main, delta)
		dir = _ai_dir(delta)
		if ai_want_attack:
			ai_want_attack = false
			try_attack(ai_attack_pos)
		if ai_want_skill:
			ai_want_skill = false
			try_skill(ai_attack_pos)
	# 贴墙切向偏置：上一帧撞墙 → 这一帧沿墙面滑走，而不是继续直顶。
	# （直顶时位移≈0、朝向反复，既"看着像卡住"，也让原有的卡住判定拿不到进展）
	if _slide_t > 0.0:
		_slide_t = maxf(0.0, _slide_t - delta)
		if dir.length_squared() > 0.001:
			var blended: Vector2 = dir + _slide_bias * 0.85
			if blended.length_squared() > 0.0001:
				dir = blended.normalized()
	knock = knock.move_toward(Vector2.ZERO, 1000.0 * delta)
	lunge = lunge.move_toward(Vector2.ZERO, 1500.0 * delta)
	velocity = dir * spd * _speed_scale + knock + lunge + _separation(dir.length_squared() > 0.001) * spd * 0.65
	move_and_slide()
	_update_slide(dir)
	_moving = dir.length_squared() > 0.001
	_animate(delta)
	if in_combat_until > 0.0:
		in_combat_until -= delta


## AI 移动执行：沿寻路路点走（新路径首拍做一次拉直）
## 迭代推进而非递归：到达 / 可直视下一点 → 直接跳过，切角更少、不会栈溢出
func _ai_dir(_delta: float) -> Vector2:
	_speed_scale = 1.0
	if main == null or main.party == null:
		return Vector2.ZERO
	if ai_path_i == 0 and ai_path.size() > 1:
		ai_path = main.party.smooth_path(position, ai_path)
	var guard := 0
	while ai_path_i < ai_path.size() and guard < 8:
		guard += 1
		var wp: Vector2 = ai_path[ai_path_i]
		var d := wp - position
		var dl := d.length()
		if dl < 18.0:
			ai_path_i += 1
			continue
		# 提前跳点：到当前点已能直视下一个点 → 不必走到点上再拐（治"蹭墙角"）
		if ai_path_i + 1 < ai_path.size() and dl < 46.0 \
				and main.party.line_clear(position, ai_path[ai_path_i + 1]):
			ai_path_i += 1
			continue
		if ai_path_i == ai_path.size() - 1 and dl < 36.0:
			_speed_scale = clampf(dl / 36.0, 0.45, 1.0)
		facing_name = _dir_name(d)
		return d / dl
	if ai_has_goal:
		var g := ai_goal - position
		var gl := g.length()
		if gl < 14.0:
			ai_has_goal = false
			ai_path.clear()
			ai_path_i = 0
			return Vector2.ZERO
		if gl < 44.0:
			_speed_scale = clampf(gl / 44.0, 0.5, 1.0)
		facing_name = _dir_name(g)
		return g / gl
	return Vector2.ZERO


## 撞墙记录：把"顶着墙的方向"换算成"沿墙滑的方向"，下一拍混入移动方向
func _update_slide(dir: Vector2) -> void:
	if dir.length_squared() < 0.001:
		return
	for i in get_slide_collision_count():
		var n: Vector2 = get_slide_collision(i).get_normal()
		if n.dot(dir) < -0.15:
			var tangent: Vector2 = dir.slide(n)
			if tangent.length_squared() > 0.0001:
				_slide_bias = tangent.normalized()
				_slide_t = 0.20
				return


## 朝向向量（镜头前视 / 集合点计算读取）
func face_dir() -> Vector2:
	return _face_vec()


## 软分离：队友之间、与玩家之间保持个人空间（不叠影、不挡镜头、不挤门）
## 含最近敌人：被怪贴脸时推开，不再与敌群叠影
## 站定时分离力减半：否则"站着互相推"会让待机看起来在抖
func _separation(moving: bool = true) -> Vector2:
	var sep := Vector2.ZERO
	var spread := float(ArpgPartyConfig.cfg("command")["follow"].get("spread", 52.0))
	var r_friend := maxf(30.0, spread * 0.58)
	if main.party != null:
		for other in main.party.friends:
			if other == self or not is_instance_valid(other) or other.dead:
				continue
			var d: Vector2 = position - other.position
			var l: float = d.length()
			if l < r_friend and l > 0.01:
				sep += d / l * (1.0 - l / r_friend)
	if main.player != null and main.player != self and is_instance_valid(main.player) and not main.player.dead:
		var dp: Vector2 = position - main.player.position
		var lp: float = dp.length()
		if lp < 26.0 and lp > 0.01:
			sep += dp / lp * (1.0 - lp / 26.0) * 1.4
	# 敌人推离（1 次哈希查询；队友本就不该与怪重叠）
	if world != null and world.mobs != null:
		var mi: int = world.mobs.nearest(position, 40.0)
		if mi >= 0:
			var dm: Vector2 = position - world.mobs.pos[mi]
			var lm: float = dm.length()
			if lm < 28.0 and lm > 0.01:
				sep += dm / lm * (1.0 - lm / 28.0) * 0.9
	if not moving:
		sep *= 0.45
	return sep.limit_length(1.2)


func _dir_name(d: Vector2) -> String:
	if absf(d.x) > absf(d.y):
		return "right" if d.x > 0 else "left"
	return "down" if d.y > 0 else "up"


func _face_vec() -> Vector2:
	match facing_name:
		"left": return Vector2.LEFT
		"right": return Vector2.RIGHT
		"up": return Vector2.UP
	return Vector2.DOWN


func _animate(delta: float) -> void:
	if _moving:
		_walk_t += delta
		_set_frame(WALK_SEQ[int(_walk_t / 0.12) % 4])
	else:
		_walk_t = 0.0
		_set_frame(0)


func _set_frame(f: int) -> void:
	var row: int = DIR_ROW[facing_name]
	sprite.region_rect = Rect2(block.x + f * 48, block.y + row * 48, 48, 48)


# ———————— 战斗 ————————

func try_attack(target_pos: Vector2) -> void:
	if dead or atk_timer > 0.0:
		return
	# 攻速走模板（与玩家同源）；旧实现写死 0.42，弓手/魔女的快慢完全体现不出来
	atk_timer = float(tpl.get("atk_cd", 0.42))
	# 瞄准必须用「连续方向」。
	# 旧实现把方向坍缩成 _face_vec() 的四个正方向再发射：目标不在正上/下/左/右
	# （绝大多数情况）时弹道就是歪的，直线弹幕必然打空——这就是"不同一直线就打不中"的根因。
	# facing_name 只用于贴图选行，弹道/挥砍角度一律用 aim。
	var aim := target_pos - position
	if aim.length_squared() > 1.0:
		aim = aim.normalized()
		facing_name = _dir_name(aim)
	else:
		aim = _face_vec()
	if weapon == "melee":
		lunge = aim * 170.0
		world.spawn_slash(position + aim * 13.0, aim.angle(), Color(0.75, 0.9, 1.0))
		for i in world.mobs_in_arc(position, aim.angle(), atk_range):
			world.damage_mob(i, atk, position)
	else:
		# 枪口前移一点点，但别把弹丸生进墙里（生在墙内的弹会立刻消失，读起来像"没打出去"）
		var muzzle := position + aim * 12.0
		if world.dungeon != null \
				and not world.dungeon.is_floor(Vector2i((muzzle / float(ArpgData.TILE)).floor())):
			muzzle = position
		world.spawn_projectile(muzzle, aim, proj_spd, atk,
			"player", Color(0.65, 0.95, 1.0) if weapon == "ranged" else Color(0.85, 0.55, 1.0),
			"arrow" if weapon == "ranged" else "orb")
	main.play_sfx("attack", -10.0)


func heal_flash() -> void:
	hp_bar.set_ratio(float(hp) / max_hp)
	sprite.modulate = Color(0.55, 1, 0.65)
	var tw := create_tween()
	tw.tween_property(sprite, "modulate", Color.WHITE, 0.25)


## 技能 v2：取职业表第一个解锁技能（数据驱动，与玩家同源）
func try_skill(target_pos: Vector2) -> void:
	if dead or skill_cd > 0.0:
		return
	var ids: Array = ArpgBalance.data.get("char_skills", {}).get(char_id, [])
	if ids.is_empty():
		return
	var def: Dictionary = ArpgBalance.data.get("skills", {}).get(str(ids[0]), {})
	if def.is_empty() or sp < int(def["sp"]):
		return
	sp -= int(def["sp"])
	skill_cd = float(def["cd"])
	var to_t := target_pos - position
	var dir := to_t.normalized() if to_t.length_squared() > 1.0 else _face_vec()
	var mult := float(def.get("dmg_mult", 1.0))
	match str(def.get("kind", "nova")):
		"dash":
			lunge = dir * 360.0
			for i in world.mobs_in_arc(position + dir * 30.0, dir.angle(), atk_range + 14.0):
				world.damage_mob(i, int(atk * mult), position, 260.0, true)
			world.spawn_slash(position + dir * 16.0, dir.angle(), Color(0.7, 0.95, 1.0))
		"volley":
			for i in 5:
				world.spawn_projectile(position + dir * 14.0, dir.rotated(deg_to_rad(-24.0 + i * 12.0)),
					proj_spd, atk, "player", Color(0.62, 1.0, 0.8), "arrow")
		"heal":
			heal_by(int(max_hp * float(def.get("heal", 0.3))))
			world.spawn_nova(position, Color(0.55, 1, 0.65))
		_:
			for i in world.mobs_in_radius(position, 90.0):
				world.damage_mob(i, int(atk * mult), position, 300.0, true)
			for i in 12:
				world.spawn_projectile(position, Vector2.RIGHT.rotated(TAU * i / 12.0), 265.0, atk, "player", Color(1.0, 0.6, 0.28), "bullet")
			world.spawn_nova(position, Color(0.6, 0.7, 1.0))
	main.play_sfx("skill", -9.0)


func take_damage(dmg: int, from_pos: Vector2) -> void:
	if dead or iframes > 0.0:
		return
	hp = maxi(0, hp - dmg)
	iframes = 0.4
	in_combat_until = 4.0
	knock = (position - from_pos).normalized() * 200.0
	sprite.modulate = Color(1, 0.45, 0.45)
	var tw := create_tween()
	tw.tween_property(sprite, "modulate", Color.WHITE, 0.25)
	world.spawn_popup("-%d" % dmg, position, Color(1, 0.6, 0.5))
	hp_bar.set_ratio(float(hp) / max_hp)
	if hp <= 0:
		die()


func heal_by(amount: int) -> void:
	hp = mini(max_hp, hp + amount)
	hp_bar.set_ratio(float(hp) / max_hp)


## 经验分享（需求书 §7）：升级同样完全回满
func gain_xp(x: int) -> void:
	xp += x
	var g: Dictionary = tpl.get("growth", {})
	if g.is_empty():
		return
	while xp >= ArpgBalance.xp_need(level):
		xp -= ArpgBalance.xp_need(level)
		level += 1
		max_hp += int(g.get("hp", 8))
		atk += int(g.get("atk", 1))
		hp = max_hp
		sp = max_sp
		hp_bar.set_ratio(1.0)


func die() -> void:
	dead = true
	state = "dead"
	collision_layer = 0
	collision_mask = 0
	hp_bar.visible = false
	world.spawn_death_poof(position, Color(0.75, 0.85, 1.0))
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(sprite, "scale", Vector2(0.1, 0.1), 0.35)
	tw.tween_property(self, "modulate:a", 0.15, 0.35)
	main.party.notify_death(uid)


func revive(ratio: float) -> void:
	dead = false
	state = "idle"
	collision_layer = 2
	collision_mask = 1
	hp = int(max_hp * ratio)
	sp = max_sp
	hp_bar.visible = true
	hp_bar.set_ratio(float(hp) / max_hp)
	modulate = Color.WHITE
	sprite.scale = Vector2.ONE


func teleport_to(p: Vector2) -> void:
	position = p
	knock = Vector2.ZERO
	lunge = Vector2.ZERO
	_slide_bias = Vector2.ZERO
	_slide_t = 0.0
	_speed_scale = 1.0
	ai_path.clear()
	ai_path_i = 0
	ai_has_goal = false


func _draw() -> void:
	draw_set_transform(Vector2(0, 13), 0.0, Vector2(1.0, 0.45))
	draw_circle(Vector2.ZERO, 8.5, Color(0, 0, 0, 0.26))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if main.possession != null and main.possession.is_possessed(self):
		draw_arc(Vector2(0, 13), 12.0, 0, TAU, 40, Color(1, 0.95, 0.5, 0.95), 2.5)
