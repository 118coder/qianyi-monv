extends VBoxContainer
## 事件编辑内核（RPG Maker 式）。字段定义与 `core/events/event_system.gd` 逐字一致
## ——「界面上配得出来、运行时却没反应的字段，比不做更糟」是本文件的红线 #1。
##
## 本类自己渲染**底部事件条**（事件头 + 命令按钮条 + 线性命令列表），
## 另外两块 UI 由宿主（workspace）安放：
##   · get_canvas()   —— 节点流画布（EventCanvas），放中央预览区；
##   · build_inspector(box) —— 事件/命令属性表单，填进工作区右栏。
##
## 数据结构（与运行时 event_system.gd 同源）：
##   事件 = { name, once, condition{flag,equals}, trigger{type,...}, commands[...] }
##   命令 = { cmd, ...字段 }；if 命令把分支挂在兄弟键 then / else 上
##   寻址 = 混合路径 [链索引, "then", 索引, "else", 索引, ...]
##
## 红线 #2：命令链的**列表视图**保证语义唯一、顺序明确，不可能连出非法图；
## 画布视图只是同一份数据的另一种看法，两处选择状态（sel_path）永远同步。

signal changed
signal preview_cell(cell: Vector2i)
## 事件集合变化（新建/复制/删除/改名）→ 工作区重建左树
signal structure_changed

const UI := preload("res://creator/core/ui_kit.gd")
const EventCanvas := preload("res://creator/core/event_canvas.gd")

const DEPTH_INDENT := 22.0
const MAX_DEPTH := 6           # 分支嵌套上限：再深的阅读成本就超过收益了

## 命令注册表。fields[].k 直接对应 JSON 里的键名。
const CMDS := {
	"dialogue": {
		"zh": "对话", "col": Color(0.25, 0.42, 0.75),
		"fields": [
			{"k": "speaker", "t": "tpl", "zh": "说话人", "def": "narrator",
				"tip": "选 narrator 表示旁白；也可以选角色模板"},
			{"k": "lines", "t": "lines", "zh": "台词", "def": [],
				"tip": "每行一句，玩家点击/空格逐句推进"},
		],
	},
	"spawn": {
		"zh": "增援", "col": Color(0.75, 0.45, 0.2),
		"fields": [
			{"k": "tpl", "t": "mob", "zh": "怪物", "def": "imp"},
			{"k": "cells", "t": "cells", "zh": "出生格", "def": [],
				"tip": "格式 [[x,y],...]，格坐标以地图左上角为原点"},
		],
	},
	"set_flag": {
		"zh": "设旗标", "col": Color(0.5, 0.35, 0.7),
		"fields": [
			{"k": "flag", "t": "str", "zh": "旗标名", "def": "flag1"},
			{"k": "value", "t": "bool", "zh": "设为", "def": true},
		],
	},
	"if": {
		"zh": "条件分支", "col": Color(0.2, 0.55, 0.55),
		"fields": [
			{"k": "flag", "t": "str", "zh": "判断旗标", "def": "flag1"},
			{"k": "equals", "t": "bool", "zh": "等于", "def": true},
		],
	},
	"camera": {
		"zh": "镜头调度", "col": Color(0.3, 0.5, 0.3),
		"fields": [
			{"k": "mode", "t": "enum", "zh": "目标", "def": "focus_cell",
				"opts": [["focus_cell", "指定格子"], ["focus_player", "当前角色"]]},
			{"k": "cell", "t": "cell", "zh": "格子", "def": [0, 0],
				"tip": "仅「指定格子」模式使用"},
			{"k": "dur", "t": "float", "zh": "持续秒", "def": 1.5},
		],
	},
	"wait": {
		"zh": "等待", "col": Color(0.4, 0.4, 0.45),
		"fields": [{"k": "time", "t": "float", "zh": "秒", "def": 1.0}],
	},
	"fx": {
		"zh": "演出特效", "col": Color(0.6, 0.4, 0.3),
		"fields": [
			{"k": "kind", "t": "enum", "zh": "类型", "def": "nova",
				"opts": [["nova", "光爆"], ["spark", "火花"], ["heal", "治愈"], ["shake", "震屏"]]},
			{"k": "at", "t": "enum", "zh": "位置", "def": "cell",
				"opts": [["cell", "指定格子"], ["player", "当前角色"]]},
			{"k": "cell", "t": "cell", "zh": "格子", "def": [0, 0]},
		],
	},
	"music": {
		"zh": "切换音乐", "col": Color(0.45, 0.3, 0.5),
		"fields": [
			{"k": "track", "t": "enum", "zh": "曲目", "def": "dungeon",
				"opts": [["title", "标题"], ["dungeon", "地牢"], ["boss", "首领"], ["town", "城镇"]]},
		],
	},
	"give_gold": {
		"zh": "给金币", "col": Color(0.6, 0.55, 0.25),
		"fields": [{"k": "amount", "t": "int", "zh": "数量", "def": 100}],
	},
	"give_item": {
		"zh": "给物品", "col": Color(0.5, 0.5, 0.3),
		"fields": [
			{"k": "tpl", "t": "item", "zh": "物品", "def": "potion"},
			{"k": "count", "t": "int", "zh": "数量", "def": 1},
		],
	},
	"heal_full": {"zh": "全队回满", "col": Color(0.3, 0.6, 0.4), "fields": []},
	"win": {"zh": "★ 胜利", "col": Color(0.2, 0.55, 0.3), "fields": []},
	"lose": {"zh": "★ 失败", "col": Color(0.6, 0.25, 0.2), "fields": []},
}

