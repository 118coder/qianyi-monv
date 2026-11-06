class_name EditorAdvancedTabs
extends RefCounted
## 编辑器进阶页签：节点式事件图 / AI 状态机可视化 / 系统数值面板。
## 面向小白的可视化：画布只画流程（节点链+IF 缩进分支），编辑走右侧属性面板，
## 参数全部中文标签直写 balance（热重载）。

const NODE_W := 360.0
const NODE_HEAD := 26.0
const NODE_ROW := 24.0
const INDENT := 56.0
const MARGIN := 24.0

# 节点类型 → [标题, 头部颜色, 添加按钮文案]
const NODE_TYPES := {
	"dialogue": ["对话", Color(0.25, 0.42, 0.75), "＋对话"],
	"spawn": ["增援", Color(0.75, 0.45, 0.2), "＋增援"],
	"spawn_friend": ["队友入队", Color(0.35, 0.65, 0.45), "＋队友"],
	"set_flag": ["设旗标", Color(0.5, 0.35, 0.7), "＋旗标"],
	"if": ["条件分支", Color(0.2, 0.55, 0.55), "＋条件"],
	"camera": ["镜头调度", Color(0.3, 0.5, 0.3), "＋镜头"],
	"wait": ["等待", Color(0.4, 0.4, 0.45), "＋等待"],
	"fx": ["演出特效", Color(0.6, 0.4, 0.3), "＋特效"],
	"music": ["切换音乐", Color(0.45, 0.3, 0.5), "＋音乐"],
	"give_gold": ["给金币", Color(0.6, 0.55, 0.25), "＋金币"],
	"give_item": ["给物品", Color(0.5, 0.5, 0.3), "＋物品"],
	"give_xp": ["给经验", Color(0.35, 0.5, 0.45), "＋经验"],
	"heal_full": ["全员回满", Color(0.3, 0.6, 0.4), "＋回满"],
	"win": ["★胜利", Color(0.2, 0.55, 0.3), "＋胜利"],
	"lose": ["★失败", Color(0.6, 0.25, 0.2), "＋失败"],
}


## 把命令树铺平为 [{cmd, depth, path}]（path 供选中/增删/移动定位）
static func flatten(cmds: Array, depth: int, path: Array, out: Array) -> void:
	for i in cmds.size():
		var c: Dictionary = cmds[i]
		var p := path.duplicate()
		p.append(i)
		out.append({"cmd": c, "depth": depth, "path": p})
		if str(c.get("cmd", "")) == "if":
			flatten(c.get("then", []), depth + 1, p + ["then"], out)
			flatten(c.get("else", []), depth + 1, p + ["else"], out)


static func chain_at(cmds: Array, path: Array) -> Array:
	var cur := cmds
	var i := 0
	while i < path.size():
		var idx: int = int(path[i])
		if idx >= cur.size():
			return cur
		var node: Dictionary = cur[idx]
		i += 1
		if i < path.size() and path[i] is String:
			cur = node.get(str(path[i]), [])
			i += 1
	return cur


static func node_at(cmds: Array, path: Array) -> Dictionary:
	var chain := chain_at(cmds, path)
	var idx := int(path[-1]) if path.size() > 0 else -1
	return chain[idx] if idx >= 0 and idx < chain.size() else {}


static func delete_at(ed, path: Array) -> void:
	var parent_chain := chain_at(ed.events[ed.editing_event]["commands"], path.slice(0, path.size() - 1))
	var idx := int(path[-1])
	if idx >= 0 and idx < parent_chain.size():
		parent_chain.remove_at(idx)


static func move_at(ed, path: Array, dir: int) -> void:
	var parent_chain := chain_at(ed.events[ed.editing_event]["commands"], path.slice(0, path.size() - 1))
	var idx := int(path[-1])
	var j := idx + dir
	if j < 0 or j >= parent_chain.size():
		return
	var tmp = parent_chain[idx]
	parent_chain[idx] = parent_chain[j]
	parent_chain[j] = tmp


static func add_after(ed, path: Array, cmd: Dictionary) -> void:
	var chain := chain_at(ed.events[ed.editing_event]["commands"], path.slice(0, path.size() - 1))
	var idx := int(path[-1]) + 1
	chain.insert(mini(idx, chain.size()), cmd)


static func add_into_branch(ed, path: Array, branch: String, cmd: Dictionary) -> void:
	var node: Dictionary = node_at(ed.events[ed.editing_event]["commands"], path)
	if not node.has(branch):
		node[branch] = []
	node[branch].append(cmd)


