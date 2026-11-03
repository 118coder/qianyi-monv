class_name ArpgAIController
extends RefCounted
## 队友 AI 决策器（需求书 §7 AIController）——「感知 → 决策 → 执行」三层里只负责决策。
##
## 旧实现的问题（都是"消极不作为 / 卡墙 / 玩家挨打不参战"的根因）：
## 1. 跟随模式只在 `main.player_in_combat()` 为真时索敌，且索敌圆心是**玩家**：
##    怪贴到队友脸上（玩家没被打到）→ 队友站着挨打；怪在 260~300 的环带 → 谁也不管。
## 2. 没有目标粘性：每次 think 都重取 `nearest`，站在两只怪中间会来回改目标 → 原地抽搐。
## 3. 目标下标是 mob 数组下标，而 `mob_system._handle_deaths()` 每帧 swap 压缩数组
##    → 缓存的 target 会指向"另一只怪"甚至越界。
## 4. 攻击不判视野：隔着墙也能挥空。
## 5. 卡住判定用"位移<2px"，贴墙滑动（位移很大但没进展）永远触发不了 → 一直卡着。
## 6. A* 无解（目标不可达 / 目标格在墙里）时直接直线硬顶墙，只能等 2.5s 传送。
##
## 现在的做法（成熟商业游戏常见结构）：
## - **感知**：贴脸半径 ∪ 队友/玩家协同半径取候选，按「距离 + 对玩家的威胁 + 收尾 + 视野」评分；
##   目标有粘性（换目标需要高出 switch_margin），并用「位置+模板」校验，规避数组压缩。
## - **决策**：行为 = 待机/跟随/接敌/风筝/撤退/拾取/归队，全部带迟滞（进入/退出两套阈值）。
## - **执行**：只写 unit 的 ai_* 接口；寻路失败退回流程场；卡住分四级升级处置（重寻路→侧移→
##   换点→传送），全部按「朝目标的有效进展」判定，而不是位移。
## - 参数全部来自 balance.json `party.ai` / `party.command.*`，保存即热重载。

const CMD_ORDER := ["active", "follow", "hold"]
const CMD_NAME := {"active": "主动进攻", "follow": "跟随玩家", "hold": "待机"}

## 默认值（JSON 缺键时兜底；正式数值在 data/balance.json）
const DEF := {
	"self_defense_radius": 150.0,   # 被怪贴到这个距离必还手（不看玩家是否在战斗）
	"assist_radius": 300.0,         # 玩家参战时，以玩家为圆心的协战半径
	"assist_idle_radius": 200.0,    # 玩家未参战时，仍会主动清理的"贴近玩家"半径
	"los_penalty": 0.9,             # 隔墙目标评分扣分（不直接排除：绕过去打才对）
	"stick_bonus": 0.6,             # 当前目标的粘性加分
	"switch_margin": 1.25,          # 新目标分数需超过当前目标的倍数才换
	"reach_timeout": 6.0,           # 追同一目标超时仍打不到 → 拉黑一段时间
	"blacklist_time": 5.0,
	"ranged_engage": 265.0,         # 远程接敌距离
	"ranged_keep_min": 125.0,       # 远程后撤线
	"ranged_keep_max": 225.0,       # 远程前压线
	"arrive_radius": 28.0,          # 跟随到点判定
	"resume_radius": 48.0,          # 跟随重新起步判定（迟滞）
	"pickup_threat_radius": 220.0,  # 附近有怪时不捡东西
	"skill_min_enemies": 2,         # 技能起手条件：身边至少几只
	"stuck_repath": 0.30,
	"stuck_sidestep": 0.75,
	"stuck_regroup": 1.50,
	"stuck_teleport": 2.50,
	"hold_leash": 1.6,              # 待机时自卫的最大脱离半径（×defense_radius）
}

var anchor := Vector2.ZERO      # 【主动进攻/待机】锚点
var target := -1                # 当前目标 mob 下标（调试用，= unit.ai_target）

