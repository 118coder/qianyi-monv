class_name ArpgPossessionManager
extends RefCounted
## 主控切换统一入口（需求书 §5.4 / §7 PossessionManager）：
## · 状态连续：单位各自的 HP/SP/CD/指令/仇恨天然挂在单位上，切换只换「谁读输入」
## · 限制：死亡禁止、APC 标签禁止、切换冷却（防卡 CD / 取消惩罚滥用）
## · 反馈：清空输入缓冲、镜头/技能栏/提示随主控走、切换提示与镜头过渡
## · 特殊状态：被主控单位死亡 → 强制切回玩家

var main: Node
var current_unit: Node2D = null
var last_switch_ms := -99999999.0


func setup(m: Node, initial: Node2D) -> void:
	main = m
	current_unit = initial


func is_possessed(u) -> bool:
	# 主控单位可能是"已被释放的节点"（换层重建玩家/队友阵亡移出队伍）。
	# 这时不能把它当成有效主控，否则所有单位都判定为"不是主控" → 输入全失效。
	if current_unit == null or not is_instance_valid(current_unit):
		return u == main.player
	return u == current_unit


func cooldown_left() -> float:
	var cd := float(ArpgPartyConfig.cfg("possession_cooldown"))
	var passed := (Time.get_ticks_msec() - last_switch_ms) / 1000.0
	return maxf(0.0, cd - passed)


## 切换资格检查（返回原因；空串=可切换）
func switch_block_reason(u) -> String:
	if u == null:
		return "目标不存在"
	if u == current_unit:
		return ""
	if u.dead:
		return "目标已倒下"
	if u != main.player and not bool(u.tags.get("can_possess", true)):
		return "该单位无法被主控（APC）"
	if cooldown_left() > 0.0:
		return "切换冷却中（%.1fs）" % cooldown_left()
	return ""


func switch_to(u, ignore_cooldown: bool = false) -> bool:
	if u == current_unit:
		return true
	var reason := switch_block_reason(u)
	if reason != "" and not ignore_cooldown:
		if reason != "":
			main.hud.log("无法切换主控：%s" % reason)
			print("[POSSESS] deny → %s (%s)" % [(u.uid if u != null else "?"), reason])
		return false
	if u == current_unit:
		return true
	var prev := current_unit
	_clear_input()
	current_unit = u
	last_switch_ms = Time.get_ticks_msec()
	_on_changed(u, prev)
	return true


## 被主控单位死亡 / 离队时强制切回玩家（不受冷却限制，规则优先级最高）
func force_back_to_player() -> void:
	if current_unit == main.player:
		return
	var prev := current_unit
	current_unit = main.player
	last_switch_ms = Time.get_ticks_msec()
	_clear_input()
	_on_changed(main.player, prev)


func cycle(reverse: bool = false) -> void:
	var cands: Array = main.party.possessable()
	if cands.size() <= 1:
		return
	var idx: int = cands.find(current_unit)
	if idx < 0:
		idx = 0
	idx = (idx + (cands.size() - 1 if reverse else 1)) % cands.size()
	switch_to(cands[idx])


## 切换时清空输入缓冲，防止残留移动/攻击输入打到新主控
func _clear_input() -> void:
	for a in ["move_left", "move_right", "move_up", "move_down", "attack", "skill", "potion", "interact"]:
		Input.action_release(a)


func _on_changed(u, prev) -> void:
	var uname: String = u.unit_name if u != main.player else main.player.uname
	main.hud.log("主控切换 → %s%s" % [uname, "（%.1fs 冷却）" % float(ArpgPartyConfig.cfg("possession_cooldown")) if u != main.player else ""])
	print("[POSSESS] %s → %s" % [(prev.uid if prev != null else "?"), u.uid])
	main.rumble(0.2, 0.4, 0.18)
	world_flash(u)
	main.on_possession_changed(u, prev)


func world_flash(u) -> void:
	if main.world != null:
		main.world.spawn_nova(u.position, Color(1, 0.95, 0.6))