static func new_command(cmd: String) -> Dictionary:
	match cmd:
		"dialogue":
			return {"cmd": "dialogue", "speaker": "narrator", "lines": ["……"]}
		"spawn":
			return {"cmd": "spawn", "tpl": "orc", "cells": []}
		"spawn_friend":
			return {"cmd": "spawn_friend", "tpl": "archer"}
		"set_flag":
			return {"cmd": "set_flag", "flag": "flag_1", "value": true}
		"if":
			return {"cmd": "if", "flag": "flag_1", "equals": true, "then": [], "else": []}
		"camera":
			return {"cmd": "camera", "mode": "focus_cell", "cell": [9, 7], "dur": 1.5}
		"wait":
			return {"cmd": "wait", "time": 1.0}
		"fx":
			return {"cmd": "fx", "kind": "nova", "at": "player", "cell": [9, 7]}
		"music":
			return {"cmd": "music", "track": "dungeon"}
		"give_gold":
			return {"cmd": "give_gold", "amount": 50}
		"give_item":
			return {"cmd": "give_item", "tpl": "potion", "count": 1}
		"give_xp":
			return {"cmd": "give_xp", "amount": 30}
		"heal_full":
			return {"cmd": "heal_full"}
		"win":
			return {"cmd": "win"}
		"lose":
			return {"cmd": "lose"}
	return {}


## ———————— 事件页构建（列表 + 画布 + 属性面板） ————————

static func build_event_page(ed) -> void:
	ed.event_canvas = EditorEventCanvas.new()
	ed.event_canvas.ed = ed
	ed.event_props = VBoxContainer.new()
	ed.event_props.custom_minimum_size = Vector2(340, 0)
	ed.event_props.add_theme_constant_override("separation", 6)


static func build_event_props(ed) -> void:
	for c in ed.event_props.get_children():
		c.queue_free()
	if ed.editing_event < 0 or ed.editing_event >= ed.events.size():
		ed.event_props.add_child(ed._lbl("← 选择一个节点"))
		return
	var ev: Dictionary = ed.events[ed.editing_event]
	var path: Array = ed._sel_path
	var is_trigger: bool = path.is_empty()
	var node: Dictionary = ev["trigger"] if is_trigger else node_at(ev["commands"], path)

	ed.event_props.add_child(ed._lbl("— 节点属性 —"))
	if is_trigger:
		_build_trigger_fields(ed, ev)
	else:
		_build_command_fields(ed, ev, path, node)
	ed.event_props.add_child(HSeparator.new())
	ed.event_props.add_child(ed._lbl("移动 / 删除"))
	if not is_trigger:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 4)
		ed.event_props.add_child(h)
		h.add_child(_small_btn("↑", func(): move_at(ed, path, -1); ed.refresh_event_canvas()))
		h.add_child(_small_btn("↓", func(): move_at(ed, path, 1); ed.refresh_event_canvas()))
		h.add_child(_small_btn("删除", func(): delete_at(ed, path); ed._select_event(ed.editing_event)))
	ed.event_props.add_child(ed._lbl("在此节点后添加："))
	var pal := GridContainer.new()
	pal.columns = 3
	pal.add_theme_constant_override("h_separation", 4)
	ed.event_props.add_child(pal)
	for k in NODE_TYPES:
		var b := _small_btn(NODE_TYPES[k][2], func(): add_after(ed, path, new_command(k)); ed._select_event(ed.editing_event))
		pal.add_child(b)


static func _build_trigger_fields(ed, ev: Dictionary) -> void:
	var trig: Dictionary = ev["trigger"]
	var trow := HBoxContainer.new()
	ed.event_props.add_child(trow)
	var type_opt := OptionButton.new()
	type_opt.add_item("回合开始")
	type_opt.add_item("单位死亡")
	type_opt.add_item("进入区域")
	type_opt.select(["turn_start", "unit_death", "zone"].find(str(trig.get("type", "turn_start"))))
	type_opt.item_selected.connect(func(i):
		trig["type"] = ["turn_start", "unit_death", "zone"][i]
		ed.refresh_event_canvas())
	ed.event_props.add_child(type_opt)
	match str(trig.get("type", "turn_start")):
		"turn_start":
			var prow := HBoxContainer.new()
			ed.event_props.add_child(prow)
			prow.add_child(ed._lbl("第"))
			var spin := SpinBox.new()
			spin.min_value = 1
			spin.max_value = 99
			spin.value = int(trig.get("turn", 1))
			spin.value_changed.connect(func(v): trig["turn"] = int(v))
			prow.add_child(spin)
			prow.add_child(ed._lbl("回合 ·"))
			var ph := OptionButton.new()
			ph.add_item("玩家回合")
			ph.add_item("敌方回合")
			ph.add_item("任意")
			ph.select(["player", "enemy", "any"].find(str(trig.get("phase", "player"))))
			ph.item_selected.connect(func(i): trig["phase"] = ["player", "enemy", "any"][i])
			prow.add_child(ph)
		"unit_death":
			var prow := HBoxContainer.new()
			ed.event_props.add_child(prow)
			prow.add_child(ed._lbl("单位"))
			var uo := OptionButton.new()
			uo.add_item("（任意单位）")
			uo.set_item_metadata(0, "")
			for p in ed.placements:
				uo.add_item("%s" % p["uid"])
				uo.set_item_metadata(uo.item_count - 1, p["uid"])
			uo.select(0)
			uo.item_selected.connect(func(i): trig["unit"] = uo.get_item_metadata(i))
			prow.add_child(uo)
		"zone":
			var prow := HBoxContainer.new()
			ed.event_props.add_child(prow)
			prow.add_child(ed._lbl("谁进入"))
			var fo := OptionButton.new()
			fo.add_item("我方")
			fo.add_item("敌方")
			fo.add_item("任意")
			fo.select(["player", "enemy", "any"].find(str(trig.get("faction", "player"))))
			fo.item_selected.connect(func(i): trig["faction"] = ["player", "enemy", "any"][i])
			prow.add_child(fo)
			prow.add_child(ed._lbl("区域 %s" % str(trig.get("rect", "未设置"))))
			var pick := Button.new()
			pick.text = "画布框选"
			pick.pressed.connect(func():
				ed.cur_tool = 2   # EdTool.ZONE
				ed.zone_drag_start = Vector2i(-1, -1))
			prow.add_child(pick)


