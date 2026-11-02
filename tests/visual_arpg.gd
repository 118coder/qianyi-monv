extends SceneTree
## ARPG 视觉验证：godot --write-movie ... -s res://tests/visual_arpg.gd
## 选人画面 → 自动选剑士 → 朝最近敌人移动并连打普攻 → 放技能 → 看特效。

func _initialize() -> void:
	_watchdog()
	_run()


func _watchdog() -> void:
	await create_timer(90.0).timeout
	quit(2)


func _nearest(main: Node) -> int:
	return main.world.mobs.nearest(main.player.position)


func _run() -> void:
	var ps: PackedScene = load("res://arpg/main.tscn")
	var main: Node = ps.instantiate()
	root.add_child(main)
	for i in 8:
		await process_frame          # 选人画面帧

	main.start_run("fencer")
	for i in 12:
		await process_frame          # 刚进地牢的画面

	for phase in 3:
		var mi := _nearest(main)
		if mi >= 0:
			var dir: Vector2 = (main.world.mobs.pos[mi] - main.player.position).normalized()
			Input.action_press("move_right" if dir.x > 0.2 else ("move_left" if dir.x < -0.2 else ""))
			Input.action_press("move_down" if dir.y > 0.2 else ("move_up" if dir.y < -0.2 else ""))
		Input.action_press("attack")
		for i in 22:
			await process_frame
		Input.action_release("attack")
		Input.action_release("move_right")
		Input.action_release("move_left")
		Input.action_release("move_up")
		Input.action_release("move_down")

	Input.action_press("skill")
	for i in 4:
		await process_frame
	Input.action_release("skill")
	for i in 26:
		await process_frame
	print("VISUAL DONE  mobs=%d  player_hp=%d  kills=%d" % [
		main.world.mob_count(), main.player.hp, main.kills])
	quit(0)
