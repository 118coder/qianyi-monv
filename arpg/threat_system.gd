extends RefCounted
## 威胁值系统（影之刃零「杀气/压力」的 2D 俯视角翻译）。
## 核心理念：Boss 不读指令，读玩家状态——HP/SP/喝药/按键频率/受击/站桩
## 汇总成一个隐藏威胁值（0-100），Boss 按它调整招式权重与攻击节奏。
## 威胁值高**不加伤害**，只改出招偏好（mob_system Boss 招式池消费 move_weights）。
## 配置全部在 balance.json `threat` 段，保存即热重载（消费方每帧 data.get 读）。
## 玩家侧观察点映射（本游戏无格挡/翻滚的取舍）：
##   喝药→main.drink_potion   受击→player.take_damage   技能→player.use_skill
##   狂按→main._process 语义按键统计   闪避/弹反→批次 3/4 接入
##   低血/贴脸/站桩→update(delta) 逐帧判定

var main: Node
var value := 25.0

# —— 输入统计内部状态 ——
var _mash_n := 0                 # mash_window 内的语义按键数
var _mash_t := 0.0               # 窗口剩余时间
var _mash_fired := false         # 本窗口已结算过 mash 加分（防重复）
var _potion_mash_t := 0.0        # 喝药后狂按检测窗口剩余
var _potion_mash_gain := 0.0     # 本窗口已累计的狂按加分（封顶）
var _idle_t := 0.0               # 玩家连续站桩时长
var _was_aggressive := false     # 凶暴档播报去重
var _pb_t := 0.0                 # 贴脸采样节流（nearest 是全桶扫，万敌下太贵，4Hz 足够）

## main._process 每帧喂的语义动作（dodge/parry 在批次 3/4 注册后自动生效）
const FEED_ACTIONS := ["attack", "skill", "skill2", "skill3", "potion", "interact", "purge"]


func setup(m: Node) -> void:
	main = m


func reset() -> void:
	value = float(_cfg().get("start", 25.0))
	_mash_n = 0
	_mash_t = 0.0
	_mash_fired = false
	_potion_mash_t = 0.0
	_potion_mash_gain = 0.0
	_idle_t = 0.0
	_was_aggressive = false


func _cfg() -> Dictionary:
	return ArpgBalance.data.get("threat", {})


func _gain(key: String, dflt: float) -> float:
	return float(_cfg().get("gain", {}).get(key, dflt))


func _relief(key: String, dflt: float) -> float:
	return float(_cfg().get("relief", {}).get(key, dflt))


func _clamp() -> void:
	value = clampf(value, 0.0, float(_cfg().get("max", 100.0)))


# ———————— 事件挂钩（各系统调用） ————————

## 语义按键（main._process 每帧统计 just_pressed）
func on_input() -> void:
	if not bool(_cfg().get("enabled", true)):
		return
	_mash_n += 1
	# 首次按键才开窗口：窗口未开时积累的按键不能被下一帧清掉
	if _mash_t <= 0.0:
		_mash_t = _gain("mash_window", 1.0)
		_mash_fired = false
	# 喝药后狂按：Boss 会读「喝药后慌乱按键」作为压力信号
	if _potion_mash_t > 0.0:
		var cap := _gain("potion_mash_cap", 8.0)
		if _potion_mash_gain < cap:
			_potion_mash_gain = minf(cap, _potion_mash_gain + _gain("potion_mash_per_input", 2.0))
			value += _gain("potion_mash_per_input", 2.0)


## 喝药（main.drink_potion）：压力信号 + 开启狂按检测窗口
func on_potion() -> void:
	if not bool(_cfg().get("enabled", true)):
		return
	value += _gain("potion", 8.0)
	_potion_mash_t = _gain("potion_mash_window", 1.5)
	_potion_mash_gain = 0.0


## 玩家真实受击（player.take_damage 命中分支）
func on_player_hurt() -> void:
	if not bool(_cfg().get("enabled", true)):
		return
	value += _gain("hurt", 4.0)


## 技能施放成功（player.use_skill）：SP 富余时更「嚣张」
func on_skill(sp_ratio: float) -> void:
	if not bool(_cfg().get("enabled", true)):
		return
	value += _gain("skill", 2.0)
	if sp_ratio >= _gain("skill_rich_ratio", 0.8):
		value += _gain("skill_rich", 2.0)


