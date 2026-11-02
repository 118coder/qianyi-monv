extends SceneTree
## 视觉验证脚本：godot --path . --write-movie ... -s res://tests/visual_check.gd
## 模拟「选中剑士 → 移动 → 待机 → 结束回合（敌方 AI 行动）」并录制成帧。

func _initialize() -> void:
	_run()


func _run() -> void:
	var ps: PackedScene = load("res://srpg/main.tscn")
	var main: Node = ps.instantiate()
	root.add_child(main)
	for i in 14:
		await process_frame

	# 选中剑士，显示范围
	main._select(main.units[0])
	for i in 4:
		await process_frame

	# 移动到 (4,6) 并待机
	main._do_move(Vector2i(4, 6))
	for i in 24:
		await process_frame
	main._on_action_chosen("待机")
	for i in 3:
		await process_frame

	# 结束回合 → 敌方 AI 行动
	main._end_player_turn()
	for i in 120:
		await process_frame
	quit(0)