static func _build_command_fields(ed, ev: Dictionary, path: Array, node: Dictionary) -> void:
	var kind := str(node.get("cmd", ""))
	match kind:
		"dialogue":
			ed.event_props.add_child(ed._lbl("说话人"))
			var so := OptionButton.new()
			so.add_item("旁白")
			so.set_item_metadata(0, "narrator")
			for tpl_id in ArpgBalance.CHARS:
				so.add_item(ArpgBalance.CHARS[tpl_id]["name"])
				so.set_item_metadata(so.item_count - 1, tpl_id)
				if tpl_id == str(node.get("speaker", "")):
					so.select(so.item_count - 1)
			so.item_selected.connect(func(i): node["speaker"] = so.get_item_metadata(i))
			ed.event_props.add_child(so)
			ed.event_props.add_child(ed._lbl("台词（每行一句）"))
			var te := TextEdit.new()
			te.text = "\n".join(node.get("lines", []))
			te.custom_minimum_size = Vector2(0, 70)
			te.text_changed.connect(func(): node["lines"] = te.text.split("\n"))
			ed.event_props.add_child(te)
		"spawn":
			ed.event_props.add_child(ed._lbl("增援单位"))
			var so := OptionButton.new()
			for tpl_id in ArpgBalance.ENEMIES:
				so.add_item(ArpgBalance.ENEMIES[tpl_id]["name"])
				so.set_item_metadata(so.item_count - 1, tpl_id)
				if tpl_id == str(node.get("tpl", "orc")):
					so.select(so.item_count - 1)
			so.item_selected.connect(func(i): node["tpl"] = so.get_item_metadata(i))
			ed.event_props.add_child(so)
			ed.event_props.add_child(ed._lbl("出生格：%d 个（选「点选格子」后到地形画布点击）" % (node.get("cells", []) as Array).size()))
			var pick := Button.new()
			pick.text = "点选格子"
			pick.pressed.connect(func():
				ed.editing_spawn_cmd = node
				ed.cur_tool = 3)
			ed.event_props.add_child(pick)
		"set_flag":
			ed.event_props.add_child(ed._lbl("旗标名"))
			var fe := LineEdit.new()
			fe.text = str(node.get("flag", ""))
			fe.text_changed.connect(func(t): node["flag"] = t)
			ed.event_props.add_child(fe)
			var vo := OptionButton.new()
			vo.add_item("设为真")
			vo.add_item("设为假")
			vo.select(0 if bool(node.get("value", true)) else 1)
			vo.item_selected.connect(func(i): node["value"] = i == 0)
			ed.event_props.add_child(vo)
		"if":
			ed.event_props.add_child(ed._lbl("条件旗标"))
			var fe2 := LineEdit.new()
			fe2.text = str(node.get("flag", ""))
			fe2.text_changed.connect(func(t): node["flag"] = t)
			ed.event_props.add_child(fe2)
			var eq := OptionButton.new()
			eq.add_item("为真时执行「是」分支")
			eq.add_item("为假时执行「是」分支")
			eq.select(0 if bool(node.get("equals", true)) else 1)
			eq.item_selected.connect(func(i): node["equals"] = i == 0)
			ed.event_props.add_child(eq)
			ed.event_props.add_child(ed._lbl("「是」分支 %d 个节点 /「否」分支 %d 个节点" % [
				(node.get("then", []) as Array).size(), (node.get("else", []) as Array).size()]))
			ed.event_props.add_child(ed._lbl("提示：先用「设旗标」改变旗标，再用本节点分流"))
		"camera":
			ed.event_props.add_child(ed._lbl("镜头调度"))
			var mo := OptionButton.new()
			mo.add_item("聚焦格子")
			mo.add_item("聚焦玩家")
			mo.select(0 if str(node.get("mode", "focus_cell")) == "focus_cell" else 1)
			mo.item_selected.connect(func(i): node["mode"] = "focus_cell" if i == 0 else "focus_player")
			ed.event_props.add_child(mo)
			ed.event_props.add_child(_cell_spin(node, "cell"))
			_add_dur_spin(ed, node)
		"wait":
			ed.event_props.add_child(_dur_spin(node, "time", "等待秒数"))
		"fx":
			ed.event_props.add_child(ed._lbl("特效种类"))
			var ko := OptionButton.new()
			for pair in [["nova", "冲击波"], ["spark", "火花"], ["shake", "震屏"], ["heal", "治疗光环"]]:
				ko.add_item(pair[1])
				ko.set_item_metadata(ko.item_count - 1, pair[0])
				if pair[0] == str(node.get("kind", "nova")):
					ko.select(ko.item_count - 1)
			ko.item_selected.connect(func(i): node["kind"] = ko.get_item_metadata(i))
			ed.event_props.add_child(ko)
			ed.event_props.add_child(_cell_spin(node, "cell"))
		"music":
			ed.event_props.add_child(ed._lbl("曲目"))
			var mo2 := OptionButton.new()
			for pair in [["dungeon", "地牢"], ["town", "城镇"], ["boss", "Boss"], ["title", "标题"]]:
				mo2.add_item(pair[1])
				mo2.set_item_metadata(mo2.item_count - 1, pair[0])
				if pair[0] == str(node.get("track", "dungeon")):
					mo2.select(mo2.item_count - 1)
			mo2.item_selected.connect(func(i): node["track"] = mo2.get_item_metadata(i))
			ed.event_props.add_child(mo2)
		"give_gold":
			ed.event_props.add_child(_amount_spin(node, "amount", "金币数量", 50))
		"give_xp":
			ed.event_props.add_child(_amount_spin(node, "amount", "经验数量", 30))
		"give_item":
			ed.event_props.add_child(ed._lbl("物品"))
			var io2 := OptionButton.new()
			for iid in ArpgBalance.ITEMS:
				io2.add_item(ArpgBalance.ITEMS[iid]["name"])
				io2.set_item_metadata(io2.item_count - 1, iid)
				if iid == str(node.get("tpl", "potion")):
					io2.select(io2.item_count - 1)
			io2.item_selected.connect(func(i): node["tpl"] = io2.get_item_metadata(i))
			ed.event_props.add_child(io2)
			ed.event_props.add_child(_amount_spin(node, "count", "数量", 1))
		"win":
			ed.event_props.add_child(ed._lbl("★ 立即胜利"))
		"lose":
			ed.event_props.add_child(ed._lbl("★ 立即失败"))


