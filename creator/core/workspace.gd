extends VBoxContainer
## 共享工作区：五个编辑模块 + 保存 / 重载 / 脏标记 / 状态广播。
##
## 这一层是「独立创作器」与「Godot 编辑器插件」的**唯一共用实体**。职责边界很硬：
##   · 它只知道怎么编辑和保存数据，不知道自己在谁肚子里跑；
##   · 它**不创建窗口、不决定试玩方式、不碰编辑器 API**——那三件事交给宿主；
##   · 试玩只发 `playtest_requested` 信号，独立版起新进程、插件版调 EditorInterface。
##
## 这样两个宿主加起来只有几十行胶水代码，编辑逻辑一份，改一处两边同时生效。

## 脏标记变化（宿主用来决定是否拦截关闭 / 是否点亮标题星号）
signal dirty_changed(is_dirty: bool)
## 状态广播：level 0=普通 1=成功 2=警告 3=错误
signal status_changed(msg: String, level: int)
## 请求试玩（由宿主实现：独立版起进程，插件版走编辑器）
signal playtest_requested()
## 请求关闭（仅独立版有「退出」按钮时会发）
signal quit_requested()

const UI := preload("res://creator/core/ui_kit.gd")
const Store := preload("res://creator/core/data_store.gd")
const EventEditor := preload("res://creator/core/event_editor.gd")
const DungeonView := preload("res://creator/core/dungeon_view.gd")
const TileEditor := preload("res://creator/core/tile_editor.gd")

const LV_INFO := 0
const LV_OK := 1
const LV_WARN := 2
const LV_ERR := 3

const DB_CATS := [
	["chars", "角色"], ["enemies", "怪物"], ["items", "物品"],
	["equipment", "装备"], ["skills", "技能"], ["quests", "任务"],
]
const DB_KEYS := ["chars", "enemies", "items", "equipment", "skills", "quests"]

var balance: Dictionary = {}
var map_data: Dictionary = {}
var dirty := false

var _pages := {}
var _nav_btns := {}
var _cur := "overview"
var _status_lbl: Label
var _dirty_lbl: Label

# 数据库页
var _db_cat := "chars"
var _db_keys: Array = []
var _db_sel := ""
var _db_list: ItemList
var _db_form: VBoxContainer

# 数值页
var _num_groups: Array = []
var _num_sel := ""
var _num_list: ItemList
var _num_form: VBoxContainer

# 事件 / 关卡
var _ev: EventEditor
var _dv: DungeonView
var _lv_floor := 1
var _lv_seed := 20261103
var _lv_info: Label

# 总览
var _ov_body: VBoxContainer


func _ready() -> void:
	add_theme_constant_override("separation", 0)
	_build_ui()
	load_all()
	_build_pages()
	_switch("overview")


# ———————— 构建 ————————

func _build_ui() -> void:
	# 顶部工具条：保存 / 重载 / 试玩 + 状态
	var bar := PanelContainer.new()
	bar.custom_minimum_size.y = 44
	add_child(bar)
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 8)
	bar.add_child(bh)

	var tag := Label.new()
	tag.text = "QY"
	tag.add_theme_font_override("font", UI.mono())
	tag.add_theme_font_size_override("font_size", 16)
	tag.add_theme_color_override("font_color", UI.ACCENT)
	bh.add_child(tag)

	UI.label(bh, "创作工坊", 15, UI.TEXT)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bh.add_child(sp)

	UI.button(bh, "保存", _save, 84).tooltip_text = "写回 balance.json 与 map001.json（自动备份 3 份，Ctrl+S）"
	UI.button(bh, "重载", reload, 72).tooltip_text = "放弃未保存修改，重新读磁盘"
	UI.button(bh, "试玩", func(): playtest_requested.emit(), 72).tooltip_text = "由宿主决定怎么启动游戏"

	# 主体：左导航 + 内容
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	add_child(body)

	var nav := VBoxContainer.new()
	nav.custom_minimum_size.x = 152
	nav.add_theme_constant_override("separation", 2)
	body.add_child(nav)

	var nav_pad := Control.new()
	nav_pad.custom_minimum_size.y = 6
	nav.add_child(nav_pad)

	var modules := [
		["overview", "总览", UI.MOD_OVERVIEW],
		["numbers", "数值", UI.MOD_NUMBERS],
		["database", "数据库", UI.MOD_DATABASE],
		["events", "事件", UI.MOD_EVENTS],
		["level", "关卡", UI.MOD_LEVEL],
		["tiles", "场景", UI.MOD_TILES],
	]
	for m in modules:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		nav.add_child(row)
		var bar_c := UI.accent_bar(row, m[2], 3, 34)
		var b := Button.new()
		b.text = "　" + str(m[1])
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.flat = true
		b.custom_minimum_size = Vector2(0, 34)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_switch.bind(str(m[0])))
		row.add_child(b)
		_nav_btns[str(m[0])] = {"btn": b, "bar": bar_c}

	var content := PanelContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(content)
	var inner := Control.new()
	content.add_child(inner)
	for m in modules:
		var p := MarginContainer.new()
		p.set_anchors_preset(Control.PRESET_FULL_RECT)
		p.visible = false
		p.add_theme_constant_override("margin_left", 12)
		p.add_theme_constant_override("margin_right", 12)
		p.add_theme_constant_override("margin_top", 10)
		p.add_theme_constant_override("margin_bottom", 10)
		inner.add_child(p)
		_pages[str(m[0])] = p

	# 底部状态条
	var sb := PanelContainer.new()
	sb.custom_minimum_size.y = 28
	add_child(sb)
	var sh := HBoxContainer.new()
	sh.add_theme_constant_override("separation", 12)
	sb.add_child(sh)
	_status_lbl = UI.label(sh, "就绪", 12, UI.DIM)
	_status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dirty_lbl = UI.mono_label(sh, "已同步", 12, UI.DIM)