var _desired := Vector2.ZERO    # 期望移动方向（卡住判定的基准）
var _repath_t := 0.0
var _last_goal := Vector2.INF
var _arrived := false
var _pickup_cd := 0.0
var _stuck_t := 0.0
var _stuck_stage := 0
var _last_pos := Vector2.ZERO
var _best_dist := INF
var _no_gain_t := 0.0
var _last_ms := 0.0
var _target_pos := Vector2.ZERO
var _target_tpl := ""
var _target_idx := -1      # 记录「模板+位置」属于哪个下标，用于识别数组压缩后的错位
var _engage_t0 := 0.0
var _engage_hit := false
var _blacklist := {}
var _floor_key := -1
var _los_cache := {}
var _side := 1.0
var _kite_t := 0.0


func set_command(unit, cmd: String) -> void:
	if not cmd in CMD_ORDER:
		return
	unit.command_queue.push(cmd)
	unit.command = cmd
	anchor = unit.position
	_blacklist.clear()
	_arrived = false
	_repath_t = 0.0
	print("[AI] %s 指令 → %s" % [unit.uid, CMD_NAME[cmd]])


func think(unit, main, delta: float) -> void:
	if unit == null or not is_instance_valid(unit) or unit.dead:
		return
	if main.state != main.State.PLAY or main.world == null or main.world.mobs == null:
		_stop(unit)
		return
	_sync_floor(main)
	# ⚠️ think 是"按节拍"调用的：传进来的 delta 只是某一帧的帧时长（≈16ms），
	# 用它当计时器会让所有计时慢 ~9 倍（旧实现卡住判定慢到几乎不触发）。
	# 这里用真实墙钟得到的「决策周期」，所有计时器统一走 tick。
	var tick := _tick_delta()
	_repath_t = maxf(0.0, _repath_t - tick)
	_pickup_cd = maxf(0.0, _pickup_cd - tick)
	_kite_t -= tick
	var mi := _pick_target(unit, main)
	match str(unit.command):
		"hold":
			_be_hold(unit, main, mi)
		"active":
			_be_active(unit, main, mi)
		_:
			_be_follow(unit, main, mi)
	_watch_stuck(unit, main, tick)


# ———————— 三种指令 ————————

## 【跟随】编队跟随；但「贴到身上的怪」「扑向玩家的怪」一律还手
func _be_follow(unit, main, mi: int) -> void:
	if mi >= 0:
		unit.state = "attack"
		_engage(unit, main, mi)
		return
	target = -1
	unit.ai_target = -1
	if _try_pickup(unit, main, "follow"):
		return
	var goal: Vector2 = main.party.formation_point(unit)
	_move_goal(unit, main, goal)


## 【主动进攻】锚点周围搜索；脱离归位；低血撤退；无怪时按配置跟随/守点
func _be_active(unit, main, mi: int) -> void:
	var cfg: Dictionary = ArpgPartyConfig.cfg("command").get("active", {})
	var leash := float(cfg.get("leash_radius", 320.0))
	var retreat := float(cfg.get("low_hp_retreat", 0.25))
	if float(unit.hp) / float(unit.max_hp) < retreat:
		target = -1
		unit.ai_target = -1
		unit.state = "retreat"
		_move_goal(unit, main, anchor, 34.0, 52.0)
		return
	if unit.position.distance_to(anchor) > leash:
		target = -1
		unit.ai_target = -1
		_move_goal(unit, main, anchor, 34.0, 52.0)
		return
	if mi >= 0:
		unit.state = "attack"
		_engage(unit, main, mi)
		return
	target = -1
	unit.ai_target = -1
	if str(cfg.get("no_enemy", "follow")) == "follow":
		if _try_pickup(unit, main, "active"):
			return
		_move_goal(unit, main, main.party.formation_point(unit))
	else:
		_move_goal(unit, main, anchor, 40.0, 60.0)
		if unit.position.distance_to(anchor) <= 40.0 and bool(cfg.get("pickup", true)):
			_try_pickup(unit, main, "active")