static func _cell_spin(node: Dictionary, key: String) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	var cc: Array = node.get(key, [9, 7])
	var sx := SpinBox.new()
	sx.min_value = 0
	sx.max_value = 99
	sx.value = int(cc[0])
	sx.value_changed.connect(func(v): var a: Array = node.get(key, [0, 0]); a[0] = int(v); node[key] = a)
	var sy := SpinBox.new()
	sy.min_value = 0
	sy.max_value = 99
	sy.value = int(cc[1])
	sy.value_changed.connect(func(v): var a: Array = node.get(key, [0, 0]); a[1] = int(v); node[key] = a)
	h.add_child(sx)
	h.add_child(sy)
	return h


static func _add_dur_spin(ed, node: Dictionary) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	h.add_child(ed._lbl("持续秒数"))
	var sp := SpinBox.new()
	sp.min_value = 0.2
	sp.max_value = 10.0
	sp.step = 0.1
	sp.value = float(node.get("dur", 1.5))
	sp.value_changed.connect(func(v): node["dur"] = float(v))
	h.add_child(sp)
	ed.event_props.add_child(h)


static func _dur_spin(node: Dictionary, key: String, label: String) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	var l := Label.new()
	l.text = label
	h.add_child(l)
	var sp := SpinBox.new()
	sp.min_value = 0.1
	sp.max_value = 30.0
	sp.step = 0.1
	sp.value = float(node.get(key, 1.0))
	sp.value_changed.connect(func(v): node[key] = float(v))
	h.add_child(sp)
	return h


static func _amount_spin(node: Dictionary, key: String, label: String, def: int) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	var l := Label.new()
	l.text = label
	h.add_child(l)
	var sp := SpinBox.new()
	sp.min_value = 1
	sp.max_value = 99999
	sp.value = int(node.get(key, def))
	sp.value_changed.connect(func(v): node[key] = int(v))
	h.add_child(sp)
	return h


static func _small_btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b


## ———————— AI 状态机页（可视化 + 调参，写入 balance 热重载） ————————

