extends HBoxContainer
## 可视化事件编辑器（RPG Maker 式：左侧事件列表 / 中间命令链 / 右侧属性面板）。
##
## 三条设计红线：
##  1. **字段定义必须与 `core/events/event_system.gd` 的真实实现逐字一致**。
##     比如 `camera` 用的是 mode/cell/dur，`wait` 用 time，`music` 用 track，
##     `give_item` 用 tpl/count。界面上配得出来、运行时却没反应的字段，比不做更糟。
##  2. **命令链是缩进列表而不是自由画布**。RPG Maker 的事件本来就是"触发器 + 命令序列"，
##     用列表能保证语义唯一、顺序明确、不可能连出非法图；条件分支靠缩进表达，
##     和用户在 RM 里形成的直觉一致。
##  3. 只改内存里的字典，脏标记由外层控制；不在这里碰文件。

signal changed
## 请求预览某个命令（目前用于「镜头调度」定位到格子）
signal preview_cell(cell: Vector2i)

const UI := preload("res://creator/core/ui_kit.gd")

const DEPTH_INDENT := 22.0
const MAX_DEPTH := 6           # 分支嵌套上限：再深人的阅读成本就超过收益了

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
var _dirty := false

var _list_box: VBoxContainer
var _chain_box: VBoxContainer
var _insp_box: VBoxContainer


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	_build_layout()
	# setup() 可能在本节点 add_child 之前就被调用（宿主要先构造再挂载），
	# 那时 _list_box 等还是 null，刷新会被跳过；布局建好后在这里补一次。
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


func refresh_all() -> void:
	_build_event_list()
	_build_chain()
	_build_inspector()


# ———————— 布局 ————————

func _build_layout() -> void:
	# 左：事件列表
	var left := UI.vbox(self, 6)
	left.custom_minimum_size.x = 218
	UI.section(left, "事件列表")
	UI.hint(left, "一个事件 = 一个触发条件 + 一串命令。选中后在中栏编辑。")
	var sc := ScrollContainer.new()
	sc.custom_minimum_size.y = 0
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(sc)
	_list_box = UI.vbox(sc, 3)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var acts := UI.hbox(left, 6)
	UI.button(acts, "＋ 新建", _new_event, 100)
	UI.button(acts, "复制", _dup_event, 56)
	UI.button(acts, "删除", _del_event, 56)

	# 中：命令链
	var mid := UI.vbox(self, 6)
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UI.section(mid, "命令链（从上到下依次执行）")
	var add_bar := UI.hbox(mid, 4)
	add_bar.add_theme_constant_override("separation", 4)
	for t in CMDS.keys():
		var b := UI.button(add_bar, str(CMDS[t]["zh"]), _add_cmd.bind(str(t)))
		b.add_theme_font_size_override("font_size", 12)
		b.custom_minimum_size.y = 26
	var chain_sc := ScrollContainer.new()
	chain_sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.add_child(chain_sc)
	_chain_box = UI.vbox(chain_sc, 3)
	_chain_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# 右：属性面板
	var right := UI.vbox(self, 6)
	right.custom_minimum_size.x = 330
	UI.section(right, "属性")
	var insp_sc := ScrollContainer.new()
	insp_sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	insp_sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(insp_sc)
	_insp_box = UI.vbox(insp_sc, 8)
	_insp_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL


# ———————— 事件列表 ————————

func _build_event_list() -> void:
	for c in _list_box.get_children():
		c.queue_free()
	if events.is_empty():
		UI.hint(_list_box, "还没有事件。点「＋ 新建」开始。")
		return
	for i in events.size():
		var ev: Dictionary = events[i]
		var b := Button.new()
		var tname := str(TRIGGERS.get(str(ev.get("trigger", {}).get("type", "")), {}).get("zh", "未知触发"))
		b.text = "%d. %s\n　%s" % [i + 1, str(ev.get("name", "未命名")), tname]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 12)
		b.custom_minimum_size.y = 40
		if i == cur_event:
			b.add_theme_stylebox_override("normal", _sel_style())
		b.pressed.connect(_pick_event.bind(i))
		_list_box.add_child(b)


func _sel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.22, 0.33, 0.47)
	s.border_width_left = 3
	s.border_color = UI.ACCENT
	s.content_margin_left = 8
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	return s


func _pick_event(i: int) -> void:
	cur_event = i
	sel_path = []
	refresh_all()


func _new_event() -> void:
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
	refresh_all()


func _dup_event() -> void:
	if cur_event < 0 or cur_event >= events.size():
		return
	var copy = events[cur_event].duplicate(true)
	copy["name"] = str(copy.get("name", "事件")) + " 副本"
	events.insert(cur_event + 1, copy)
	cur_event += 1
	_mark()
	refresh_all()


func _del_event() -> void:
	if cur_event < 0 or cur_event >= events.size():
		return
	events.remove_at(cur_event)
	cur_event = clampi(cur_event, 0, events.size() - 1)
	sel_path = []
	_mark()
	refresh_all()


# ———————— 命令链 ————————

func _build_chain() -> void:
	for c in _chain_box.get_children():
		c.queue_free()
	if cur_event < 0 or cur_event >= events.size():
		UI.hint(_chain_box, "先选中或新建一个事件。")
		return
	var cmds: Array = events[cur_event].get("commands", [])
	if cmds.is_empty():
		UI.hint(_chain_box, "这个事件还没有命令。用上方按钮添加第一条。")
		return
	_rows(_chain_box, cmds, [], 0)