## 【待机】原地不动；被攻击/被贴脸时自卫，但只在小范围里打，不追出去
func _be_hold(unit, main, mi: int) -> void:
	var cfg: Dictionary = ArpgPartyConfig.cfg("command").get("hold", {})
	var defend_r := float(cfg.get("defense_radius", 70.0))
	var leash := defend_r * float(_f("hold_leash", 1.6))
	if bool(cfg.get("self_defense", true)) and mi >= 0 and mi < main.world.mobs.count:
		var mp: Vector2 = main.world.mobs.pos[mi]
		if mp.distance_to(unit.position) <= defend_r or mp.distance_to(anchor) <= defend_r:
			unit.state = "attack"
			_engage(unit, main, mi)
			return
	target = -1
	unit.ai_target = -1
	if unit.position.distance_to(anchor) > leash:
		_move_goal(unit, main, anchor, 30.0, 44.0)
		return
	_stop(unit)
	unit.state = "idle"
	if bool(cfg.get("pickup", false)):
		_try_pickup(unit, main, "hold")


# ———————— 感知：目标选择 ————————

## 候选 = 自身贴脸半径 ∪ 队长（主控单位）周边；四项评分 + 粘性 + 黑名单
func _pick_target(unit, main) -> int:
	var mobs = main.world.mobs
	var leader = _leader(main)
	var self_r := float(_f("self_defense_radius", 150.0))
	var assist := float(_f("assist_radius", 300.0))
	var idle := float(_f("assist_idle_radius", 200.0))
	var leader_combat: bool = _leader_in_combat(main, leader)
	var pool := {}
	# 贴脸半径内的怪：隔墙且离得较远的不拉（避免"跟着玩家走，顺手把墙后整间房拉过来"）
	for i in mobs.in_radius(unit.position, self_r):
		var mp0: Vector2 = mobs.pos[i]
		if mp0.distance_to(unit.position) < 90.0 or _los(unit, main, mp0):
			pool[i] = true
	if leader != null:
		var ar: float = assist if leader_combat else idle
		for i in mobs.in_radius(leader.position, ar):
			pool[i] = true
	var cmd: String = str(unit.command)
	var search_r := 0.0
	if cmd == "active":
		search_r = float(ArpgPartyConfig.cfg("command").get("active", {}).get("search_radius", 340.0))
		for i in mobs.in_radius(unit.position, search_r):
			pool[i] = true
	var best := -1
	var best_s := -1e9
	var cur_s := -1e9
	var stick := float(_f("stick_bonus", 0.6))
	var los_pen := float(_f("los_penalty", 0.9))
	var now := _now()
	var scored := 0
	for i in pool:
		if scored >= 96:      # 万敌压测下的护栏：候选评分有上限，不影响正常战斗
			break
		if not _mob_valid(mobs, i) or _blacklisted(i, now):
			continue
		scored += 1
		var mp: Vector2 = mobs.pos[i]
		var du: float = mp.distance_to(unit.position)
		var s: float = 2.4 / (1.0 + du / 140.0)
		if leader != null:
			var dl: float = mp.distance_to(leader.position)
			if dl < assist:
				s += 1.7 * (1.0 - dl / assist)
		if float(mobs.hp[i]) / maxf(float(mobs.max_hp[i]), 1.0) < 0.35:
			s += 0.35
		if mobs.boss[i] == 1 or mobs.elite[i] == 1:
			s += 0.2
		if not _los(unit, main, mp):
			s -= los_pen
		if i == target:
			s += stick
			cur_s = s
		if s > best_s:
			best_s = s
			best = i
	# 目标粘性：新目标不够好就不换（避免两只怪之间来回改目标）
	if target >= 0 and best != target and cur_s > -1e8:
		if cur_s * float(_f("switch_margin", 1.25)) >= best_s:
			best = target
	# 若目标已失效（死亡/被压缩掉）→ 立刻清掉
	if target >= 0 and not _mob_valid(mobs, target):
		target = -1
	if target != best:
		_engage_t0 = now
		_engage_hit = false
	target = best
	if best >= 0:
		# 立刻记录身份：mob 数组每帧可能被 swap 压缩，缓存下标必须能自证"还是同一只"
		_target_idx = best
		_target_pos = mobs.pos[best]
		_target_tpl = str(mobs.tpl_of(best))
	return best