## 触发器注册表。字段与 event_system._matches() 对齐。
const TRIGGERS := {
	"turn_start": {
		"zh": "楼层开始",
		"fields": [
			{"k": "turn", "t": "int", "zh": "第几层", "def": 1},
			{"k": "phase", "t": "enum", "zh": "阶段", "def": "any",
				"opts": [["any", "任意"], ["player", "玩家"], ["enemy", "敌方"]]},
		],
	},
	"unit_death": {
		"zh": "单位死亡",
		"fields": [
			{"k": "unit", "t": "str", "zh": "单位", "def": "",
				"tip": "留空 = 任何单位；也可填单位 uid 或模板 id"},
		],
	},
	"zone": {
		"zh": "进入区域",
		"fields": [
			{"k": "faction", "t": "enum", "zh": "阵营", "def": "any",
				"opts": [["any", "任意"], ["player", "玩家"], ["enemy", "敌方"]]},
			{"k": "rect", "t": "rect", "zh": "区域", "def": [0, 0, 3, 3],
				"tip": "[x, y, 宽, 高]，单位是格"},
		],
	},
}

var events: Array = []
var chars: Dictionary = {}
var enemies: Dictionary = {}
var items: Dictionary = {}

var cur_event := -1
var sel_path: Array = []

var _list_box: VBoxContainer
var _head_lbl: Label
var _canvas = null
var _insp_bound: VBoxContainer = null    # 由 build_inspector 记住，结构操作后能原地重建


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_build_strip()
	if events.size() > 0 and cur_event < 0:
		cur_event = 0
	refresh_all()


# ———————— 对外 ————————

func setup(evs: Array, balance: Dictionary) -> void:
	events = evs
	chars = balance.get("chars", {})
	enemies = balance.get("enemies", {})
	items = balance.get("items", {})
	cur_event = 0 if events.size() > 0 else -1
	sel_path = []
	if is_inside_tree():
		refresh_all()


## 中央画布（懒创建：workspace 路由到事件页时才需要）。
## 不叫 get_canvas——那是 CanvasItem 的原生方法，重名会被引擎当重载报错。
func flow_canvas() -> Control:
	if _canvas == null:
		_canvas = EventCanvas.new()
		_canvas.title_of = func(c): return str(CMDS.get(str(c.get("cmd", "")), {}).get("zh", str(c.get("cmd", "?"))))
		_canvas.lines_of = _node_lines
		_canvas.color_of = func(c): return CMDS.get(str(c.get("cmd", "")), {}).get("col", Color(0.4, 0.4, 0.4))
		_canvas.trigger_of = func(t): return {"title": _trigger_title(t), "lines": _trigger_lines(t)}
		_canvas.node_selected.connect(func(p): _pick_cmd(p))
		_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_canvas.set_event(_cur_ev())
		_canvas.sel_path = sel_path
	return _canvas


## 左树事件节点的显示文本
func event_label(i: int) -> String:
	if i < 0 or i >= events.size():
		return "事件"
	var ev: Dictionary = events[i]
	return "%02d · %s" % [i + 1, str(ev.get("name", "未命名"))]


func select_event(i: int) -> void:
	cur_event = clampi(i, -1, events.size() - 1)
	sel_path = []
	refresh_all()