func _build_pages() -> void:
	for k in _pages:
		for c in _pages[k].get_children():
			_pages[k].remove_child(c)
			c.queue_free()
	_pages["overview"].add_child(_make_overview())
	_pages["numbers"].add_child(_make_numbers())
	_pages["database"].add_child(_make_database())
	_pages["events"].add_child(_make_events())
	_pages["level"].add_child(_make_level())
	_pages["tiles"].add_child(_make_tiles())


# ———————— 数据 ————————

func load_all() -> void:
	var b := Store.load_json(Store.BALANCE_PATH)
	if bool(b["ok"]):
		balance = b["data"]
	else:
		_set_status("数值文件读取失败：" + str(b["error"]), LV_ERR)
	var m := Store.load_json(Store.MAP_PATH)
	if bool(m["ok"]):
		map_data = m["data"]
	else:
		_set_status("事件文件读取失败（事件页将为空）：" + str(m["error"]), LV_WARN)
	if not (map_data.get("events") is Array):
		map_data["events"] = []
	if not (balance.get("chars") is Dictionary):
		balance["chars"] = {}
	dirty = false
	_emit_dirty()


func reload() -> void:
	if dirty:
		_set_status("已放弃未保存修改，重新读磁盘", LV_WARN)
	load_all()
	_build_pages()
	_switch(_cur)


func _save() -> void:
	var r1 := Store.save_json(Store.BALANCE_PATH, balance, "balance")
	if not bool(r1["ok"]):
		_set_status("数值保存失败：" + str(r1["error"]), LV_ERR)
		return
	var r2 := Store.save_json(Store.MAP_PATH, map_data, "map")
	if not bool(r2["ok"]):
		_set_status("事件保存失败：" + str(r2["error"]), LV_ERR)
		return
	dirty = false
	_emit_dirty()
	_set_status("已保存并备份（游戏内热重载会在下一次检查时套用）", LV_OK)


func _mark_dirty() -> void:
	dirty = true
	_emit_dirty()


## 宿主用的对外保存入口（插件菜单、工具栏按钮都调它）
func save_now() -> void:
	_save()


## 宿主用的对外通知入口
func notify(msg: String, level: int = LV_INFO) -> void:
	_set_status(msg, level)


func _emit_dirty() -> void:
	if _dirty_lbl != null:
		_dirty_lbl.text = "● 未保存" if dirty else "✓ 已同步"
		_dirty_lbl.add_theme_color_override("font_color", UI.WARN if dirty else UI.DIM)
	dirty_changed.emit(dirty)


func _set_status(msg: String, level: int = LV_INFO) -> void:
	var col := UI.DIM
	match level:
		LV_OK: col = UI.OK
		LV_WARN: col = UI.WARN
		LV_ERR: col = UI.ERR
	if _status_lbl != null:
		_status_lbl.text = msg
		_status_lbl.add_theme_color_override("font_color", col)
	status_changed.emit(msg, level)