## mob 下标是会被 swap 压缩的数组下标：用「模板 + 位置」二次确认身份
func _mob_valid(mobs, i: int) -> bool:
	if i < 0 or i >= mobs.count:
		return false
	if mobs.hp[i] <= 0 or mobs.alive[i] == 0:
		return false
	if i == _target_idx and _target_tpl != "":
		if str(mobs.tpl_of(i)) != _target_tpl:
			return false
		if mobs.pos[i].distance_to(_target_pos) > 120.0:
			return false
	return true


func _blacklisted(i: int, now: float) -> bool:
	var t = _blacklist.get(i)
	if t == null:
		return false
	if float(t) <= now:
		_blacklist.erase(i)
		return false
	return true


# ———————— 决策：接敌 ————————

func _engage(unit, main, mi: int) -> void:
	var mobs = main.world.mobs
	if not _mob_valid(mobs, mi):
		target = -1
		unit.ai_target = -1
		return
	unit.ai_target = mi
	var tp: Vector2 = mobs.pos[mi]
	_target_idx = mi
	_target_pos = tp
	_target_tpl = str(mobs.tpl_of(mi))
	var aim: Vector2 = _aim_point(unit, main, mobs, mi, tp)
	# 追太久还打不到 → 判定"够不着"（隔墙/不可达），拉黑换目标，别一直顶墙
	var now := _now()
	if not _engage_hit and now - _engage_t0 > float(_f("reach_timeout", 6.0)):
		_blacklist[mi] = now + float(_f("blacklist_time", 5.0))
		target = -1
		unit.ai_target = -1
		_stop(unit)
		return
	if _weapon_of(unit) == "melee":
		var reach: float = unit.atk_range + mobs.radius[mi]
		if unit.position.distance_to(tp) <= reach * 0.95:
			_stop(unit)
			unit.state = "attack"
			unit.ai_face = (tp - unit.position).normalized()
			unit.ai_attack_pos = aim
			# 贴到身上（<26px）就别再吹毛求疵查视野：格子采样在墙角会误判，
			# 那样会表现成"站着不动、被怪白打"
			if unit.position.distance_to(tp) < 26.0 or _los_exact(unit, main, tp):
				unit.ai_want_attack = true
				_engage_hit = true
				_engage_t0 = now
				_maybe_skill(unit, main, mi)
		else:
			unit.state = "move"
			_nav_to(unit, main, tp, 0.3)
	else:
		_engage_ranged(unit, main, mi, tp, aim)


