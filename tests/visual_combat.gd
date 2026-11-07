extends SceneTree
## 战斗系统画面捕获（影之刃方案批 6 走查，--write-movie 渲染 PNG 序列）：
## 方向闪避残影+耐力条 / 完美弹反金闪 / 蓄力重击渐蓝→蓝光斩 /
## Boss 招式池（蓄力突进"!"、范围震地环）/ F1 威胁值行
func _initialize() -> void:
	_run()
func _run() -> void:
	var ps: PackedScene = load("res://arpg/main.tscn")
	var main: Node = ps.instantiate()
	root.add_child(main)
	for i in 8:
		await process_frame
	main.events_silent = true          # _ready 之后覆盖（_ready 会按 DisplayServer 重置它）——跳过序章对话
	main.start_run("fencer")
	for i in 20:
		await process_frame
	var pl = main.player
	pl.iframes = 0.0
	# ① 前闪残影 + 耐力条下降（面向右，闪避同向）
	pl.facing = Vector2.RIGHT
	pl._do_dodge(Vector2(1, 0))
	for i in 6:
		await process_frame
	# ② 完美弹反：架势中吃一口近战伤害（金闪 + 敌人硬直 + 返还反馈）
	var wi: int = main.world.mobs.spawn("wolf", main.player.cell + Vector2i(2, 0), false, false)
	if wi >= 0:
		pl._do_parry()
		pl.take_damage(9, main.world.mobs.pos[wi])
		for i in 10:
			await process_frame
	# ③ 蓄力重击：按住攻击 0.5s（渐蓝→强化重击蓝光斩→nova）
	Input.action_press("attack")
	for i in 5:
		await process_frame
	Input.action_release("attack")
	for i in 8:
		await process_frame
	# ④ Boss 招式池：高威胁 → 蓄力突进/震地优先（nova 保底不变）
	main.threat.value = 90.0
	var bi: int = main.world.mobs.spawn("boss", main.player.cell + Vector2i(4, 0), false, true)
	if bi >= 0:
		main.world.mobs.ult_streak[bi] = 0
		main.world.mobs.pool_t[bi] = 0.0
		main.world.mobs.aggro[bi] = 1
		main.world.mobs.refresh_targets()
		var ev := []
		main.world.mobs._sim_range(bi, bi + 1, 0.016, ev)   # 立即选招（确定性散列）
		main.world.mobs._chunk_events = [ev]
		main.world.mobs._drain_events()                     # 渲染该招的视觉（"!"/震地环）
		for i in 12:
			await process_frame
		# 再强制一记震地（灰环 + 震屏 + 半径内玩家受伤数字）
		main.world.mobs._chunk_events = [[[5, bi, "slam"]]]
		main.world.mobs._drain_events()
		for i in 10:
			await process_frame
	# ⑤ F1 调试面板（威胁值行 + AI 质量 + 各状态）
	main.hud.toggle_debug()
	for i in 10:
		await process_frame
	quit(0)
