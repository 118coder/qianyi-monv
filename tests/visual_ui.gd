extends SceneTree
## UI 全表面渲染：选人→战斗→菜单各页→商店→结算→暂停
func _initialize() -> void:
	_run()
func _run() -> void:
	var ps: PackedScene = load("res://arpg/main.tscn")
	var main: Node = ps.instantiate()
	root.add_child(main)
	for i in 6:
		await process_frame
	main.events_silent = true   # 本脚本捕获各 UI 面：事件对话会暂停世界盖住画面
	main.start_run("witch")
	for i in 10:
		await process_frame
	main.hud.menu_screen._switch_menu_tab("状态")
	main._toggle_menu()
	for i in 6:
		await process_frame
	main._toggle_menu()
	main.hud.menu_screen._switch_menu_tab("背包")
	main._toggle_menu()
	for i in 6:
		await process_frame
	main._toggle_menu()
	main.hud.show_shop()
	for i in 6:
		await process_frame
	main.hud.shop_root.visible = false
	main._settle(true, "测试凯旋", "flavor")
	for i in 6:
		await process_frame
	main._resume()
	paused = true
	main.hud.show_pause()
	for i in 6:
		await process_frame
	paused = false
	main.hud.hide_pause()
	quit(0)