## 远程：保持 [keep_min, keep_max] 距离带内横向走位，带内才开火（可以在后撤中开火）
func _engage_ranged(unit, main, mi: int, tp: Vector2, aim: Vector2) -> void:
	var lo := float(_f("ranged_keep_min", 125.0))
	var hi := float(_f("ranged_keep_max", 225.0))
	var d: float = unit.position.distance_to(tp)
	if d > float(_f("ranged_engage", 265.0)) or not _los_exact(unit, main, tp):
		unit.state = "move"
		_nav_to(unit, main, tp, 0.35)
		return
	if d < lo:
		# 后撤：主方向背离目标，混入横向分量；被墙挡住就换边
		var away: Vector2 = (unit.position - tp).normalized()
		if _kite_t <= 0.0:
			_kite_t = 0.9
			if not main.party.line_clear(unit.position, unit.position + away.rotated(_side * 0.9) * 70.0):
				_side = -_side
		var dirn: Vector2 = away.rotated(_side * 0.85)
		unit.state = "move"
		unit.ai_has_goal = true
		unit.ai_goal = unit.position + dirn * 76.0
		unit.ai_path = PackedVector2Array()
		_desired = dirn
	elif d > hi:
		unit.state = "move"
		_nav_to(unit, main, tp, 0.4)
	else:
		# 距离带内：站定开火（稍微横移让身位不死板）
		_stop(unit)
		unit.state = "attack"
		unit.ai_face = (tp - unit.position).normalized()
	if unit.position.distance_to(tp) <= hi * 1.15 and _los_exact(unit, main, tp):
		unit.ai_attack_pos = aim
		unit.ai_want_attack = true
		_engage_hit = true
		_engage_t0 = _now()
		_maybe_skill(unit, main, mi)


## 技能：按「身边敌人数 / 目标强度 / 血量」决策，替代原来的 3% 随机
func _maybe_skill(unit, main, mi: int) -> void:
	if unit.skill_cd > 0.0:
		return
	var ids: Array = ArpgBalance.data.get("char_skills", {}).get(str(unit.char_id), [])
	if ids.is_empty():
		return
	var def: Dictionary = ArpgBalance.data.get("skills", {}).get(str(ids[0]), {})
	if def.is_empty() or unit.sp < int(def["sp"]):
		return
	var kind := str(def.get("kind", "nova"))
	if kind == "heal":
		if float(unit.hp) / float(unit.max_hp) < 0.55:
			unit.ai_attack_pos = unit.position
			unit.ai_want_skill = true
		return
	var mobs = main.world.mobs
	var near: int = mobs.in_radius(unit.position, 96.0).size()
	var strong: bool = false
	if mi >= 0 and mi < mobs.count:
		strong = mobs.boss[mi] == 1 or mobs.elite[mi] == 1
	if near >= int(_f("skill_min_enemies", 2)) or strong:
		if randf() < 0.7:
			unit.ai_want_skill = true


# ———————— 执行：导航 / 停 / 卡住 ————————

## 跟随/守点的到位迟滞：到点后要跑出 resume 才重新起步，避免在点位上抖
func _move_goal(unit, main, goal: Vector2, arrive: float = -1.0, resume: float = -1.0) -> void:
	if arrive < 0.0:
		arrive = float(_f("arrive_radius", 28.0))
	if resume < 0.0:
		resume = float(_f("resume_radius", 48.0))
	var d: float = unit.position.distance_to(goal)
	if _arrived:
		if d < resume:
			_stop(unit)
			unit.state = "idle"
			return
		_arrived = false
	if d < arrive:
		_arrived = true
		_stop(unit)
		unit.state = "idle"
		return
	unit.state = "move"
	_nav_to(unit, main, goal)


func _nav_to(unit, main, goal: Vector2, repath_interval: float = -1.0) -> void:
	if repath_interval < 0.0:
		repath_interval = float(ArpgPartyConfig.cfg("nav_repath_interval"))
	unit.ai_has_goal = true
	unit.ai_goal = goal
	_desired = (goal - unit.position)
	var goal_moved: bool = _last_goal.distance_to(goal) > 56.0
	if goal_moved:
		# 换了目标点：进展基准要重置，否则"没进展"计时会误伤正常换目标
		_best_dist = INF
		_no_gain_t = 0.0
	if not (_repath_t <= 0.0 or unit.ai_path.is_empty() or goal_moved):
		return
	var path: PackedVector2Array = main.party.nav_path(unit.position, goal)
	if path.is_empty():
		# A* 无解（目标格不可达/在墙内）→ 不是硬顶墙，而是退回流程场朝主控靠拢，短周期重试
		var fd := Vector2.ZERO
		if main.world != null and main.world.mobs != null:
			fd = main.world.mobs.flow.dir_at(unit.position, ArpgData.TILE)
		if fd != Vector2.ZERO:
			path = PackedVector2Array([unit.position + fd.normalized() * 58.0])
		_repath_t = minf(repath_interval, 0.35)
	else:
		_repath_t = repath_interval
	unit.ai_path = path
	unit.ai_path_i = 0
	_last_goal = goal