func add_event() -> void:
	events.append({
		"name": "新事件 %d" % (events.size() + 1),
		"once": true,
		"condition": {},
		"trigger": {"type": "turn_start", "turn": 1, "phase": "any"},
		"commands": [],
	})
	cur_event = events.size() - 1
	sel_path = []
	_mark()
	structure_changed.emit()
	refresh_all()


func dup_event() -> void:
	if cur_event < 0 or cur_event >= events.size():
		return
	var copy = events[cur_event].duplicate(true)
	copy["name"] = str(copy.get("name", "事件")) + " 副本"
	events.insert(cur_event + 1, copy)
	cur_event += 1
	sel_path = []
	_mark()
	structure_changed.emit()
	refresh_all()


func del_event() -> void:
	if cur_event < 0 or cur_event >= events.size():
		return
	events.remove_at(cur_event)
	cur_event = clampi(cur_event, 0, events.size() - 1)
	sel_path = []
	_mark()
	structure_changed.emit()
	refresh_all()


## 追加命令到当前链尾（sel_path 指向分支内时追加进那条分支）
func add_cmd(t: String) -> void:
	if cur_event < 0 or cur_event >= events.size():
		_status("先新建一个事件")
		return
	var chain: Array = events[cur_event].get("commands", [])
	if sel_path.size() > 0:
		chain = _chain_at(sel_path.slice(0, sel_path.size() - 1))
	chain.append(_make_cmd(t))
	sel_path = []
	_mark()
	refresh_all()


## 在选中命令之后插入（列表视图没有的能力，画布右栏提供）
func add_cmd_after(t: String) -> void:
	if cur_event < 0 or cur_event >= events.size():
		return
	var node := _make_cmd(t)
	if sel_path.is_empty():
		var cmds: Array = events[cur_event].get("commands", [])
		cmds.append(node)
		sel_path = [cmds.size() - 1]
	else:
		var parent_path := sel_path.duplicate()
		parent_path.resize(parent_path.size() - 1)
		var chain := _chain_at(parent_path)
		var idx := int(sel_path[-1])
		var at := mini(idx + 1, chain.size())
		chain.insert(at, node)
		var np := parent_path.duplicate()
		np.append(at)
		sel_path = np
	_mark()
	refresh_all()


## 往选中 if 命令的分支追加；选中的不是 if 时返回 false
func add_into_branch(t: String, branch: String) -> bool:
	if sel_path.is_empty() or cur_event < 0:
		return false
	var c := _node_at(sel_path)
	if str(c.get("cmd", "")) != "if":
		return false
	if not (c.get(branch) is Array):
		c[branch] = []
	(c[branch] as Array).append(_make_cmd(t))
	sel_path = sel_path + [branch, (c[branch] as Array).size() - 1]
	_mark()
	refresh_all()
	return true


func del_cmd() -> void:
	if sel_path.is_empty() or cur_event < 0:
		return
	var chain := _chain_at(sel_path.slice(0, sel_path.size() - 1))
	var idx := int(sel_path[-1])
	if idx >= 0 and idx < chain.size():
		chain.remove_at(idx)
	sel_path = []
	_mark()
	refresh_all()


func move_cmd(dir: int) -> void:
	if sel_path.is_empty() or cur_event < 0:
		return
	var chain := _chain_at(sel_path.slice(0, sel_path.size() - 1))
	var idx := int(sel_path[-1])
	var j := idx + dir
	if j < 0 or j >= chain.size():
		return
	var tmp = chain[idx]
	chain[idx] = chain[j]
	chain[j] = tmp
	sel_path[-1] = j
	_mark()
	refresh_all()


func refresh_all() -> void:
	_build_head()
	_build_list()
	if _canvas != null:
		_canvas.set_event(_cur_ev())
		_canvas.sel_path = sel_path
		_canvas.queue_redraw()
	_rebuild_inspector()


## 右栏属性表单：workspace 路由到事件页时调用
func build_inspector(box: VBoxContainer) -> void:
	_insp_bound = box
	_rebuild_inspector()


func _rebuild_inspector() -> void:
	if _insp_bound == null or not is_instance_valid(_insp_bound) or not _insp_bound.is_inside_tree():
		return
	for c in _insp_bound.get_children():
		_insp_bound.remove_child(c)
		c.queue_free()
	if cur_event < 0 or cur_event >= events.size():
		UI.hint(_insp_bound, "左侧没有选中事件。到「事件」里新建一个。")
		return
	if sel_path.is_empty():
		_build_event_props(_insp_bound)
	else:
		_build_cmd_props(_insp_bound)