## 递归铺命令：分支用缩进表达，层次一眼可见
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
				var l := UI.label(h, "满足时 ↓", 11, UI.OK)
				_rows(box, then_chain, path + ["then"], depth + 1)
			var else_chain: Array = c.get("else", [])
			if else_chain.size() > 0:
				var h2 := UI.hbox(box, 0)
				var pad2 := Control.new()
				pad2.custom_minimum_size.x = DEPTH_INDENT * float(depth + 1)
				h2.add_child(pad2)
				UI.label(h2, "否则 ↓", 11, UI.ERR)
				_rows(box, else_chain, path + ["else"], depth + 1)


func _row(box: Node, c: Dictionary, path: Array, depth: int) -> void:
	var info: Dictionary = CMDS.get(str(c.get("cmd", "")), {})
	var col: Color = info.get("col", Color(0.3, 0.3, 0.35))
	var wrap := UI.hbox(box, 0)
	var pad := Control.new()
	pad.custom_minimum_size.x = DEPTH_INDENT * float(depth)
	wrap.add_child(pad)

	var b := Button.new()
	b.text = "%s　%s" % [str(info.get("zh", c.get("cmd", "?"))), _summary(c)]
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size.y = 30
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
	_build_chain()
	_build_inspector()


func _add_cmd(t: String) -> void:
	if cur_event < 0 or cur_event >= events.size():
		UI.hint(_insp_box, "先新建一个事件。")
		return
	var chain: Array = events[cur_event].get("commands", [])
	if sel_path.size() > 0:
		chain = _chain_at(sel_path.slice(0, sel_path.size() - 1))
	var node := {"cmd": t}
	for f in CMDS.get(t, {}).get("fields", []):
		node[str(f["k"])] = _default_of(f)
	if t == "if":
		node["then"] = []
		node["else"] = []
	chain.append(node)
	sel_path = []
	_mark()
	refresh_all()


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


func _del_cmd() -> void:
	if sel_path.is_empty() or cur_event < 0:
		return
	var chain := _chain_at(sel_path.slice(0, sel_path.size() - 1))
	var idx := int(sel_path[-1])
	if idx >= 0 and idx < chain.size():
		chain.remove_at(idx)
	sel_path = []
	_mark()
	refresh_all()


func _move_cmd(dir: int) -> void:
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


# ———————— 属性面板 ————————

func _build_inspector() -> void:
	for c in _insp_box.get_children():
		c.queue_free()
	if cur_event < 0 or cur_event >= events.size():
		return
	if sel_path.is_empty():
		_build_event_props()
	else:
		_build_cmd_props()


## 选中事件本身（未选命令）时：名字 / 触发条件 / 只触发一次 / 旗标前提
func _build_event_props() -> void:
	var ev: Dictionary = events[cur_event]

	UI.label(_insp_box, "事件属性", 15, UI.ACCENT)
	UI.hsep(_insp_box)

	UI.label(_insp_box, "名称", 13, UI.DIM)
	var nm := LineEdit.new()
	nm.text = str(ev.get("name", ""))
	nm.text_changed.connect(func(t):
		ev["name"] = t
		_mark()
		_build_event_list()
	)
	_insp_box.add_child(nm)

	UI.hsep(_insp_box)
	UI.label(_insp_box, "触发条件", 14, UI.TEXT)
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
	_insp_box.add_child(opt)

	var tf: Array = TRIGGERS.get(cur_type, {}).get("fields", [])
	for f in tf:
		_field(_insp_box, trig, f, func():
			_mark()
			_build_event_list()
		)

	UI.hsep(_insp_box)
	var once := CheckBox.new()
	once.text = "只触发一次"
	once.button_pressed = bool(ev.get("once", true))
	once.toggled.connect(func(v):
		ev["once"] = v
		_mark()
	)
	_insp_box.add_child(once)

	UI.label(_insp_box, "触发前提（旗标，可留空）", 13, UI.DIM)
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
	)
	_insp_box.add_child(fl)
	var eq := CheckBox.new()
	eq.text = "旗标为真时才触发"
	eq.button_pressed = bool(cond.get("equals", true))
	eq.toggled.connect(func(v):
		cond["equals"] = v
		_mark()
	)
	_insp_box.add_child(eq)


## 选中某条命令时：按注册表生成字段表单 + 增删移
func _build_cmd_props() -> void:
	var c := _node_at(sel_path)
	if c.is_empty():
		UI.hint(_insp_box, "命令已不存在，重新选一条。")
		return
	var t := str(c.get("cmd", ""))
	var info: Dictionary = CMDS.get(t, {})

	UI.label(_insp_box, "命令：" + str(info.get("zh", t)), 15, UI.ACCENT)
	UI.hsep(_insp_box)

	for f in info.get("fields", []):
		_field(_insp_box, c, f, func(): _mark(); _build_chain())

	UI.hsep(_insp_box)
	var acts := UI.hbox(_insp_box, 6)
	UI.button(acts, "↑ 上移", _move_cmd.bind(-1), 76)
	UI.button(acts, "↓ 下移", _move_cmd.bind(1), 76)
	UI.button(acts, "删除命令", _del_cmd, 88)

	if t == "if":
		UI.hsep(_insp_box)
		UI.hint(_insp_box, "分支内容在中栏缩进的「满足时 / 否则」里继续添加：\n先选中分支里的某条命令再点「＋」，会插到同一层。")
		var tb := UI.button(_insp_box, "＋ 往「满足时」加一条", func():
			sel_path = sel_path + ["then"]
			_add_cmd("dialogue")
		)
		tb.add_theme_font_size_override("font_size", 12)
		var eb := UI.button(_insp_box, "＋ 往「否则」加一条", func():
			sel_path = sel_path + ["else"]
			_add_cmd("dialogue")
		)
		eb.add_theme_font_size_override("font_size", 12)


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
	_dirty = true
	changed.emit()