static func build_ai_page(ed) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	ed.pages["AI 状态机"] = v
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	v.add_child(top)
	top.add_child(ed._lbl("敌人模板"))
	var pick := OptionButton.new()
	for tpl_id in ArpgBalance.ENEMIES:
		pick.add_item(ArpgBalance.ENEMIES[tpl_id]["name"])
		pick.set_item_metadata(pick.item_count - 1, tpl_id)
	pick.add_item("★ " + ArpgBalance.BOSS["name"])
	pick.set_item_metadata(pick.item_count - 1, "boss")
	pick.item_selected.connect(func(i):
		ed.ai_tpl = str(pick.get_item_metadata(i))
		ed.refresh_ai_page())
	top.add_child(pick)
	top.add_child(ed._lbl("改动即时生效于新刷出的单位；保存后全游戏热重载"))
	var canvas := EditorAIStateCanvas.new()
	canvas.ed = ed
	canvas.custom_minimum_size = Vector2(620, 240)
	v.add_child(canvas)
	ed.ai_canvas = canvas
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	v.add_child(right)
	ed.ai_params = right
	var save := _small_btn("保存到 balance.json（游戏自动热重载）", func():
		ArpgBalance.save_to_file()
		ed._set_status("已保存，游戏将自动热重载"))
	v.add_child(save)


static func refresh_ai_page(ed) -> void:
	if ed.ai_canvas != null:
		ed.ai_canvas.queue_redraw()
	if ed.ai_params == null:
		return
	for c in ed.ai_params.get_children():
		c.queue_free()
	var tpl: Dictionary = ArpgBalance.BOSS if ed.ai_tpl == "boss" else ArpgBalance.ENEMIES.get(ed.ai_tpl, {})
	if tpl.is_empty():
		return
	ed.ai_params.add_child(ed._lbl("「%s」参数（即时写入 balance）" % tpl["name"]))
	# target 字典按引用绑定，改动直达 balance 数据
	var target: Dictionary = ArpgBalance.BOSS if ed.ai_tpl == "boss" else ArpgBalance.ENEMIES[ed.ai_tpl]
	for pair in [["hp", "生命", 1, 9999, 1], ["atk", "攻击", 1, 999, 1], ["spd", "移速", 10, 400, 1],
			["xp", "经验", 0, 999, 1], ["windup", "蓄力秒", 0.1, 3.0, 0.1], ["cool", "冷却秒", 0.1, 6.0, 0.1],
			["atk_range", "攻击距离", 10, 400, 1]]:
		var key: String = pair[0]
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		var l: Label = ed._lbl(pair[1])
		l.custom_minimum_size = Vector2(76, 0)
		h.add_child(l)
		var sp := SpinBox.new()
		sp.min_value = float(pair[2])
		sp.max_value = float(pair[3])
		sp.step = float(pair[4])
		sp.value = float(tpl.get(key, 0))
		sp.custom_minimum_size = Vector2(90, 0)
		sp.value_changed.connect(func(v: float): target[key] = int(v) if float(pair[4]) == 1.0 and pair[0] != "spd" else float(v))
		h.add_child(sp)
		ed.ai_params.add_child(h)
	var gh := HBoxContainer.new()
	gh.add_theme_constant_override("separation", 6)
	var gl: Label = ed._lbl("仇恨半径")
	gl.custom_minimum_size = Vector2(76, 0)
	gh.add_child(gl)
	var gs := SpinBox.new()
	gs.min_value = 40.0
	gs.max_value = 800.0
	gs.step = 5.0
	gs.value = float(ArpgBalance.data.get("aggro_range", 185.0))
	gs.value_changed.connect(func(v: float): ArpgBalance.data["aggro_range"] = float(v))
	gh.add_child(gs)
	ed.ai_params.add_child(gh)


## AI 状态画布
class EditorAIStateCanvas:
	extends Control
	var ed

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.1), true)
		var tpl: Dictionary = ArpgBalance.BOSS if ed.ai_tpl == "boss" else ArpgBalance.ENEMIES.get(ed.ai_tpl, {})
		if tpl.is_empty():
			return
		var states: Array = EditorAdvancedTabs.ai_states(tpl)
		var rects := {}
		for s in states:
			var r := Rect2(Vector2(s["x"], s["y"]), Vector2(170, 56))
			rects[s["id"]] = r
			draw_rect(r, Color(s["col"].r, s["col"].g, s["col"].b, 0.28), true)
			draw_rect(r, Color(s["col"].r, s["col"].g, s["col"].b, 0.9), false, 1.5)
			draw_string(ThemeDB.fallback_font, r.position + Vector2(10, 24), str(s["name"]), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 20, 14, Color(0.92, 0.94, 1.0))
			draw_string(ThemeDB.fallback_font, r.position + Vector2(10, 44), "参数见右侧", HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 20, 11, Color(1, 1, 1, 0.5))
		# 转移箭头（游荡→追击→蓄力→攻击/射击；冷却回蓄力；狂暴分支）
		var arrows := [
			["wander", "chase", "发现玩家"],
			["chase", "windup", "进入射程"],
		]
		if str(tpl.get("behavior", "")) == "ranged":
			arrows.append(["windup", "shoot", "蓄力完成"])
			arrows.append(["shoot", "keep", "冷却"])
			arrows.append(["keep", "windup", "再次进入射程"])
		elif str(tpl.get("behavior", "")) == "boss":
			arrows.append(["windup", "ring", "每 3s 并行"])
			arrows.append(["chase", "enrage", "血量<40%"])
			arrows.append(["ring", "chase", "弹幕结束"])
		else:
			arrows.append(["windup", "attack", "蓄力完成"])
			arrows.append(["attack", "windup", "冷却结束"])
		for a in arrows:
			if not rects.has(a[0]) or not rects.has(a[1]):
				continue
			var r0: Rect2 = rects[a[0]]
			var r1: Rect2 = rects[a[1]]
			var p0 := Vector2(r0.end.x, r0.position.y + r0.size.y / 2)
			var p1 := Vector2(r1.position.x, r1.position.y + r1.size.y / 2)
			if a[0] == a[1]:
				continue
			var mid := (p0 + p1) / 2.0
			draw_line(p0, p1, Color(0.75, 0.85, 1.0, 0.6), 1.6)
			var dirv := (p1 - p0).normalized()
			draw_circle(p1, 4.0, Color(0.85, 0.92, 1.0, 0.9))
			draw_string(ThemeDB.fallback_font, mid + Vector2(-24, -6), str(a[2]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.75))


