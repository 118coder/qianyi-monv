class_name ArpgInputRouter
extends RefCounted
## 输入路由（P1-2 从 main 拆出）：InputMap 注册 + 全局事件分发。
## main._unhandled_input 是薄转发层；本类持有全部键位/手柄配置与 PLAY 态快捷键。

## 用代码注册输入映射（免改 project.godot）：键盘 + Xbox/PS 手柄通用语义键位
static func setup() -> void:
	var defs := {
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"move_up": [KEY_W, KEY_UP],
		"move_down": [KEY_S, KEY_DOWN],
		"attack": [KEY_J, KEY_Z],
		"skill": [KEY_K, KEY_X],
		"potion": [KEY_Q],
		"interact": [KEY_E],
	}
	for action in defs:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in defs[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)

	# —— 手柄（Godot 语义键位：A=Xbox A/PS叉, X=Xbox X/PS方块, B=Xbox B/PS圆圈, Y=Xbox Y/PS三角）——
	var face := {
		"attack": [JOY_BUTTON_A],       # A / 叉：普攻
		"skill": [JOY_BUTTON_X],        # X / 方块：技能
		"interact": [JOY_BUTTON_B],     # B / 圆圈：互动
		"potion": [JOY_BUTTON_Y],       # Y / 三角：药水
	}
	for action in face:
		for b in face[action]:
			var jb := InputEventJoypadButton.new()
			jb.button_index = b
			InputMap.action_add_event(action, jb)
	# 左摇杆 + 十字键移动
	var axes := [
		["move_left", JOY_AXIS_LEFT_X, -1.0], ["move_right", JOY_AXIS_LEFT_X, 1.0],
		["move_up", JOY_AXIS_LEFT_Y, -1.0], ["move_down", JOY_AXIS_LEFT_Y, 1.0],
	]
	for a in axes:
		var m := InputEventJoypadMotion.new()
		m.axis = a[1]
		m.axis_value = a[2]
		InputMap.action_add_event(a[0], m)
	var dpad := {
		"move_left": JOY_BUTTON_DPAD_LEFT, "move_right": JOY_BUTTON_DPAD_RIGHT,
		"move_up": JOY_BUTTON_DPAD_UP, "move_down": JOY_BUTTON_DPAD_DOWN,
	}
	for action in dpad:
		var db := InputEventJoypadButton.new()
		db.button_index = dpad[action]
		InputMap.action_add_event(action, db)
	# 扳机：RT 攻击 / LT 技能
	var rt := InputEventJoypadMotion.new()
	rt.axis = JOY_AXIS_TRIGGER_RIGHT
	rt.axis_value = 1.0
	InputMap.action_add_event("attack", rt)
	var lt := InputEventJoypadMotion.new()
	lt.axis = JOY_AXIS_TRIGGER_LEFT
	lt.axis_value = 1.0
	InputMap.action_add_event("skill", lt)
	# Start = 暂停（并入 ui_cancel）
	var st := InputEventJoypadButton.new()
	st.button_index = JOY_BUTTON_START
	InputMap.action_add_event("ui_cancel", st)
	# 队伍/主控/调试
	var more := {
		"possession_next": [KEY_TAB],
		"squad_cmd": [KEY_T],
		"debug_panel": [KEY_F1],
		"save_party": [KEY_F9],
		"load_party": [KEY_F10],
		"char_menu": [KEY_C],
		"skill2": [KEY_L],
		"skill3": [KEY_U],
		"reload_balance": [KEY_F2],
		"reload_map": [KEY_F3],
		"restart_run": [KEY_F4],
	}
	for action in more:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in more[action]:
			var ke := InputEventKey.new()
			ke.physical_keycode = key
			InputMap.action_add_event(action, ke)
	# 摇杆死区
	for a2 in ["move_left", "move_right", "move_up", "move_down"]:
		InputMap.action_set_deadzone(a2, 0.28)


## 全局事件分发（PLAY 态快捷键 + 暂停切换）。返回 true = 事件已消费。
static func unhandled(main: Node, event: InputEvent) -> bool:
	if event.is_action_pressed("ui_cancel"):
		if main.state == main.State.PLAY and not main.get_tree().paused:
			main.get_tree().paused = true
			main.hud.show_pause()
		elif main.get_tree().paused:
			main._resume()
		return true
	if main.state != main.State.PLAY or main.get_tree().paused:
		return false
	if event.is_action_pressed("possession_next"):
		main.possession.cycle()
	elif event.is_action_pressed("squad_cmd"):
		main._squad_cmd_i = (main._squad_cmd_i + 1) % 3
		main.party.set_squad_command(["active", "follow", "hold"][main._squad_cmd_i])
	elif event.is_action_pressed("debug_panel"):
		main.hud.toggle_debug()
	elif event.is_action_pressed("char_menu"):
		main._toggle_menu()
	elif event.is_action_pressed("save_party"):
		main._save_party()
	elif event.is_action_pressed("load_party"):
		main._load_party()
	elif event.is_action_pressed("reload_balance"):
		main._manual_reload_balance()
	elif event.is_action_pressed("reload_map"):
		main.build_floor()
		main._map_mtime = main._file_mtime(SrpgMapLoader.PATH)
		main.hud.log("地图已热重载（保留队伍状态）")
	elif event.is_action_pressed("restart_run"):
		main.start_run(main.char_id)
	else:
		return false
	return true