func _stop(unit) -> void:
	unit.ai_has_goal = false
	unit.ai_path = PackedVector2Array()
	unit.ai_path_i = 0
	_desired = Vector2.ZERO


## 拾取：先向仲裁器认领；附近有怪时不捡（战斗优先）
func _try_pickup(unit, main, cmd: String) -> bool:
	var cfg: Dictionary = ArpgPartyConfig.cfg("command").get(cmd, {})
	if cfg.is_empty() or not bool(cfg.get("pickup", false)) or _pickup_cd > 0.0:
		return false
	if main.world.pickups == null:
		return false
	var guard := float(_f("pickup_threat_radius", 220.0))
	if main.world.mobs.nearest(unit.position, guard) >= 0:
		return false
	var iid: int = main.world.pickups.nearest_id(unit.position, 110.0)
	if iid < 0:
		return false
	if not main.arbiter.request(unit.uid, iid):
		_pickup_cd = 0.8
		return false
	var ip: Vector2 = main.world.pickups.pos_of(iid)
	if unit.position.distance_to(ip) < 18.0:
		if main.arbiter.collect(unit, iid):
			_pickup_cd = 0.4
			return true
		return false
	unit.state = "pickup"
	_nav_to(unit, main, ip, 0.5)
	return true


## 卡住处置：两条独立信号 + 四级升级处置
## 信号 A「原地打转」：本决策周期位移 < 速度×0.22（顶墙/被两只怪夹住/路点落墙里）
## 信号 B「越走越远」：目标距离连续 N 秒没缩短（沿长墙盲滑、寻路绕远绕丢了）
## 处置：重寻路 → 切向侧移 → 换就近可达点 → 传送归队（带可走/避险落点校验）
func _watch_stuck(unit, main, tick: float) -> void:
	var wants: bool = unit.ai_has_goal or unit.ai_path_i < unit.ai_path.size()
	if not wants:
		_reset_stuck()
		_last_pos = unit.position
		return
	var moved: float = unit.position.distance_to(_last_pos)
	var step_need: float = maxf(1.5, float(unit.spd) * tick * 0.22)
	if moved < step_need:
		_stuck_t += tick
	else:
		_stuck_t = maxf(0.0, _stuck_t - tick * 1.5)
		_stuck_stage = 0
	_last_pos = unit.position
	# 目标距离是否在缩短（目标本身在动时只要求"有改善"，不做绝对量比较）
	var gd: float = unit.position.distance_to(unit.ai_goal)
	if _best_dist == INF or gd < _best_dist - 20.0:
		_best_dist = gd
		_no_gain_t = 0.0
	else:
		_no_gain_t += tick
	if _stuck_t > float(_f("stuck_repath", 0.30)) and _stuck_stage < 1:
		_stuck_stage = 1
		_repath_t = 0.0
		unit.ai_path = PackedVector2Array()
		unit.ai_path_i = 0
		return
	if _stuck_t > float(_f("stuck_sidestep", 0.75)) and _stuck_stage < 2:
		_stuck_stage = 2
		_side_step(unit, main)
		return
	if _no_gain_t > 2.0 and _stuck_stage < 3:
		_stuck_stage = 3
		_regroup(unit, main)
		return
	if _stuck_t > float(_f("stuck_teleport", 2.50)) or _no_gain_t > 5.0:
		_reset_stuck()
		_teleport_back(unit, main)


func _reset_stuck() -> void:
	_stuck_t = 0.0
	_stuck_stage = 0
	_no_gain_t = 0.0
	_best_dist = INF