# ———————— 底部事件条 ————————

func _build_strip() -> void:
	var head := UI.hbox(self, 8)
	_head_lbl = UI.label(head, "未选择事件", 13, UI.DIM)
	_head_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var bar := UI.hbox(self, 4)
	bar.add_theme_constant_override("separation", 4)
	UI.button(bar, "＋ 新建", add_event, 74).tooltip_text = "新建一个事件（触发条件 + 命令链）"
	UI.button(bar, "复制", dup_event, 56)
	UI.button(bar, "删除", del_event, 56)
	UI.vsep(bar)
	for t in CMDS.keys():
		var b := UI.button(bar, str(CMDS[t]["zh"]), add_cmd.bind(str(t)))
		b.add_theme_font_size_override("font_size", 12)
		b.custom_minimum_size.y = 26

	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 150)
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	self.add_child(sc)
	_list_box = UI.vbox(sc, 3)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _cur_ev() -> Variant:
	if cur_event < 0 or cur_event >= events.size():
		return null
	return events[cur_event]


func _build_head() -> void:
	if _head_lbl == null:
		return
	var ev: Variant = _cur_ev()
	if ev == null:
		_head_lbl.text = "未选择事件——在左树「事件」里选，或点「＋ 新建」"
		_head_lbl.add_theme_color_override("font_color", UI.DIM)
		return
	var e: Dictionary = ev
	var tname := _trigger_title(e.get("trigger", {}))
	var tags := PackedStringArray()
	if bool(e.get("once", true)):
		tags.append("只一次")
	var cond: Dictionary = e.get("condition", {}) if e.get("condition") is Dictionary else {}
	if str(cond.get("flag", "")) != "":
		tags.append("前提:%s" % str(cond.get("flag", "")))
	_head_lbl.text = "◆ %s　·　%s　%s" % [
		str(e.get("name", "未命名")), tname,
		("　" + "　".join(tags)) if tags.size() > 0 else ""]
	_head_lbl.add_theme_color_override("font_color", UI.TEXT)


func _build_list() -> void:
	for c in _list_box.get_children():
		c.queue_free()
	var ev: Variant = _cur_ev()
	if ev == null:
		UI.hint(_list_box, "执行内容：事件被触发后从上到下依次执行的命令。")
		return
	var cmds: Array = (ev as Dictionary).get("commands", [])
	if cmds.is_empty():
		UI.hint(_list_box, "还没有命令。点上方命令按钮添加第一条；条件分支会在列表里缩进。")
		return
	_rows(_list_box, cmds, [], 0)


## 递归铺命令：分支用缩进表达，层次一眼可见（列表视图；画布视图见 EventCanvas）
func _rows(box: Node, cmds: Array, base: Array, depth: int) -> void:
	for i in cmds.size():
		var c: Dictionary = cmds[i]
		var path: Array = base.duplicate()
		path.append(i)
		_row(box, c, path, depth)
		if str(c.get("cmd", "")) == "if" and depth < MAX_DEPTH:
			var then_chain: Array = c.get("then", [])
			if then_chain.size() > 0:
				var h := UI.hbox(box, 0)
				var pad := Control.new()
				pad.custom_minimum_size.x = DEPTH_INDENT * float(depth + 1)
				h.add_child(pad)
				UI.label(h, "↳ 满足时", 11, UI.OK)
				_rows(box, then_chain, path + ["then"], depth + 1)
			var else_chain: Array = c.get("else", [])
			if else_chain.size() > 0:
				var h2 := UI.hbox(box, 0)
				var pad2 := Control.new()
				pad2.custom_minimum_size.x = DEPTH_INDENT * float(depth + 1)
				h2.add_child(pad2)
				UI.label(h2, "↳ 否则", 11, UI.ERR)
				_rows(box, else_chain, path + ["else"], depth + 1)


