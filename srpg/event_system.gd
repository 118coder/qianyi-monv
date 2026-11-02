class_name SrpgEventSystem
extends RefCounted
## 事件引擎（类 RPG Maker）：检查触发条件 → 依次执行命令序列。
## 触发器 trigger.type：
##   turn_start {turn, phase: player/enemy/any}   回合开始
##   unit_death {unit: 单位uid或模板id}            单位死亡
##   zone      {rect:[x,y,w,h], faction}          单位移动结束后进入区域
## 命令 commands[].cmd：
##   dialogue {speaker: 模板id或narrator, lines: []}  显示对话（点击/空格继续）
##   spawn    {tpl: 模板id, cells: [[x,y],...]}       增援
##   set_flag {flag, value}                           设置旗标（配合 condition 做条件分支）
##   win / lose                                        立即胜利 / 失败
## 事件可带 condition {flag, equals}：旗标满足才触发；once: 只触发一次（默认 true）

var main: Node
var fired := {}


func _init(m: Node) -> void:
	main = m


func on_phase_start(phase: String, turn: int) -> void:
	await _fire("turn_start", {"phase": phase, "turn": turn})


func on_unit_dead(u) -> void:
	await _fire("unit_death", {"uid": u.uid, "tpl": u.tpl_id})


func on_unit_moved(u) -> void:
	await _fire("zone", {"faction": u.faction, "cell": u.cell})


func _fire(tname: String, ctx: Dictionary) -> void:
	var evs: Array = main.map_events
	for i in evs.size():
		var ev: Dictionary = evs[i]
		if not _matches(ev, tname, ctx, i):
			continue
		fired[i] = true
		await _run_commands(ev.get("commands", []))
		if main.over:
			return


func _matches(ev: Dictionary, tname: String, ctx: Dictionary, idx: int) -> bool:
	var trig: Dictionary = ev.get("trigger", {})
	if str(trig.get("type", "")) != tname:
		return false
	if ev.get("once", true) and fired.has(idx):
		return false
	match tname:
		"turn_start":
			if int(trig.get("turn", 1)) != int(ctx["turn"]):
				return false
			var ph := str(trig.get("phase", "any"))
			if ph != "any" and ph != ctx["phase"]:
				return false
		"unit_death":
			var want := str(trig.get("unit", ""))
			if want != "" and want != ctx["uid"] and want != ctx["tpl"]:
				return false
		"zone":
			var f := str(trig.get("faction", "any"))
			if f != "any" and f != ctx["faction"]:
				return false
			var r: Array = trig.get("rect", [0, 0, 0, 0])
			var c: Vector2i = ctx["cell"]
			if c.x < int(r[0]) or c.y < int(r[1]) \
					or c.x >= int(r[0]) + int(r[2]) or c.y >= int(r[1]) + int(r[3]):
				return false
	var cond: Dictionary = ev.get("condition", {})
	var fl := str(cond.get("flag", ""))
	if fl != "":
		if bool(main.flags.get(fl, false)) != bool(cond.get("equals", true)):
			return false
	return true


func _run_commands(cmds: Array) -> void:
	for c in cmds:
		match str(c.get("cmd", "")):
			"dialogue":
				await main.ui.show_dialogue(str(c.get("speaker", "narrator")), c.get("lines", []))
			"spawn":
				main.spawn_units(str(c.get("tpl", "orc")), c.get("cells", []))
				await main.get_tree().create_timer(0.35).timeout
			"set_flag":
				main.flags[str(c.get("flag", ""))] = bool(c.get("value", true))
			"win":
				main._game_over(true)
				return
			"lose":
				main._game_over(false)
				return