## 侧移脱困：沿期望方向的两条切线各探一段，走能走的那条（真正贴着墙滑出去）
func _side_step(unit, main) -> void:
	var base_dir := _desired
	if base_dir.length_squared() < 0.01:
		base_dir = unit.ai_goal - unit.position
	if base_dir.length_squared() < 0.01:
		base_dir = Vector2.DOWN
	var dirn := base_dir.normalized()
	for s in [1.0, -1.0]:
		var t: Vector2 = dirn.orthogonal() * float(s)
		if main.party.line_clear(unit.position, unit.position + t * 64.0):
			unit.ai_has_goal = true
			unit.ai_goal = unit.position + t * 64.0
			unit.ai_path = PackedVector2Array([unit.ai_goal])
			unit.ai_path_i = 0
			_desired = t
			return
	# 两侧都不通（死角）：直接朝队长挪
	var leader = _leader(main)
	if leader != null:
		unit.ai_path = PackedVector2Array([leader.position])
		unit.ai_path_i = 0


## 换点：目标点可能在墙内/不可达，改到「离队长最近的可走格」
func _regroup(unit, main) -> void:
	var leader = _leader(main)
	var goal: Vector2 = leader.position if leader != null else anchor
	var c := Vector2i((goal / float(ArpgData.TILE)).floor())
	var open: Vector2i = main.party._nearest_open(c)
	var path: PackedVector2Array = main.party.nav_path(unit.position, ArpgDungeon.cell_to_pos(open))
	if path.is_empty():
		path = PackedVector2Array([ArpgDungeon.cell_to_pos(open)])
	unit.ai_has_goal = true
	unit.ai_goal = ArpgDungeon.cell_to_pos(open)
	unit.ai_path = path
	unit.ai_path_i = 0
	_desired = (unit.ai_goal - unit.position)


## 传送归队：落点必可走，且按「离怪堆最远」挑角度（别把人送进包围圈）
func _teleport_back(unit, main) -> void:
	var leader = _leader(main)
	if leader == null:
		return
	var best: Vector2 = leader.position
	var best_score := -1e9
	var slot := 0
	if main.party != null:
		slot = maxi(main.party.friends.find(unit), 0)
	for k in 4:
		var ang := float(slot) * (TAU / 6.0) + 0.4 + float(k) * (TAU / 4.0)
		var dest: Vector2 = leader.position + Vector2.RIGHT.rotated(ang) * 36.0
		var c := Vector2i((dest / float(ArpgData.TILE)).floor())
		if not main.party._is_open(c):
			dest = ArpgDungeon.cell_to_pos(main.party._nearest_open(c))
		var threat: int = main.world.mobs.in_radius(dest, 90.0).size()
		var score: float = -float(threat) * 10.0 - dest.distance_to(leader.position) * 0.05
		if score > best_score:
			best_score = score
			best = dest
	unit.teleport_to(best)
	unit.state = "stuck"
	if main.world != null:
		main.world.spawn_nova(unit.position, Color(0.6, 0.85, 1.0))
	print("[AI] %s 卡住，已传送归队" % unit.uid)
	if main.hud != null:
		main.hud.log("%s 卡住了，已传送归队" % unit.unit_name)


# ———————— 工具 ————————

func _leader(main):
	if main.possession != null and main.possession.current_unit != null \
			and is_instance_valid(main.possession.current_unit) and not main.possession.current_unit.dead:
		return main.possession.current_unit
	return main.player


## 队长是否处于交战状态：受击计时（玩家/被切队友都有 in_combat_until）或身边有怪
func _leader_in_combat(main, leader) -> bool:
	if leader == null or not is_instance_valid(leader):
		return false
	var t = leader.get("in_combat_until")
	if t != null and float(t) > 0.0:
		return true
	if main.world == null or main.world.mobs == null:
		return false
	return main.world.mobs.nearest(leader.position, 240.0) >= 0