func _row(box: Node, c: Dictionary, path: Array, depth: int) -> void:
	var info: Dictionary = CMDS.get(str(c.get("cmd", "")), {})
	var col: Color = info.get("col", Color(0.3, 0.3, 0.35))
	var wrap := UI.hbox(box, 0)
	var pad := Control.new()
	pad.custom_minimum_size.x = DEPTH_INDENT * float(depth)
	wrap.add_child(pad)

	var b := Button.new()
	b.text = "◆ %s　%s" % [str(info.get("zh", c.get("cmd", "?"))), _summary(c)]
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size.y = 28
	b.add_theme_font_size_override("font_size", 13)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.r * 0.30, col.g * 0.30, col.b * 0.34)
	sb.border_width_left = 4
	sb.border_color = col
	sb.content_margin_left = 8
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	if path == sel_path:
		sb.bg_color = Color(col.r * 0.55, col.g * 0.55, col.b * 0.60)
		sb.border_width_bottom = 1
	b.add_theme_stylebox_override("normal", sb)
	var sbh := sb.duplicate() as StyleBoxFlat
	sbh.bg_color = sb.bg_color.lightened(0.12)
	b.add_theme_stylebox_override("hover", sbh)
	b.pressed.connect(_pick_cmd.bind(path))
	wrap.add_child(b)


## 一行摘要：只显示最关键的参数，细节在右侧面板改
func _summary(c: Dictionary) -> String:
	match str(c.get("cmd", "")):
		"dialogue":
			var n: int = (c.get("lines", []) as Array).size()
			return "· %s　%d 句" % [str(c.get("speaker", "narrator")), n]
		"spawn":
			return "· %s ×%d" % [str(c.get("tpl", "")), (c.get("cells", []) as Array).size()]
		"set_flag":
			return "· %s = %s" % [str(c.get("flag", "")), str(c.get("value", true))]
		"if":
			return "· 若 %s == %s" % [str(c.get("flag", "")), str(c.get("equals", true))]
		"camera":
			if str(c.get("mode", "")) == "focus_player":
				return "· 聚焦角色 %.1fs" % float(c.get("dur", 1.5))
			var cc: Array = c.get("cell", [0, 0])
			return "· 格子(%d,%d) %.1fs" % [int(cc[0]), int(cc[1]), float(c.get("dur", 1.5))]
		"wait":
			return "· %.2f 秒" % float(c.get("time", 1.0))
		"fx":
			return "· %s @%s" % [str(c.get("kind", "")), str(c.get("at", "cell"))]
		"music":
			return "· " + str(c.get("track", ""))
		"give_gold":
			return "· %d G" % int(c.get("amount", 0))
		"give_item":
			return "· %s ×%d" % [str(c.get("tpl", "")), int(c.get("count", 1))]
	return ""


# ———————— 寻址与数据操作 ————————

func _make_cmd(t: String) -> Dictionary:
	var node := {"cmd": t}
	for f in CMDS.get(t, {}).get("fields", []):
		node[str(f["k"])] = _default_of(f)
	if t == "if":
		node["then"] = []
		node["else"] = []
	return node


func _default_of(f: Dictionary) -> Variant:
	var d = f.get("def", null)
	if d == null:
		match str(f["t"]):
			"int": return 0
			"float": return 0.0
			"bool": return false
			"lines", "cells": return []
			"cell", "vec2": return [0, 0]
			"rect": return [0, 0, 3, 3]
			_: return ""
	if d is Array:
		return (d as Array).duplicate(true)
	return d


func _chain_at(path: Array) -> Array:
	var cur: Array = events[cur_event].get("commands", [])
	var i := 0
	while i < path.size():
		var idx: int = int(path[i])
		if idx < 0 or idx >= cur.size():
			return cur
		var node: Dictionary = cur[idx]
		i += 1
		if i < path.size() and path[i] is String:
			var key := str(path[i])
			if not (node.get(key) is Array):
				node[key] = []
			cur = node[key]
			i += 1
	return cur


func _node_at(path: Array) -> Dictionary:
	var chain := _chain_at(path)
	if path.is_empty():
		return {}
	var idx := int(path[-1])
	return chain[idx] if idx >= 0 and idx < chain.size() else {}


func _pick_cmd(path: Array) -> void:
	sel_path = path
	_build_list()
	if _canvas != null:
		_canvas.sel_path = sel_path
		_canvas.queue_redraw()
	_rebuild_inspector()


func _status(msg: String) -> void:
	_head_lbl.text = msg
	_head_lbl.add_theme_color_override("font_color", UI.WARN)


# ———————— 右栏：事件属性 ————————