## ———————— 系统数值页（全表单直改 balance） ————————

static func build_systems_page(ed) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	ed.pages["系统数值"] = v
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	v.add_child(top)
	top.add_child(ed._lbl("改完点保存 → 游戏自动热重载（新刷出的单位用新值）"))
	var save := _small_btn("保存到 balance.json", func():
		ArpgBalance.save_to_file()
		ed._set_status("balance.json 已保存，游戏自动热重载"))
	top.add_child(save)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(grid)
	ed.sys_grid = grid


static func refresh_systems(ed) -> void:
	var grid: GridContainer = ed.sys_grid
	if grid == null:
		return
	for c in grid.get_children():
		c.queue_free()
	var data: Dictionary = ArpgBalance.data
	for cid in data.get("chars", {}):
		var c: Dictionary = data["chars"][cid]
		_add_spin(grid, "%s·HP" % c["name"], c, "hp", 1, 9999, 1)
		_add_spin(grid, "%s·攻" % c["name"], c, "atk", 1, 999, 1)
		_add_spin(grid, "%s·移速" % c["name"], c, "spd", 10, 400, 1)
	var boss: Dictionary = data.get("boss", {})
	_add_spin(grid, "魔王·HP", boss, "hp", 1, 99999, 1)
	_add_spin(grid, "魔王·攻", boss, "atk", 1, 999, 1)
	_add_spin(grid, "陷阱率%", data, "trap_chance", 0.0, 1.0, 0.05)
	_add_spin(grid, "精英率%", data, "elite_chance", 0.0, 1.0, 0.05)
	_add_spin(grid, "卖价倍率", data, "sell_ratio", 0.1, 3.0, 0.05)
	_add_spin(grid, "金币下限", data, "gold_drop_min", 0, 999, 1)
	_add_spin(grid, "金币上限", data, "gold_drop_max", 0, 999, 1)
	_add_spin(grid, "经验基数", data, "xp_base", 1, 999, 1)
	_add_spin(grid, "经验/级", data, "xp_per_level", 1, 999, 1)
	var party: Dictionary = data.get("party", {})
	_add_spin(grid, "队伍容量", party, "max_party_size", 0, 64, 1)
	_add_spin(grid, "开局队友", party, "start_friends", 0, 16, 1)
	_add_spin(grid, "切换冷却s", party, "possession_cooldown", 0.0, 10.0, 0.1)


static func _add_spin(grid: GridContainer, label: String, obj: Dictionary, key: String, mn: float, mx: float, step: float) -> void:
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(110, 0)
	grid.add_child(l)
	var sp := SpinBox.new()
	sp.custom_minimum_size = Vector2(90, 0)
	sp.min_value = mn
	sp.max_value = mx
	sp.step = step
	if obj.has(key):
		sp.value = float(obj[key])
	sp.value_changed.connect(func(v: float):
		if step >= 1.0 and mx >= 100:
			obj[key] = int(v)
		else:
			obj[key] = float(v))

static func trigger_title(trig: Dictionary) -> String:
	match str(trig.get("type", "")):
		"turn_start":
			return "回合开始 · 第%d回合%s" % [int(trig.get("turn", 1)), {"player": "·玩家", "enemy": "·敌方", "any": ""}.get(str(trig.get("phase", "")), "")]
		"unit_death":
			return "单位死亡 · %s" % str(trig.get("unit", "任意"))
		"zone":
			return "进入区域 · %s" % str(trig.get("faction", ""))
	return "触发器"


static func trigger_lines(trig: Dictionary) -> Array:
	var out := []
	match str(trig.get("type", "")):
		"turn_start":
			out.append("时机：第 %d 回合 · %s" % [int(trig.get("turn", 1)), _phase_name(str(trig.get("phase", "player")))])
		"unit_death":
			out.append("当单位死亡：%s" % str(trig.get("unit", "任意")))
		"zone":
			out.append("当%s进入区域 %s" % [{"player": "我方", "enemy": "敌方", "any": "任意单位"}.get(str(trig.get("faction", "")), ""), str(trig.get("rect", "未框选"))])
	return out


