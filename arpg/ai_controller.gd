class_name ArpgAIController
extends RefCounted
## AI 决策器（需求书 §7 AIController）：
## 高层指令（主动进攻/跟随玩家/待机）→ 底层行为（索敌/攻击/撤退/拾取/跟随/卡住恢复）。
## 队友与「被切下主控的玩家」共用；只写 unit 的 ai_* 执行接口，不直接操作引擎节点。
## 所有参数读 ArpgPartyConfig，禁止硬编码。

const CMD_ORDER := ["active", "follow", "hold"]
const CMD_NAME := {"active": "主动进攻", "follow": "跟随玩家", "hold": "待机"}

var anchor := Vector2.ZERO          # 【主动进攻】锚点（下达指令时的位置）
var _stuck_t := 0.0
var _unstuck_t := 0.0
var _last_pos := Vector2.ZERO
var _pickup_cd := 0.0
var _repath_t := 0.0
var _last_goal := Vector2.INF


func set_command(unit, cmd: String) -> void:
	if not cmd in CMD_ORDER:
		return
	unit.command_queue.push(cmd)
	unit.command = cmd
	if cmd == "active":
		anchor = unit.position
	print("[AI] %s 指令 → %s" % [unit.uid, CMD_NAME[cmd]])


func think(unit, main, delta: float) -> void:
	if unit == null or unit.dead or main.state != main.State.PLAY:
		return
	_pickup_cd = maxf(0.0, _pickup_cd - delta)
	_repath_t = maxf(0.0, _repath_t - delta)
	match unit.command:
		"hold":
			_hold(unit, main)
		"active":
			_active(unit, main)
		_:
			_follow(unit, main)
	_stuck_check(unit, main, delta)


# ———————— 三指令 ————————

## 【待机】原地不动；被攻击是否自卫可配置；默认不拾取
func _hold(unit, main) -> void:
	var cfg: Dictionary = ArpgPartyConfig.cfg("command")["hold"]
	unit.state = "idle"
	_stop(unit)
	if bool(cfg["self_defense"]):
		var mi := _enemy_near(main, unit.position, float(cfg["defense_radius"]))
		if mi >= 0:
			unit.state = "attack"
			_combat(unit, main, mi)


## 【跟随玩家】编队跟随；默认不开怪，玩家进入战斗后按配置参战；拾取按开关
func _follow(unit, main) -> void:
	var cfg: Dictionary = ArpgPartyConfig.cfg("command")["follow"]
	var player = main.player
	if bool(cfg["engage_with_player"]) and main.player_in_combat():
		var mi := _enemy_near(main, player.position, float(cfg["engage_radius"]))
		if mi >= 0:
			unit.state = "attack"
			_combat(unit, main, mi)
			return
	if _try_pickup(unit, main, cfg):
		return
	var goal: Vector2 = main.party.formation_point(unit)
	if unit.position.distance_to(goal) < 30.0:
		_stop(unit)
		unit.state = "idle"
	else:
		unit.state = "move"
		_nav_to(unit, main, goal)


## 【主动进攻】搜索半径内索敌；脱离半径回锚点；低血撤退；无敌时按配置跟随或守锚点
func _active(unit, main) -> void:
	var cfg: Dictionary = ArpgPartyConfig.cfg("command")["active"]
	var leash := float(cfg["leash_radius"])
	if unit.position.distance_to(anchor) > leash:
		unit.ai_target = -1
		unit.state = "move"
		_nav_to(unit, main, anchor)
		return
	var retreat_ratio := float(cfg.get("low_hp_retreat", ArpgPartyConfig.cfg("low_hp_retreat_ratio")))
	if float(unit.hp) / unit.max_hp < retreat_ratio:
		unit.state = "retreat"
		unit.ai_target = -1
		_nav_to(unit, main, anchor)
		return
	var target := -1
	if bool(cfg["protect_player"]) and main.player_in_combat():
		target = _enemy_near(main, main.player.position, 220.0)
	if target < 0:
		target = _enemy_near(main, unit.position, float(cfg["search_radius"]))
	if target >= 0:
		unit.state = "attack"
		_combat(unit, main, target)
		return
	# 无敌人：按配置跟随或守锚点；空闲且允许时顺路拾取
	if str(cfg["no_enemy"]) == "follow":
		var goal: Vector2 = main.party.formation_point(unit)
		if unit.position.distance_to(goal) > 40.0:
			unit.state = "move"
			_nav_to(unit, main, goal)
			return
		_stop(unit)
		unit.state = "idle"
	else:
		if unit.position.distance_to(anchor) > 40.0:
			unit.state = "move"
			_nav_to(unit, main, anchor)
			return
		_stop(unit)
		unit.state = "idle"
	if bool(cfg["pickup"]):
		_try_pickup(unit, main, cfg)


# ———————— 底层行为 ————————