## 选中事件本身（未选命令）时：名称 / 触发条件 / 只触发一次 / 旗标前提
func _build_event_props(box: VBoxContainer) -> void:
	var ev: Dictionary = events[cur_event]

	var base := UI.inspector_section(box, "事件", UI.MOD_EVENTS)
	var nm := LineEdit.new()
	nm.text = str(ev.get("name", ""))
	nm.text_changed.connect(func(t):
		ev["name"] = t
		_mark()
		structure_changed.emit()
		_build_head()
	)
	base.add_child(nm)
	var once := CheckBox.new()
	once.text = "只触发一次"
	once.button_pressed = bool(ev.get("once", true))
	once.toggled.connect(func(v):
		ev["once"] = v
		_mark()
		_build_head()
	)
	base.add_child(once)

	var trig_sec := UI.inspector_section(box, "触发条件", UI.MOD_EVENTS)
	var trig: Dictionary = ev.get("trigger", {})
	var opt := OptionButton.new()
	var types := TRIGGERS.keys()
	var cur_type := str(trig.get("type", "turn_start"))
	var sel_i := 0
	for i in types.size():
		opt.add_item(str(TRIGGERS[types[i]]["zh"]), i)
		if str(types[i]) == cur_type:
			sel_i = i
	opt.selected = sel_i
	opt.item_selected.connect(func(i):
		var newt := str(types[i])
		ev["trigger"] = {"type": newt}
		for f in TRIGGERS[newt]["fields"]:
			ev["trigger"][str(f["k"])] = _default_of(f)
		_mark()
		refresh_all()
	)
	trig_sec.add_child(opt)
	var tf: Array = TRIGGERS.get(cur_type, {}).get("fields", [])
	for f in tf:
		_field(trig_sec, trig, f, func():
			_mark()
			_build_head()
			_build_list()
			if _canvas != null:
				_canvas.queue_redraw()
		)

	var cond_sec := UI.inspector_section(box, "触发前提（旗标，可留空）", UI.MOD_EVENTS, false)
	var cond: Dictionary = ev.get("condition", {})
	if not (cond is Dictionary):
		cond = {}
		ev["condition"] = cond
	var fl := LineEdit.new()
	fl.placeholder_text = "例如 boss_defeated"
	fl.text = str(cond.get("flag", ""))
	fl.text_changed.connect(func(t):
		cond["flag"] = t
		_mark()
		_build_head()
	)
	cond_sec.add_child(fl)
	var eq := CheckBox.new()
	eq.text = "旗标为真时才触发"
	eq.button_pressed = bool(cond.get("equals", true))
	eq.toggled.connect(func(v):
		cond["equals"] = v
		_mark()
	)
	cond_sec.add_child(eq)


# ———————— 右栏：命令属性 ————————

## 选中某条命令时：按注册表生成字段表单 + 移动/删除/插入
func _build_cmd_props(box: VBoxContainer) -> void:
	var c := _node_at(sel_path)
	if c.is_empty():
		UI.hint(box, "命令已不存在，重新选一条。")
		return
	var t := str(c.get("cmd", ""))
	var info: Dictionary = CMDS.get(t, {})

	var sec := UI.inspector_section(box, "命令 · " + str(info.get("zh", t)), info.get("col", UI.ACCENT))
	for f in info.get("fields", []):
		_field(sec, c, f, func():
			_mark()
			_build_head()
			_build_list()
			if _canvas != null:
				_canvas.queue_redraw()
		)

	var ops := UI.inspector_section(box, "调整", UI.DIM)
	var acts := UI.hbox(ops, 6)
	UI.button(acts, "↑ 上移", move_cmd.bind(-1), 74)
	UI.button(acts, "↓ 下移", move_cmd.bind(1), 74)
	UI.button(acts, "删除", del_cmd, 62)
	UI.hint(ops, "「在此后添加」会把新命令插到当前命令后面（主链或分支内都一样）。")
	var ins := UI.hbox(ops, 4)
	ins.add_theme_constant_override("separation", 4)
	for t2 in CMDS.keys():
		var b := UI.button(ins, str(CMDS[t2]["zh"]), add_cmd_after.bind(str(t2)))
		b.add_theme_font_size_override("font_size", 12)
		b.custom_minimum_size.y = 26

	if t == "if":
		UI.hsep(ops)
		UI.hint(ops, "把命令加进分支：")
		var hb := UI.hbox(ops, 4)
		var tb := UI.button(hb, "＋ 满足时", func():
			if not add_into_branch("dialogue", "then"):
				_status("先选中一个「条件分支」命令")
		)
		tb.add_theme_font_size_override("font_size", 12)
		var eb := UI.button(hb, "＋ 否则", func():
			if not add_into_branch("dialogue", "else"):
				_status("先选中一个「条件分支」命令")
		)
		eb.add_theme_font_size_override("font_size", 12)