static func node_lines(c: Dictionary) -> Array:
	var out := []
	match str(c.get("cmd", "")):
		"dialogue":
			var lines: Array = c.get("lines", [])
			for i in mini(lines.size(), 3):
				out.append("「%s」" % str(lines[i]))
			if lines.size() > 3:
				out.append("… 共 %d 句" % lines.size())
			if lines.is_empty():
				out.append("（未写台词）")
		"spawn":
			out.append("增援 %s ×%d 处" % [c.get("tpl", "?"), (c.get("cells", []) as Array).size()])
		"set_flag":
			out.append("旗标 %s = %s" % [c.get("flag", "?"), "真" if bool(c.get("value", true)) else "假"])
		"if":
			out.append("条件：旗标 %s 为%s" % [c.get("flag", "?"), "真" if bool(c.get("equals", true)) else "假"])
			out.append("是分支 %d 节点 / 否分支 %d 节点" % [(c.get("then", []) as Array).size(), (c.get("else", []) as Array).size()])
		"camera":
			out.append(("聚焦玩家" if str(c.get("mode", "")) == "focus_player" else "聚焦格子 %s" % str(c.get("cell", ""))) + " · %.1f 秒" % float(c.get("dur", 1.5)))
		"wait":
			out.append("等待 %.1f 秒" % float(c.get("time", 1.0)))
		"fx":
			out.append("演出特效：%s" % str(c.get("kind", "nova")))
		"music":
			out.append("BGM → %s" % c.get("track", "?"))
		"give_gold":
			out.append("给玩家金币 +%d" % int(c.get("amount", 0)))
		"give_item":
			out.append("给玩家 %s ×%d" % [c.get("tpl", "?"), c.get("count", 1)])
		"give_xp":
			out.append("给玩家经验 +%d" % int(c.get("amount", 0)))
		"heal_full":
			out.append("全员回满生命")
		"win":
			out.append("★ 游戏立即胜利")
		"lose":
			out.append("★ 游戏立即失败")
		_:
			out.append("(未知命令)")
	return out


static func _phase_name(ph: String) -> String:
	return {"player": "玩家回合", "enemy": "敌方回合", "any": "任意回合"}.get(ph, ph)


## AI 状态机节点布局（按行为类型；数值参数可在右侧调整）
static func ai_states(tpl: Dictionary) -> Array:
	var beh := str(tpl.get("behavior", "melee"))
	if beh == "ranged":
		return [
			{"id": "wander", "name": "游荡", "x": 40, "y": 40, "col": Color(0.4, 0.4, 0.5)},
			{"id": "keep", "name": "保持距离", "x": 250, "y": 40, "col": Color(0.3, 0.45, 0.6)},
			{"id": "windup", "name": "蓄力(%.1fs)" % float(tpl.get("windup", 0.5)), "x": 250, "y": 170, "col": Color(0.6, 0.4, 0.2)},
			{"id": "shoot", "name": "法弹(%d攻)" % int(tpl.get("atk", 1)), "x": 40, "y": 170, "col": Color(0.45, 0.3, 0.55)},
		]
	if beh == "boss":
		return [
			{"id": "wander", "name": "游荡", "x": 40, "y": 40, "col": Color(0.4, 0.4, 0.5)},
			{"id": "chase", "name": "追击", "x": 250, "y": 40, "col": Color(0.3, 0.45, 0.6)},
			{"id": "windup", "name": "蓄力咬(%.1fs)" % float(tpl.get("windup", 0.5)), "x": 460, "y": 40, "col": Color(0.6, 0.4, 0.2)},
			{"id": "ring", "name": "环形弹幕(每%.1fs)" % float(tpl.get("cool", 1.1) + 2.3), "x": 460, "y": 170, "col": Color(0.7, 0.3, 0.25)},
			{"id": "enrage", "name": "狂暴(<40%血)", "x": 250, "y": 170, "col": Color(0.75, 0.25, 0.2)},
		]
	return [
		{"id": "wander", "name": "游荡", "x": 40, "y": 40, "col": Color(0.4, 0.4, 0.5)},
		{"id": "chase", "name": "追击", "x": 250, "y": 40, "col": Color(0.3, 0.45, 0.6)},
		{"id": "windup", "name": "蓄力(%.1fs)" % float(tpl.get("windup", 0.5)), "x": 460, "y": 40, "col": Color(0.6, 0.4, 0.2)},
		{"id": "attack", "name": "攻击(%d攻)" % int(tpl.get("atk", 1)), "x": 250, "y": 170, "col": Color(0.55, 0.35, 0.3)},
	]