## 网格视野（8px 采样），按「格对」缓存：换层时清空。用于候选目标评分（容错可接受）
func _los(unit, main, p: Vector2) -> bool:
	if main.party == null:
		return true
	var a: Vector2 = unit.position
	var key := int(a.x / 48.0) * 100003 + int(a.y / 48.0) * 7919 \
		+ int(p.x / 48.0) * 104729 + int(p.y / 48.0) * 1299709
	var v = _los_cache.get(key)
	if v == null:
		v = main.party.line_clear(a, p)
		if _los_cache.size() > 6000:
			_los_cache.clear()
		_los_cache[key] = v
	return bool(v)


## 精确视野（不走缓存）：只用在「这一刀/这一箭能不能真的打到」上，
## 缓存量化到 48px 会让人隔着薄墙挥空/放箭，观感很假
func _los_exact(unit, main, p: Vector2) -> bool:
	if main.party == null:
		return true
	return main.party.line_clear(unit.position, p)


func _sync_floor(main) -> void:
	var key: int = int(main.floor_no) * 1000 + int(main.dungeon.get_instance_id() % 100000) if main.dungeon != null else 0
	if key == _floor_key:
		return
	_floor_key = key
	_blacklist.clear()
	_los_cache.clear()
	target = -1
	_arrived = false
	_repath_t = 0.0


## 弹道提前量（Predictive Aim / 交会解算）：
## 先假设目标不动求飞行时间 t0，再用 t 推目标未来位置求新的 t，迭代 2 次收敛
## （GDC "Predictive Aim Mathematics" 的标准做法）。近战瞬时命中，不需要提前量。
## 提前量有上限（`aim_max_lead` 秒），并且预测点被墙挡住时退回当前位置——不然残血怪
## 贴墙走位时会瞄到墙里，箭全打在墙上。
func _aim_point(unit, main, mobs, mi: int, tp: Vector2) -> Vector2:
	if _weapon_of(unit) == "melee":
		return tp
	var ps := _proj_speed(unit)
	if ps <= 1.0:
		return tp
	var v := Vector2.ZERO
	if mobs.vel.size() > mi:
		v = mobs.vel[mi]
	var max_t := float(_f("aim_max_lead", 0.55))
	var t: float = minf(unit.position.distance_to(tp) / ps, max_t)
	var aim := tp
	for _k in 2:
		aim = tp + v * t
		t = minf(unit.position.distance_to(aim) / ps, max_t)
	if aim.distance_to(tp) > 6.0 and not _los_exact(unit, main, aim):
		aim = tp
	return aim


func _proj_speed(unit) -> float:
	var s = unit.get("proj_spd")
	if s != null:
		return float(s)
	var tp = unit.get("tpl")
	if tp != null and tp is Dictionary:
		return float(tp.get("proj_spd", 380.0))
	return 380.0


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


## 武器类型：队友有 weapon 字段，玩家只存在模板里（AI 接管玩家时也要能读到）
func _weapon_of(unit) -> String:
	var w = unit.get("weapon")
	if w != null:
		return str(w)
	var tp = unit.get("tpl")
	if tp != null and tp is Dictionary:
		return str(tp.get("weapon", "melee"))
	return "melee"


## 距上次 think 的真实时长（秒），夹在 [20ms, 600ms]：掉帧/暂停后不会瞬间攒满计时
func _tick_delta() -> float:
	var now := _now()
	if _last_ms <= 0.0:
		_last_ms = now
		return 0.15
	var dt := now - _last_ms
	_last_ms = now
	return clampf(dt, 0.02, 0.6)


func _f(key: String, fallback: float) -> float:
	var party: Dictionary = ArpgBalance.data.get("party", {})
	var ai: Dictionary = party.get("ai", {})
	if ai.has(key):
		return float(ai[key])
	return float(DEF.get(key, fallback))


## 指令名（UI 用）
static func cmd_name(cmd: String) -> String:
	return CMD_NAME.get(cmd, cmd)