func _combat(unit, main, mi: int) -> void:
	var mobs = main.world.mobs
	var tp: Vector2 = mobs.pos[mi]
	unit.ai_target = mi
	var reach: float = unit.atk_range + mobs.radius[mi]
	if unit.position.distance_to(tp) <= reach + 4.0:
		_stop(unit)
		unit.ai_face = (tp - unit.position).normalized()
		unit.ai_attack_pos = tp
		unit.ai_want_attack = true
		# 保守用技能：冷却好且随机触发（避免一次战斗全交）
		if unit.skill_cd <= 0.0 and randf() < 0.03:
			unit.ai_want_skill = true
		unit.state = "attack"
	else:
		unit.state = "move"
		_nav_to(unit, main, tp, 0.35)


func _enemy_near(main, from: Vector2, r: float) -> int:
	var i: int = main.world.mobs.nearest(from, r)
	if i < 0:
		return -1
	return i if main.world.mobs.pos[i].distance_to(from) <= r + main.world.mobs.radius[i] else -1


## 拾取：先向仲裁器认领，走到位后收取（玩家手动拾取始终优先，见 PickupArbiter）
func _try_pickup(unit, main, cfg) -> bool:
	if not bool(cfg["pickup"]) or _pickup_cd > 0.0:
		return false
	var iid: int = main.world.pickups.nearest_id(unit.position, 110.0)
	if iid < 0:
		return false
	if not main.arbiter.request(unit.uid, iid):
		_pickup_cd = 0.8   # 被别人认领了，歇一会再看
		return false
	var ip: Vector2 = main.world.pickups.pos_of(iid)
	if unit.position.distance_to(ip) < 16.0:
		if main.arbiter.collect(unit, iid):
			_pickup_cd = 0.4
			return true
		return false
	unit.state = "pickup"
	_nav_to(unit, main, ip, 0.4)
	return true


func _nav_to(unit, main, goal: Vector2, repath_interval: float = -1.0) -> void:
	if repath_interval < 0.0:
		repath_interval = float(ArpgPartyConfig.cfg("nav_repath_interval"))
	unit.ai_has_goal = true
	unit.ai_goal = goal
	if _repath_t <= 0.0 or unit.ai_path.is_empty() or unit.ai_goal.distance_to(_last_goal) > 48.0:
		unit.ai_path = main.party.nav_path(unit.position, goal)
		unit.ai_path_i = 0
		_repath_t = repath_interval
		_last_goal = goal


func _stop(unit) -> void:
	unit.ai_has_goal = false
	unit.ai_path = PackedVector2Array()
	unit.ai_path_i = 0


## 卡住恢复：先垂直绕行，超时传送到玩家身边并提示（禁止无声卡死）
func _stuck_check(unit, main, delta: float) -> void:
	var want_move: bool = unit.ai_has_goal or unit.ai_path_i < unit.ai_path.size()
	if not want_move:
		_stuck_t = 0.0
		_last_pos = unit.position
		return
	if unit.position.distance_to(_last_pos) < 2.0:
		_stuck_t += delta
		# 0.5s：跳过当前路点（多半被转角卡住）
		if _stuck_t > 0.5 and unit.ai_path_i < unit.ai_path.size():
			unit.ai_path_i += 1
		# 0.7s：垂直绕行一拍
		if _stuck_t > 0.7 and _unstuck_t <= 0.0:
			_unstuck_t = 0.7
			var perp: Vector2 = (unit.ai_goal - unit.position).normalized().rotated(PI / 2.0)
			unit.ai_path = PackedVector2Array([unit.position + perp * 52.0])
			unit.ai_path_i = 0
		# 2.5s：传送归队（带特效反馈，读起来是有意的召回）
		# 落点必须可走（主控贴墙时 (34,0) 会把人传进墙里 → 反复卡死）；
		# 按队伍序号环形错开，避免多名队友传到同一点叠影
		if _stuck_t > float(ArpgPartyConfig.cfg("stuck_teleport_after")):
			_stuck_t = 0.0
			var anchor: Vector2 = main.possession.current_unit.position
			var slot := 0
			if main.party != null:
				slot = main.party.friends.find(unit)
				if slot < 0:
					slot = 0
			var ang := float(slot) * (TAU / 6.0) + 0.4
			var dest: Vector2 = anchor + Vector2.RIGHT.rotated(ang) * 34.0
			if main.party != null:
				var dc := Vector2i((dest / float(ArpgData.TILE)).floor())
				if not main.party._is_open(dc):
					dest = ArpgDungeon.cell_to_pos(main.party._nearest_open(dc))
			unit.teleport_to(dest)
			unit.state = "stuck"
			if main.world != null:
				main.world.spawn_nova(unit.position, Color(0.6, 0.85, 1.0))
			print("[AI] %s 卡住，已传送归队" % unit.uid)
			main.hud.log("%s 卡住了，已传送归队" % unit.unit_name)
	else:
		_stuck_t = 0.0
	_last_pos = unit.position
	if _unstuck_t > 0.0:
		_unstuck_t -= delta


## 指令名（UI 用）
static func cmd_name(cmd: String) -> String:
	return CMD_NAME.get(cmd, cmd)