## 成功闪避（批次 3 接线）：冷静脱身 = 减压
func on_dodge() -> void:
	if not bool(_cfg().get("enabled", true)):
		return
	value -= _relief("dodge", 4.0)


## 弹反（批次 4 接线）：perfect = 完美弹反
func on_parry(perfect: bool) -> void:
	if not bool(_cfg().get("enabled", true)):
		return
	value -= _relief("perfect_parry", 6.0) if perfect else _relief("parry", 2.0)


# ———————— 逐帧更新（main._process，PLAY 态） ————————

func update(delta: float, player: Node2D, mobs) -> void:
	var cfg := _cfg()
	if not bool(cfg.get("enabled", true)) or player == null or not is_instance_valid(player):
		return
	# 喝药狂按窗口衰减
	if _potion_mash_t > 0.0:
		_potion_mash_t = maxf(0.0, _potion_mash_t - delta)
		if _potion_mash_t <= 0.0:
			_potion_mash_gain = 0.0
	# 按键频率窗口：窗口到期时结算——1 秒内按键超过阈值 → 「慌了」加分（每窗口只结算一次）
	if _mash_t > 0.0:
		_mash_t = maxf(0.0, _mash_t - delta)
		if _mash_t <= 0.0:
			if _mash_n > int(_gain("mash_threshold", 5)) and not _mash_fired:
				value += _gain("mash", 5.0)
				_mash_fired = true
			_mash_n = 0
	# 低血：持续加分（血量压力是 Boss 最强的进攻信号）
	if float(player.hp) / float(player.max_hp) < _gain("low_hp_ratio", 0.3):
		value += _gain("low_hp_per_s", 1.5) * delta
	# 贴脸输出：近身缠斗持续加分。节流采样 4Hz（nearest 是「桶内逐怪算距离」，
	# 万敌压测玩家被上千怪围住时每帧扫就是几毫秒——与分离力同哲学：规模超限自动降级）
	if mobs != null and mobs.count <= 300:
		_pb_t -= delta
		if _pb_t <= 0.0:
			_pb_t = 0.25
			if mobs.nearest(player.position, _gain("point_blank_dist", 95.0)) >= 0:
				value += _gain("point_blank_per_s", 1.2) * 0.25
	# 站桩：稳定走位的极端形态——缓慢减压（Boss 侧对应「观察/试探」招）
	if player.get("_moving") == true:
		_idle_t = 0.0
	else:
		_idle_t += delta
		if _idle_t > _relief("idle_after", 2.0):
			value -= _relief("idle_extra", 3.0) * delta
	# 常态缓降：不慌的玩家威胁值自然回落
	value -= _relief("calm_decay", 1.5) * delta
	_clamp()
	# 跨入凶暴档播报（每局每档一次，不刷屏）
	if band() == 2 and not _was_aggressive:
		_was_aggressive = true
		if main.hud != null:
			main.hud.log("空气骤然凝重——魔王察觉到了你的紧张…")


## 档位：0 冷静 / 1 常态 / 2 凶暴
func band() -> int:
	var bands: Dictionary = _cfg().get("bands", {})
	if value >= float(bands.get("aggressive", 85.0)):
		return 2
	if value < float(bands.get("calm", 30.0)):
		return 0
	return 1


## Boss 招式池当前权重：方案「低/高威胁两列」按威胁值线性插值。
## 返回 {move_id: weight}；moves 段里没有的招不返回（= 该招关闭）。
func move_weights() -> Dictionary:
	var out := {}
	var moves: Dictionary = _cfg().get("moves", {})
	var t := clampf(value, 0.0, 100.0) / 100.0
	for mid in moves:
		var mv: Dictionary = moves[mid]
		out[mid] = maxf(0.0, lerpf(float(mv.get("low", 0.0)), float(mv.get("high", 0.0)), t))
	return out


func debug_info() -> String:
	if not bool(_cfg().get("enabled", true)):
		return "威胁值: 关闭"
	return "威胁值: %.0f (%s)" % [value, ["冷静", "常态", "凶暴"][band()]]