# ———————— 画布用的节点文案 ————————

## 触发器节点标题（ARPG 里 turn 就是楼层号，见 HANDOFF §2）
func _trigger_title(trig: Dictionary) -> String:
	match str(trig.get("type", "")):
		"turn_start":
			return "楼层开始 · 第%d层" % int(trig.get("turn", 1))
		"unit_death":
			var u := str(trig.get("unit", ""))
			return "单位死亡 · %s" % ("任意" if u == "" else u)
		"zone":
			return "进入区域 · %s" % str(trig.get("faction", ""))
	return "触发器"


func _trigger_lines(trig: Dictionary) -> Array:
	var out := []
	match str(trig.get("type", "")):
		"turn_start":
			var ph := str(trig.get("phase", "any"))
			out.append("时机：%s" % {"player": "玩家阶段", "enemy": "敌方阶段", "any": "任意阶段"}.get(ph, ph))
		"unit_death":
			var u := str(trig.get("unit", ""))
			out.append("当%s死亡" % ("任意单位" if u == "" else u))
		"zone":
			var r: Array = trig.get("rect", [0, 0, 0, 0]) if trig.get("rect") is Array else [0, 0, 0, 0]
			out.append("当%s进入区域 (%d,%d) %d×%d" % [
				{"player": "我方", "enemy": "敌方", "any": "任意单位"}.get(str(trig.get("faction", "")), ""),
				int(r[0]), int(r[1]), int(r[2]), int(r[3])])
	return out


## 命令节点的正文行（比列表摘要信息量大；移植自 editor/advanced_tabs.gd node_lines）。
## 台词过长会被节点盒硬裁，统一截断加省略号。
func _clip(s: String, n: int) -> String:
	if s.length() <= n:
		return s
	return s.substr(0, n) + "…"


func _node_lines(c: Dictionary) -> Array:
	var out := []
	match str(c.get("cmd", "")):
		"dialogue":
			var lines: Array = c.get("lines", [])
			for i in mini(lines.size(), 3):
				out.append("「%s」" % _clip(str(lines[i]), 22))
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
		"heal_full":
			out.append("全员回满生命")
		"win":
			out.append("★ 游戏立即胜利")
		"lose":
			out.append("★ 游戏立即失败")
		_:
			out.append("(未知命令)")
	return out


# ———————— 字段控件（注册表驱动，与旧版逐字对齐） ————————

## 按字段类型生成控件（含下拉框的选项来源）
func _field(parent: Node, target: Dictionary, f: Dictionary, on_change: Callable) -> void:
	var k := str(f["k"])
	var t := str(f["t"])
	var zh := str(f.get("zh", k))
	if not target.has(k):
		target[k] = _default_of(f)

	if t != "bool":
		var l := UI.label(parent, zh, 13, UI.DIM)
		if f.has("tip"):
			l.tooltip_text = str(f["tip"])

	match t:
		"bool":
			var cb := CheckBox.new()
			cb.text = zh
			cb.button_pressed = bool(target[k])
			cb.toggled.connect(func(v):
				target[k] = v
				on_change.call()
			)
			parent.add_child(cb)
		"int":
			var sp := SpinBox.new()
			sp.min_value = -99999
			sp.max_value = 99999
			sp.value = int(target[k])
			sp.value_changed.connect(func(v):
				target[k] = int(v)
				on_change.call()
			)
			parent.add_child(sp)
		"float":
			var sp2 := SpinBox.new()
			sp2.min_value = 0.0
			sp2.max_value = 999.0
			sp2.step = 0.1
			sp2.value = float(target[k])
			sp2.value_changed.connect(func(v):
				target[k] = float(v)
				on_change.call()
			)
			parent.add_child(sp2)
		"str":
			var le := LineEdit.new()
			le.text = str(target[k])
			le.text_changed.connect(func(s):
				target[k] = s
				on_change.call()
			)
			parent.add_child(le)
		"enum":
			var opt := OptionButton.new()
			var opts: Array = f.get("opts", [])
			for i in opts.size():
				opt.add_item(str(opts[i][1]), i)
				if str(opts[i][0]) == str(target[k]):
					opt.selected = i
			opt.item_selected.connect(func(i):
				target[k] = str(opts[i][0])
				on_change.call()
			)
			parent.add_child(opt)
		"tpl", "mob", "item":
			var opt2 := OptionButton.new()
			var src: Dictionary = chars
			if t == "mob":
				src = enemies
			elif t == "item":
				src = items
			var keys := src.keys()
			var idx := 0
			if t == "tpl":
				opt2.add_item("旁白（无头像）", 0)
				opt2.set_item_metadata(0, "narrator")
			for i in keys.size():
				var kk := str(keys[i])
				var disp := str(src[keys[i]].get("name", kk)) if src[keys[i]] is Dictionary else kk
				opt2.add_item("%s（%s）" % [disp, kk], opt2.item_count)
				opt2.set_item_metadata(opt2.item_count - 1, kk)
				if kk == str(target[k]):
					idx = opt2.item_count - 1
			opt2.selected = idx
			opt2.item_selected.connect(func(i):
				target[k] = str(opt2.get_item_metadata(i))
				on_change.call()
			)
			parent.add_child(opt2)
		"lines", "cells":
			_lines_editor(parent, target, k, on_change)
		"cell":
			_cell_editor(parent, target, k, on_change)
		"rect":
			_rect_editor(parent, target, k, on_change)