func _switch(key: String) -> void:
	_cur = key
	for k in _pages:
		_pages[k].visible = (k == key)
	for k in _nav_btns:
		var on: bool = (str(k) == key)
		var b: Button = _nav_btns[k]["btn"]
		var bar: ColorRect = _nav_btns[k]["bar"]
		b.add_theme_color_override("font_color", UI.TEXT if on else UI.DIM)
		b.add_theme_stylebox_override("normal", _nav_style(on))
		b.add_theme_stylebox_override("hover", _nav_style(on, true))
		bar.custom_minimum_size.x = 3.0 if on else 2.0
	match key:
		"overview": _refresh_overview()
		"numbers": _refresh_num_list()
		"database": _refresh_db_list()
		"level": _refresh_level()
		"tiles":
			# 等一帧让容器完成布局，再看要不要缩放适配
			if _tiles != null:
				_tiles.call_deferred("reset_view")
	# 一次编排好的入场：切换模块时内容错峰浮现
	UI.stagger_in(_pages[key])


func _nav_style(on: bool, hover: bool = false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = (UI.PANEL_3 if on else (UI.PANEL_2 if hover else Color(0, 0, 0, 0)))
	s.content_margin_left = 10
	s.content_margin_right = 8
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s


# ———————— ① 总览 ————————

func _make_overview() -> Control:
	var sc := ScrollContainer.new()
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ov_body = UI.vbox(sc, 10)
	_ov_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_refresh_overview()
	return sc


func _refresh_overview() -> void:
	if _ov_body == null:
		return
	for c in _ov_body.get_children():
		_ov_body.remove_child(c)
		c.queue_free()

	UI.section(_ov_body, "项目现状", UI.MOD_OVERVIEW)
	var rows := [
		["角色", "%d 个" % balance.get("chars", {}).size()],
		["怪物", "%d 种" % balance.get("enemies", {}).size()],
		["物品 / 装备", "%d / %d" % [balance.get("items", {}).size(), balance.get("equipment", {}).size()]],
		["技能", "%d 个" % balance.get("skills", {}).size()],
		["楼层总数", str(balance.get("max_floor", "?"))],
		["事件", "%d 个" % (map_data.get("events", []) as Array).size()],
	]
	for r in rows:
		var h := UI.hbox(_ov_body, 10)
		var l := UI.label(h, str(r[0]), 13, UI.DIM)
		l.custom_minimum_size.x = 96
		UI.mono_label(h, str(r[1]), 13, UI.TEXT)
	UI.hint(_ov_body, "数据源：" + Store.BALANCE_PATH + " ／ " + Store.MAP_PATH)

	UI.hsep(_ov_body)
	UI.section(_ov_body, "完整性检查", UI.OK)
	var errs: Array = []
	for pair in [["balance", balance], ["map", map_data]]:
		var e := Store.validate(str(pair[0]), pair[1])
		if e != "":
			errs.append("【%s】%s" % [pair[0], e])
	if (map_data.get("events", []) as Array).is_empty():
		errs.append("事件表为空：游戏里不会有任何剧情触发（不致命）")
	if errs.is_empty():
		UI.label(_ov_body, "· 结构完整，必需字段齐全", 13, UI.OK)
	else:
		for e2 in errs:
			var fatal := str(e2).find("不致命") < 0
			UI.label(_ov_body, "· " + str(e2), 13, UI.ERR if fatal else UI.WARN)

	UI.hsep(_ov_body)
	UI.section(_ov_body, "怎么用", UI.MOD_NUMBERS)
	for tip in [
		"数值：左栏选一组参数，右侧直接改。保存后游戏内热重载自动套用。",
		"数据库：左栏选实体（某个角色/怪物/物品），右侧改它的字段。",
		"事件：新建事件 → 选触发条件 → 中栏按钮添加命令 → 选中命令在右栏改细节。",
		"关卡：调层号与种子看地牢形态；满意的种子填进「数值 → 全局 → 地牢种子」。",
		"所有改动写入 data/*.json，保存时自动备份 3 份，可回滚。",
	]:
		UI.hint(_ov_body, "· " + str(tip))

	UI.hsep(_ov_body)
	var q := UI.hbox(_ov_body, 8)
	UI.button(q, "去改数值", _switch.bind("numbers"), 108)
	UI.button(q, "去写事件", _switch.bind("events"), 108)
	UI.button(q, "看地牢", _switch.bind("level"), 108)


# ———————— ② 数值 ————————

func _make_numbers() -> Control:
	var wrap := HBoxContainer.new()
	wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrap.add_theme_constant_override("separation", 12)

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 196
	wrap.add_child(left)
	UI.section(left, "参数分组", UI.MOD_NUMBERS)
	UI.hint(left, "全部来自 balance.json，保存即热重载。")
	_num_list = ItemList.new()
	_num_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_num_list.item_selected.connect(func(i):
		if i >= 0 and i < _num_groups.size():
			_num_sel = str(_num_groups[i])
			_refresh_num_form()
	)
	left.add_child(_num_list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.add_child(right)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(sc)
	_num_form = UI.vbox(sc, 6)
	_num_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_refresh_num_list()
	return wrap


func _num_top_keys() -> Array:
	var out: Array = []
	for k in balance.keys():
		if str(k) in DB_KEYS or str(k) == "char_skills":
			continue
		out.append(str(k))
	out.sort()
	return out


func _refresh_num_list() -> void:
	if _num_list == null:
		return
	_num_groups = _num_top_keys()
	_num_list.clear()
	for k in _num_groups:
		_num_list.add_item(UI.pretty(str(k)))
	if _num_sel == "" and _num_groups.size() > 0:
		_num_sel = str(_num_groups[0])
	var idx := _num_groups.find(_num_sel)
	if idx >= 0:
		_num_list.select(idx)
	_refresh_num_form()


func _refresh_num_form() -> void:
	if _num_form == null:
		return
	for c in _num_form.get_children():
		_num_form.remove_child(c)
		c.queue_free()
	if _num_sel == "":
		return
	var v = balance.get(_num_sel, null)
	if v == null:
		UI.hint(_num_form, "这一组是空的。")
		return
	UI.label(_num_form, UI.pretty(_num_sel), 16, UI.TEXT)
	UI.mono_label(_num_form, _num_sel, 11, UI.DIM)
	UI.hsep(_num_form)
	_sub_form(_num_form, _num_sel, v)


## 把任意值铺成表单。回调一律用 bind 带上「写回哪个容器、哪个键」，
## 不在循环里靠闭包捕获——那种写法一旦捕获语义不如预期，所有输入框会写到同一个键上。
func _sub_form(parent: Node, key: String, v: Variant) -> void:
	if v is Dictionary:
		for k in (v as Dictionary).keys():
			var kk := str(k)
			var sub = v[k]
			if sub is Dictionary:
				var box := UI.vbox(parent, 4)
				UI.label(box, UI.pretty(kk), 14, UI.TEXT)
				_sub_form(box, kk, sub)
			else:
				UI.editor_for(parent, kk, sub, _set_value.bind(v, kk))
	else:
		UI.editor_for(parent, key, v, _set_root.bind(key))


func _set_value(nv: Variant, container: Dictionary, key: String) -> void:
	container[key] = nv
	_mark_dirty()


func _set_root(nv: Variant, key: String) -> void:
	balance[key] = nv
	_mark_dirty()


# ———————— ③ 数据库 ————————

func _make_database() -> Control:
	var wrap := HBoxContainer.new()
	wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrap.add_theme_constant_override("separation", 12)

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 228
	wrap.add_child(left)
	UI.section(left, "数据库", UI.MOD_DATABASE)
	var cat := OptionButton.new()
	for i in DB_CATS.size():
		cat.add_item(str(DB_CATS[i][1]), i)
	cat.item_selected.connect(func(i):
		_db_cat = str(DB_CATS[i][0])
		_db_sel = ""
		_refresh_db_list()
	)
	left.add_child(cat)
	_db_list = ItemList.new()
	_db_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_db_list.item_selected.connect(func(i):
		if i >= 0 and i < _db_keys.size():
			_db_sel = str(_db_keys[i])
			_refresh_db_form()
	)
	left.add_child(_db_list)
	var acts := UI.hbox(left, 6)
	UI.button(acts, "＋ 新建", _db_add, 96)
	UI.button(acts, "删除", _db_del, 60)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.add_child(right)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(sc)
	_db_form = UI.vbox(sc, 6)
	_db_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_refresh_db_list()
	return wrap


func _refresh_db_list() -> void:
	if _db_list == null:
		return
	var table: Dictionary = balance.get(_db_cat, {})
	_db_keys = table.keys()
	_db_list.clear()
	for k in _db_keys:
		var disp := str(k)
		if table[k] is Dictionary:
			disp = "%s　%s" % [str(table[k].get("name", k)), str(k)]
		_db_list.add_item(disp)
	if _db_sel == "" and _db_keys.size() > 0:
		_db_sel = str(_db_keys[0])
	var idx := _db_keys.find(_db_sel)
	if idx >= 0:
		_db_list.select(idx)
	_refresh_db_form()


func _refresh_db_form() -> void:
	if _db_form == null:
		return
	for c in _db_form.get_children():
		_db_form.remove_child(c)
		c.queue_free()
	var table: Dictionary = balance.get(_db_cat, {})
	if _db_sel == "" or not table.has(_db_sel):
		UI.hint(_db_form, "左栏选一个条目。")
		return
	var ent = table[_db_sel]
	UI.label(_db_form, str(ent.get("name", _db_sel)) if ent is Dictionary else _db_sel, 16, UI.TEXT)
	UI.mono_label(_db_form, _db_sel, 11, UI.DIM)
	UI.hsep(_db_form)
	if not (ent is Dictionary):
		UI.editor_for(_db_form, _db_sel, ent, func(nv):
			table[_db_sel] = nv
			_mark_dirty()
		)
		return
	for k in (ent as Dictionary).keys():
		var kk := str(k)
		var sub = ent[k]
		if sub is Dictionary:
			var box := UI.vbox(_db_form, 4)
			UI.label(box, UI.pretty(kk), 14, UI.TEXT)
			for sk in (sub as Dictionary).keys():
				var skk := str(sk)
				UI.editor_for(box, skk, sub[skk], _set_value.bind(sub, skk))
		else:
			UI.editor_for(_db_form, kk, sub, _set_value.bind(ent, kk))


func _db_add() -> void:
	var table: Dictionary = balance.get(_db_cat, {})
	var n := 1
	var key := "new_%d" % n
	while table.has(key):
		n += 1
		key = "new_%d" % n
	table[key] = {"name": "新条目 %d" % n}
	_db_sel = key
	_mark_dirty()
	_refresh_db_list()


func _db_del() -> void:
	var table: Dictionary = balance.get(_db_cat, {})
	if _db_sel == "" or not table.has(_db_sel):
		return
	table.erase(_db_sel)
	_db_sel = ""
	_mark_dirty()
	_refresh_db_list()


# ———————— ④ 事件 ————————

func _make_events() -> Control:
	_ev = EventEditor.new()
	_ev.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ev.changed.connect(_mark_dirty)
	_ev.preview_cell.connect(func(cell: Vector2i):
		_switch("level")
		_set_status("事件引用的格子 " + UI.coord(cell.x, cell.y), LV_INFO)
	)
	_ev.setup(map_data.get("events", []), balance)
	return _ev


# ———————— ⑤ 关卡 ————————

func _make_level() -> Control:
	var wrap := HBoxContainer.new()
	wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrap.add_theme_constant_override("separation", 12)

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 226
	wrap.add_child(left)
	UI.section(left, "地牢参数", UI.MOD_LEVEL)
	UI.hint(left, "只做预览与调参，不改生成算法。")

	var fh := UI.hbox(left, 6)
	UI.label(fh, "层号", 13, UI.DIM)
	var sf := SpinBox.new()
	sf.min_value = 1
	sf.max_value = 9
	sf.value = _lv_floor
	sf.custom_minimum_size.x = 92
	sf.value_changed.connect(func(v):
		_lv_floor = int(v)
		_apply_level()
	)
	fh.add_child(sf)

	var sh := UI.hbox(left, 6)
	UI.label(sh, "种子", 13, UI.DIM)
	var ss := SpinBox.new()
	ss.min_value = 0
	ss.max_value = 9999999
	ss.value = _lv_seed
	ss.custom_minimum_size.x = 128
	ss.value_changed.connect(func(v):
		_lv_seed = int(v)
		_apply_level()
	)
	sh.add_child(ss)

	UI.button(left, "换一张", func():
		_lv_seed = randi() % 1000000
		_apply_level()
	)

	UI.hsep(left)
	UI.hint(left, "同一颗种子永远生成同一张图。把满意的种子填进「数值 → 地牢种子」即可在游戏里复现。")
	_lv_info = UI.label(left, "", 12, UI.DIM)
	_lv_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.add_child(right)
	_dv = DungeonView.new()
	_dv.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dv.pick_mode = true
	right.add_child(_dv)

	_apply_level()
	return wrap


func _apply_level() -> void:
	if _dv == null:
		return
	var total := int(balance.get("max_floor", 5))
	_dv.rebuild(_lv_floor, _lv_seed)
	if _lv_info != null:
		_lv_info.text = "第 %d 层 / 共 %d 层　种子 %d" % [_dv.floor_no, total, _lv_seed]
		if _dv.floor_no >= total:
			_lv_info.text += "\n（最后一层：按设计生成首领单间）"


func _refresh_level() -> void:
	_apply_level()


# ———————— ⑥ 场景（图块搭建） ————————

var _tiles

func _make_tiles() -> Control:
	_tiles = TileEditor.new()
	_tiles.dirty.connect(_mark_dirty)
	_tiles.status.connect(func(m: String, lv: int): _set_status(m, lv))
	return _tiles


# ———————— 键盘 ————————

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.ctrl_pressed and event.keycode == KEY_S:
		_save()
		get_viewport().set_input_as_handled()
