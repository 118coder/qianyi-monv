extends SceneTree
## 主线画面捕获（--write-movie 渲染 PNG 序列，供视觉走查）：
## 选人 → 序章对话（含头像/横幅章节名）→ 对话推进 → 挂 autopilot 战斗（暴击数字）→ 任务菜单
func _initialize() -> void:
	_run()
func _run() -> void:
	var ps: PackedScene = load("res://arpg/main.tscn")
	var main: Node = ps.instantiate()
	root.add_child(main)
	for i in 8:
		await process_frame          # 选人屏几帧
	main.start_run("witch")
	for i in 55:
		await process_frame          # 横幅「地下 1 层 · 序章…」+ 序章对话弹出
	for i in 24:
		main.hud._dlg_adv = true     # 逐帧推进对话（拍换行中的文本框）
		await process_frame
	# 挂机器人打怪：暴击数字/伤害数字/掉落吸附入画
	# （main 引用必须手动赋——CLI 模式下由 main.gd 的 --autoplay 分支赋值，手动挂载绕过了它）
	var ap: Node = load("res://arpg/autopilot.gd").new()
	ap.main = main
	main.add_child(ap)
	for i in 90:
		await process_frame
	main.hud._switch_menu_tab("任务")
	main._toggle_menu()
	for i in 12:
		await process_frame
	main._toggle_menu()
	quit(0)