## 台词 / 坐标列表：多行文本，一行一项。比一堆「＋」按钮快得多，也更像 RM 的文本框
func _lines_editor(parent: Node, target: Dictionary, k: String, on_change: Callable) -> void:
	var te := TextEdit.new()
	te.custom_minimum_size = Vector2(0, 90)
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.add_theme_font_size_override("font_size", 13)
	var arr: Array = target[k] if target[k] is Array else []
	if k == "lines":
		var buf := PackedStringArray()
		for s in arr:
			buf.append(str(s))
		te.text = "\n".join(buf)
	else:
		var buf2 := PackedStringArray()
		for it in arr:
			if it is Array and (it as Array).size() >= 2:
				buf2.append("%d,%d" % [int(it[0]), int(it[1])])
		te.text = "\n".join(buf2)
	te.text_changed.connect(func():
		var out: Array = []
		for line in te.text.split("\n"):
			var s := str(line).strip_edges()
			if s == "":
				continue
			if k == "lines":
				out.append(s)
			else:
				var p := s.split(",")
				if p.size() >= 2:
					out.append([int(p[0].strip_edges()), int(p[1].strip_edges())])
		target[k] = out
		on_change.call()
	)
	parent.add_child(te)
	UI.hint(parent, "每行一项" + ("，一句一行" if k == "lines" else "，格式 x,y"))


func _cell_editor(parent: Node, target: Dictionary, k: String, on_change: Callable) -> void:
	var arr: Array = target[k] if target[k] is Array and (target[k] as Array).size() >= 2 else [0, 0]
	var h := UI.hbox(parent, 6)
	UI.label(h, "x", 12, UI.DIM)
	var sx := SpinBox.new()
	sx.min_value = 0
	sx.max_value = 999
	sx.value = int(arr[0])
	sx.value_changed.connect(func(v):
		target[k] = [int(v), int(arr[1])]
		on_change.call()
	)
	h.add_child(sx)
	UI.label(h, "y", 12, UI.DIM)
	var sy := SpinBox.new()
	sy.min_value = 0
	sy.max_value = 999
	sy.value = int(arr[1])
	sy.value_changed.connect(func(v):
		target[k] = [int(arr[0]), int(v)]
		on_change.call()
	)
	h.add_child(sy)
	UI.button(h, "预览", func(): preview_cell.emit(Vector2i(int(arr[0]), int(arr[1]))), 56)


func _rect_editor(parent: Node, target: Dictionary, k: String, on_change: Callable) -> void:
	var arr: Array = target[k] if target[k] is Array and (target[k] as Array).size() >= 4 else [0, 0, 3, 3]
	var h := UI.hbox(parent, 4)
	var names := ["x", "y", "宽", "高"]
	for i in 4:
		UI.label(h, names[i], 12, UI.DIM)
		var sp := SpinBox.new()
		sp.min_value = 0
		sp.max_value = 999
		sp.value = int(arr[i])
		sp.custom_minimum_size.x = 62
		sp.value_changed.connect(func(v):
			var out: Array = [int(arr[0]), int(arr[1]), int(arr[2]), int(arr[3])]
			out[i] = int(v)
			target[k] = out
			on_change.call()
		)
		h.add_child(sp)


func _mark() -> void:
	changed.emit()
