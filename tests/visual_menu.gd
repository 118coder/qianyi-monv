extends SceneTree
## 角色菜单视觉验证：godot --write-movie ... -s res://tests/visual_menu.gd
func _initialize() -> void:
	_run()
func _run() -> void:
	var ps: PackedScene = load("res://arpg/main.tscn")
	var main: Node = ps.instantiate()
	root.add_child(main)
	for i in 6:
		await process_frame
	main.start_run("witch")
	for i in 8:
		await process_frame
	# 打开角色菜单（默认状态页）
	main._toggle_menu()
	for i in 6:
		await process_frame
	# 切到背包页
	main.hud._switch_menu_tab("背包")
	for i in 6:
		await process_frame
	# 切到任务页
	main.hud._switch_menu_tab("任务")
	for i in 6:
		await process_frame
	quit(0)