class EditorEventCanvas:
	extends Control
	var ed
	var _rects: Array = []   # 绘制期记录节点矩形（命中测试用）

	func _draw() -> void:
		_rects.clear()
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.1), true)
		var g := Color(1, 1, 1, 0.045)
		var yy := 12.0
		while yy < size.y:
			draw_line(Vector2(0, yy), Vector2(size.x, yy), g, 1.0)
			yy += 24.0
		var xx := 12.0
		while xx < size.x:
			draw_line(Vector2(xx, 0), Vector2(xx, size.y), g, 1.0)
			xx += 24.0
		if ed.editing_event < 0 or ed.editing_event >= ed.events.size():
			draw_string(ThemeDB.fallback_font, Vector2(20, 40), "← 新建或选择一个事件，流程会画在这里", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 0.5))
			return
		var ev: Dictionary = ed.events[ed.editing_event]
		# 触发器节点（链条头）
		var trig: Dictionary = ev.get("trigger", {})
		var t_lines := EditorAdvancedTabs.trigger_lines(trig)
		var t_rect := _push_node(Vector2(MARGIN, MARGIN), "触发器 · " + EditorAdvancedTabs.trigger_title(trig), Color(0.55, 0.45, 0.2), t_lines, [], true)
		_draw_node(t_rect, "触发器 · " + EditorAdvancedTabs.trigger_title(trig), Color(0.55, 0.45, 0.2), t_lines, ed._sel_path.is_empty())
		# 命令链
		var flat: Array = []
		EditorAdvancedTabs.flatten(ev.get("commands", []), 0, [], flat)
		var prev_rect := t_rect
		var link_label := ""
		var running_y: float = t_rect.end.y + 16.0
		var max_right: float = MARGIN + NODE_W
		for entry in flat:
			var c: Dictionary = entry["cmd"]
			var kind := str(c.get("cmd", ""))
			var meta: Array = EditorAdvancedTabs.NODE_TYPES.get(kind, [kind, Color(0.4, 0.4, 0.4)])
			var depth: int = entry["depth"]
			# 分支入口连线标签
			var path: Array = entry["path"]
			if link_label != "" and path.size() >= 2 and str(path[-2]) == link_label:
				pass
			elif path.size() >= 2:
				link_label = str(path[-2])
			else:
				link_label = ""
			var pos := Vector2(MARGIN + depth * INDENT, running_y)
			var r := _push_node(pos, meta[0], meta[1], EditorAdvancedTabs.node_lines(c), path, false)
			var from := Vector2(prev_rect.position.x + NODE_W / 2.0, prev_rect.end.y)
			var to := Vector2(pos.x + NODE_W / 2.0, pos.y)
			var line_col := Color(0.7, 0.95, 0.75, 0.85) if link_label == "是" else (Color(1.0, 0.7, 0.6, 0.8) if link_label == "否" else Color(0.7, 0.8, 1.0, 0.55))
			draw_line(from, to, line_col, 2.0)
			draw_circle(to, 3.0, Color(0.85, 0.92, 1.0, 0.9))
			if link_label == "是" or link_label == "否":
				draw_string(ThemeDB.fallback_font, from.lerp(to, 0.5) + Vector2(6, -4), link_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, line_col)
			_draw_node(r, meta[0], meta[1], EditorAdvancedTabs.node_lines(c), ed._sel_path == path)
			prev_rect = r
			running_y = r.end.y + 16.0
			max_right = maxf(max_right, pos.x + NODE_W)
		custom_minimum_size = Vector2(max_right + MARGIN, running_y + MARGIN)

	func _push_node(pos: Vector2, title: String, head: Color, lines: Array, path: Array, is_trigger: bool) -> Rect2:
		var h: float = NODE_HEAD + maxi(1, lines.size()) * NODE_ROW + 10.0
		var r := Rect2(pos, Vector2(NODE_W, h))
		_rects.append({"rect": r, "path": path.duplicate(), "is_trigger": is_trigger})
		return r

	func _draw_node(r: Rect2, title: String, head: Color, lines: Array, sel: bool) -> void:
		draw_rect(r, Color(0.10, 0.12, 0.20, 0.97), true)
		if sel:
			draw_rect(r, Color(1.0, 0.84, 0.38), false, 2.5)
		else:
			draw_rect(r, Color(1, 1, 1, 0.15), false, 1.0)
		draw_rect(Rect2(r.position, Vector2(r.size.x, NODE_HEAD)), Color(head.r, head.g, head.b, 0.9), true)
		draw_string(ThemeDB.fallback_font, r.position + Vector2(8, 18), title, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 16, 13, Color(0.08, 0.08, 0.12))
		var yy := r.position.y + NODE_HEAD + 17.0
		for i in maxi(1, lines.size()):
			var t: String = str(lines[i]) if i < lines.size() else ""
			draw_string(ThemeDB.fallback_font, Vector2(r.position.x + 8, yy), t, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 16, 12, Color(0.86, 0.89, 1.0))
			yy += NODE_ROW

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			for r in _rects:
				if (r["rect"] as Rect2).has_point(event.position):
					if bool(r["is_trigger"]):
						ed._sel_path = []
					else:
						ed._sel_path = (r["path"] as Array).duplicate()
					ed.refresh_event_canvas()
					accept_event()
					return
