extends VBoxContainer
## 共享工作区：RPG Maker 式四区布局 + 保存 / 重载 / 脏标记 / 状态广播。
##
## 布局（对照参考图 RPGMaker Codebase，但做得更完整）：
##   ┌ 菜单栏：文件 / 编辑 / 视图 / 帮助
##   ├ 工具条：保存 / 重载 / 试玩 + 脏标记
##   ├ 左「RPG Data」树 │ 中央预览/编辑区 │ 右「RPG Setting」属性面板
##   ├ 底部事件条（事件命令列表，选中事件时自动展开）
##   └ 状态条
##
## 左树是**唯一导航入口**：选中什么节点，中央就渲染它的预览，右栏就是它的属性。
## 这层是「独立创作器」与「Godot 编辑器插件」的**唯一共用实体**，职责边界很硬：
##   · 它只知道怎么编辑和保存数据，不知道自己在谁肚子里跑；
##   · 它不创建窗口、不决定试玩方式、不碰编辑器 API——那三件事交给宿主；
##   · 试玩只发 playtest_requested，独立版起新进程、插件版调 EditorInterface。

## 脏标记变化（宿主用来决定是否拦截关闭 / 是否点亮标题星号）
signal dirty_changed(is_dirty: bool)
## 状态广播：level 0=普通 1=成功 2=警告 3=错误
signal status_changed(msg: String, level: int)
## 请求试玩（由宿主实现：独立版起进程，插件版走编辑器）
signal playtest_requested()
## 请求关闭（仅独立版有「退出」菜单时会发）
signal quit_requested()

const UI := preload("res://creator/core/ui_kit.gd")
const Store := preload("res://creator/core/data_store.gd")
const EventEditor := preload("res://creator/core/event_editor.gd")
const DungeonView := preload("res://creator/core/dungeon_view.gd")
const TileEditor := preload("res://creator/core/tile_editor.gd")
const DbPreview := preload("res://creator/core/db_preview.gd")
const SpriteView := preload("res://creator/core/sprite_view.gd")

const LV_INFO := 0
const LV_OK := 1
const LV_WARN := 2
const LV_ERR := 3

## 数据库分类：kind → (中文, balance 键)
const CATS := [
	["char", "角色", "chars"], ["enemy", "怪物", "enemies"],
	["item", "物品", "items"], ["equipment", "装备", "equipment"],
	["skill", "技能", "skills"], ["quest", "任务", "quests"],
]
const ENTITY_KINDS := ["char", "enemy", "boss", "item", "equipment", "skill", "quest"]
const KIND_ZH := {
	"char": "角色", "enemy": "怪物", "boss": "首领", "item": "物品",
	"equipment": "装备", "skill": "技能", "quest": "任务",
}

var balance: Dictionary = {}
var map_data: Dictionary = {}
var dirty := false

# —— 布局 ——
var _tree: Tree
var _center: MarginContainer
var _right_box: VBoxContainer
var _status_lbl: Label
var _dirty_lbl: Label
var _strip: PanelContainer
var _strip_body: VBoxContainer
var _strip_toggle: Button
var _strip_open := false
var _right_panel: PanelContainer
var _view_popup: PopupMenu
var _right_menu_id := -1
var _strip_menu_id := -1

# —— 常驻控件（路由时 detach 而不是 free） ——
var _persist: Array = []

# —— 页面实例 ——
var _ov_body: VBoxContainer
var _ev: EventEditor
var _dv: DungeonView
var _tiles: TileEditor

# —— 状态 ——
var _sel := {"kind": "overview", "id": "", "idx": -1}
var _lv_floor := 1
var _lv_seed := 20261103
var _lv_info: Label
var _preview_pending := false


func _ready() -> void:
	add_theme_constant_override("separation", 0)
	_build_menubar()
	_build_toolbar()
	_build_body()
	_build_strip()
	_build_statusbar()
	load_all()
	# 事件编辑器要拿到 events 数组的**引用**（增删直接改 map_data）与模板表
	_ev.setup(map_data.get("events", []), balance)
	_rebuild_tree()
	_route(_sel)


# ———————— 顶部：菜单栏 ————————

func _build_menubar() -> void:
	var bar := PanelContainer.new()
	bar.custom_minimum_size.y = 28
	add_child(bar)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 2)
	bar.add_child(h)

	var file := UI.menu_button(h, "文件")
	var fp := file.get_popup()
	fp.add_item("保存　(Ctrl+S)", 0)
	fp.add_item("重载（放弃未保存修改）", 1)
	fp.add_item("备份列表…", 2)
	fp.add_separator()
	fp.add_item("退出", 4)
	fp.id_pressed.connect(_on_file_menu)

	var edit := UI.menu_button(h, "编辑")
	var ep := edit.get_popup()
	ep.add_item("撤销场景绘制　(Ctrl+Z)", 0)
	ep.add_item("重做场景绘制　(Ctrl+Shift+Z)", 1)
	ep.id_pressed.connect(_on_edit_menu)

	var view := UI.menu_button(h, "视图")
	var vp := view.get_popup()
	vp.add_check_item("右侧属性面板", 0)
	vp.add_check_item("底部事件条", 1)
	_right_menu_id = 0
	_strip_menu_id = 1
	_view_popup = vp
	vp.set_item_checked(_right_menu_id, true)
	vp.about_to_popup.connect(func():
		if _view_popup != null and is_instance_valid(_right_panel):
			_view_popup.set_item_checked(_right_menu_id, _right_panel.visible)
			_view_popup.set_item_checked(_strip_menu_id, _strip_open)
	)
	vp.id_pressed.connect(_on_view_menu)

	var help := UI.menu_button(h, "帮助")
	var hp := help.get_popup()
	hp.add_item("使用指南", 0)
	hp.add_item("关于", 1)
	hp.id_pressed.connect(_on_help_menu)


func _on_file_menu(id: int) -> void:
	match id:
		0: _save()
		1: reload()
		2: _show_backups()
		4: quit_requested.emit()


func _on_edit_menu(id: int) -> void:
	if str(_sel.get("kind", "")) == "scene":
		_tiles.handle_key(KEY_Z, id == 1)
	else:
		_set_status("撤销/重做只作用于场景页的绘制", LV_INFO)


func _on_view_menu(id: int) -> void:
	if id == 0:
		_right_panel.visible = not _right_panel.visible
	else:
		_strip_open = not _strip_open
		_update_strip()


func _on_help_menu(id: int) -> void:
	if id == 0:
		_show_help()
	else:
		_show_about()


func _show_backups() -> void:
	var d := AcceptDialog.new()
	d.title = "备份列表（自动保留 3 份）"
	d.ok_button_text = "关闭"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.custom_minimum_size = Vector2(560, 240)
	d.add_child(box)
	for p in [Store.BALANCE_PATH, Store.MAP_PATH]:
		UI.label(box, p, 14, UI.TEXT)
		var backs := Store.list_backups(p)
		if backs.is_empty():
			UI.hint(box, "　（还没有备份；每次保存都会滚动生成）")
		for b in backs:
			UI.mono_label(box, "　%s　%s" % [str(b["path"]).get_file(), str(b["time"])], 12, UI.DIM)
		UI.hsep(box)
	add_child(d)
	d.popup_centered()


func _show_help() -> void:
	var d := AcceptDialog.new()
	d.title = "使用指南"
	d.ok_button_text = "明白了"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.custom_minimum_size = Vector2(560, 300)
	d.add_child(box)
	for tip in [
		"左树是唯一导航：选中角色/怪物/物品，中央出预览卡，右栏直接改属性。",
		"数值参数组：右栏改数值，中央是只读摘要；保存后游戏内热重载自动套用。",
		"地图与关卡：选楼层看地牢形态；满意的种子填进「数值 → 全局 → 地牢种子」。",
		"事件：选一个事件 → 中央是节点流画布（条件分支分出是/否两列），\n底部是线性命令列表；点击节点或列表行，右栏改字段。",
		"场景：中央画图块（滚轮缩放 / 中键平移 / 右键擦除 / Alt+左键吸管），右栏管图层与存档。",
		"Ctrl+S 全局保存 balance 与事件；在场景页时保存的是场景 JSON。",
		"所有改动写入 data/*.json，保存时自动备份 3 份，可回滚。",
	]:
		UI.hint(box, "· " + str(tip))
	add_child(d)
	d.popup_centered()


func _show_about() -> void:
	var d := AcceptDialog.new()
	d.title = "关于"
	d.ok_button_text = "关闭"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.custom_minimum_size = Vector2(380, 120)
	d.add_child(box)
	UI.label(box, "千亿魔女 · 创作工坊", 18, UI.TEXT)
	UI.hint(box, "RPG Maker 式可视化创作工具：数据库 / 数值 / 事件 / 关卡 / 场景。\n两个宿主共用一份内核：独立窗口（打开创作器.bat）与 Godot 编辑器插件。")
	UI.mono_label(box, "Godot 4.7 · data/*.json 为唯一数据源", 12, UI.DIM)
	add_child(d)
	d.popup_centered()


# ———————— 顶部：工具条 ————————

func _build_toolbar() -> void:
	var bar := PanelContainer.new()
	bar.custom_minimum_size.y = 42
	add_child(bar)
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 8)
	bar.add_child(bh)

	var tag := Label.new()
	tag.text = "◆"
	tag.add_theme_font_override("font", UI.mono())
	tag.add_theme_font_size_override("font_size", 16)
	tag.add_theme_color_override("font_color", UI.ACCENT)
	bh.add_child(tag)

	UI.label(bh, "千亿魔女 · 创作工坊", 15, UI.TEXT)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bh.add_child(sp)

	var save_btn := UI.button(bh, "保存", _save, 84)
	save_btn.tooltip_text = "写回 balance.json 与 map001.json（自动备份 3 份，Ctrl+S）"
	# 保存是关键动作：按设计规范给它强调色边框（ACCENT 只留给关键动作）
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.14)
	sb.set_border_width_all(1)
	sb.border_color = UI.ACCENT
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	save_btn.add_theme_stylebox_override("normal", sb)
	var sbh := sb.duplicate() as StyleBoxFlat
	sbh.bg_color = Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.24)
	save_btn.add_theme_stylebox_override("hover", sbh)
	save_btn.add_theme_color_override("font_color", UI.ACCENT)
	UI.button(bh, "重载", reload, 72).tooltip_text = "放弃未保存修改，重新读磁盘"
	UI.button(bh, "试玩", func(): playtest_requested.emit(), 72).tooltip_text = "由宿主决定怎么启动游戏"


# ———————— 中部：左树 / 中央 / 右栏 ————————

func _build_body() -> void:
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	add_child(body)

	# —— 左：RPG Data 树 ——
	var left := PanelContainer.new()
	left.custom_minimum_size.x = 252
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 0)
	left.add_child(lv)
	var lh := PanelContainer.new()
	lh.custom_minimum_size.y = 26
	lv.add_child(lh)
	var lhh := HBoxContainer.new()
	lhh.add_theme_constant_override("separation", 6)
	lh.add_child(lhh)
	UI.mono_label(lhh, "RPG DATA", 11, UI.ACCENT)
	UI.label(lhh, "数据库与资源", 12, UI.DIM)
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.item_selected.connect(_on_tree_selected)
	lv.add_child(_tree)

	# —— 右：属性面板 ——
	var right_panel := PanelContainer.new()
	_right_panel = right_panel
	right_panel.custom_minimum_size.x = 322
	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 0)
	right_panel.add_child(rv)
	var rh := PanelContainer.new()
	rh.custom_minimum_size.y = 26
	rv.add_child(rh)
	var rhh := HBoxContainer.new()
	rhh.add_theme_constant_override("separation", 6)
	rh.add_child(rhh)
	UI.mono_label(rhh, "RPG SETTING", 11, UI.ACCENT)
	UI.label(rhh, "属性", 12, UI.DIM)
	var rsc := ScrollContainer.new()
	rsc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rsc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rv.add_child(rsc)
	_right_box = UI.vbox(rsc, 10)
	_right_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# —— 中央：预览/编辑区 ——
	_center = MarginContainer.new()
	_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_center.add_theme_constant_override("margin_left", 12)
	_center.add_theme_constant_override("margin_right", 12)
	_center.add_theme_constant_override("margin_top", 10)
	_center.add_theme_constant_override("margin_bottom", 10)

	# 拖动分隔条：左树 | 中央 | 右栏
	var split_r := HSplitContainer.new()
	split_r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split_r.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split_r.add_theme_constant_override("separation", 4)
	split_r.add_child(_center)
	split_r.add_child(right_panel)

	var split_l := HSplitContainer.new()
	split_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split_l.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split_l.add_theme_constant_override("separation", 4)
	split_l.add_child(left)
	split_l.add_child(split_r)
	body.add_child(split_l)

	# —— 页面实例（构造一次，路由时复用） ——
	_ev = EventEditor.new()
	_ev.changed.connect(_mark_dirty)
	_ev.structure_changed.connect(func():
		_rebuild_tree()
	)
	_ev.preview_cell.connect(func(cell: Vector2i):
		_goto_floor(_lv_floor)
		_set_status("事件引用的格子 " + UI.coord(cell.x, cell.y) + "（切到楼层页对照）", LV_INFO)
	)
	_persist.append(_ev)

	_dv = DungeonView.new()
	_dv.pick_mode = true
	_dv.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_persist.append(_dv)

	_tiles = TileEditor.new()
	_tiles.dirty.connect(_mark_dirty)
	_tiles.status.connect(func(m: String, lv2: int): _set_status(m, lv2))
	_tiles.setup()
	_persist.append(_tiles.canvas_area)
	_persist.append(_tiles.props_panel)


# ———————— 底部：事件条 ————————

func _build_strip() -> void:
	_strip = PanelContainer.new()
	add_child(_strip)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	_strip.add_child(v)

	var head := PanelContainer.new()
	head.custom_minimum_size.y = 26
	v.add_child(head)
	var hh := HBoxContainer.new()
	hh.add_theme_constant_override("separation", 8)
	head.add_child(hh)
	_strip_toggle = Button.new()
	_strip_toggle.text = "▸ 事件"
	_strip_toggle.flat = true
	_strip_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_strip_toggle.custom_minimum_size = Vector2(90, 22)
	_strip_toggle.add_theme_font_size_override("font_size", 13)
	_strip_toggle.pressed.connect(func():
		_strip_open = not _strip_open
		_update_strip()
	)
	hh.add_child(_strip_toggle)
	UI.label(hh, "执行内容：事件被触发后从上到下依次执行", 12, UI.DIM)

	_strip_body = VBoxContainer.new()
	_strip_body.add_theme_constant_override("separation", 0)
	_strip_body.visible = false
	v.add_child(_strip_body)
	_strip_body.add_child(_ev)


func _update_strip() -> void:
	var is_event := str(_sel.get("kind", "")) == "event"
	if is_event:
		_strip_open = true
	_strip_body.visible = _strip_open and _ev != null
	_strip_toggle.text = ("▾ 事件" if _strip_open else "▸ 事件")


# ———————— 底部：状态条 ————————

func _build_statusbar() -> void:
	var sb := PanelContainer.new()
	sb.custom_minimum_size.y = 26
	add_child(sb)
	var sh := HBoxContainer.new()
	sh.add_theme_constant_override("separation", 12)
	sb.add_child(sh)
	_status_lbl = UI.label(sh, "就绪", 12, UI.DIM)
	_status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dirty_lbl = UI.mono_label(sh, "已同步", 12, UI.DIM)


# ———————— 左树 ————————

func _rebuild_tree() -> void:
	_tree.clear()
	var root := _tree.create_item()
	_tnode(root, {"kind": "overview", "id": "", "idx": -1}, "项目总览", UI.TEXT)

	var db := _tnode(root, {"kind": "_cat", "id": "db", "idx": -1}, "数据库", UI.DIM)
	for c in CATS:
		var cat := _tnode(db, {"kind": "_cat", "id": str(c[0]), "idx": -1}, str(c[1]), UI.DIM)
		var table: Dictionary = balance.get(str(c[2]), {})
		for k in table.keys():
			var disp := str(k)
			if table[k] is Dictionary:
				disp = "%s（%s）" % [str(table[k].get("name", k)), str(k)]
			_tnode(cat, {"kind": str(c[0]), "id": str(k), "idx": -1}, disp, UI.TEXT)
		if str(c[0]) == "enemy" and balance.get("boss") is Dictionary and not (balance["boss"] as Dictionary).is_empty():
			var b: Dictionary = balance["boss"]
			_tnode(cat, {"kind": "boss", "id": "boss", "idx": -1},
				"%s（boss）" % str(b.get("name", "首领")), UI.WARN)

	var sys := _tnode(root, {"kind": "_cat", "id": "params", "idx": -1}, "数值参数", UI.DIM)
	for k in _num_top_keys():
		_tnode(sys, {"kind": "param", "id": str(k), "idx": -1},
			"%s（%s）" % [UI.pretty(str(k)), str(k)], UI.TEXT)

	var mapcat := _tnode(root, {"kind": "_cat", "id": "map", "idx": -1}, "地图与关卡", UI.DIM)
	var total := int(balance.get("max_floor", 5))
	for i in range(1, total + 1):
		_tnode(mapcat, {"kind": "floor", "id": "", "idx": i}, "第 %d 层" % i, UI.TEXT)
	_tnode(mapcat, {"kind": "scene", "id": "scene001", "idx": -1}, "场景画布 · scene001", UI.TEXT)

	var evc := _tnode(root, {"kind": "_cat", "id": "events", "idx": -1}, "事件", UI.DIM)
	if _ev != null:
		for i in (map_data.get("events", []) as Array).size():
			_tnode(evc, {"kind": "event", "id": "", "idx": i}, _ev.event_label(i), UI.TEXT)

	_tree_select(_sel)


func _tnode(parent: TreeItem, meta: Dictionary, text: String, color: Color) -> TreeItem:
	var it := _tree.create_item(parent)
	it.set_text(0, text)
	it.set_tooltip_text(0, text)   # 树窄、条目长：悬停看全名
	it.set_metadata(0, meta)
	it.set_custom_color(0, color)
	return it


func _on_tree_selected() -> void:
	var it := _tree.get_selected()
	if it == null:
		return
	var meta: Dictionary = it.get_metadata(0)
	if meta == null or str(meta.get("kind", "")).begins_with("_"):
		return
	_route(meta)


## 程序化选中（快捷入口 / 事件预览跳转用）
func _tree_select(sel: Dictionary) -> void:
	var want_kind := str(sel.get("kind", ""))
	var want_id := str(sel.get("id", ""))
	var want_idx := int(sel.get("idx", -1))
	var stack: Array = [_tree.get_root()]
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		if it != null:
			var m: Variant = it.get_metadata(0)
			if m is Dictionary and str(m.get("kind", "")) == want_kind \
					and str(m.get("id", "")) == want_id and int(m.get("idx", -1)) == want_idx:
				it.select(0)
				return
			var ch := it.get_first_child()
			while ch != null:
				stack.append(ch)
				ch = ch.get_next()


func _goto(kind: String, id: String = "", idx: int = -1) -> void:
	_tree_select({"kind": kind, "id": id, "idx": idx})
	_route({"kind": kind, "id": id, "idx": idx})


func _goto_floor(n: int) -> void:
	_lv_floor = clampi(n, 1, int(balance.get("max_floor", 5)))
	_goto("floor", "", _lv_floor)


# ———————— 路由：中央 + 右栏 ————————

func _center_clear() -> void:
	for c in _center.get_children():
		_center.remove_child(c)
		if not _persist.has(c):
			c.queue_free()


func _right_clear() -> void:
	for c in _right_box.get_children():
		_right_box.remove_child(c)
		if not _persist.has(c):
			c.queue_free()


func _route(sel: Dictionary) -> void:
	_sel = sel
	var kind := str(_sel.get("kind", "overview"))
	_center_clear()
	_right_clear()
	match kind:
		"overview":
			_fill_overview()
		"param":
			_fill_param()
		"floor":
			_fill_floor()
		"scene":
			_fill_scene()
		"event":
			_fill_event()
		_:
			if kind in ENTITY_KINDS:
				_fill_entity()
	if kind != "event":
		_strip_open = false
	_update_strip()
	UI.stagger_in(_center)


func _fill_overview() -> void:
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_center.add_child(sc)
	_ov_body = UI.vbox(sc, 10)
	_ov_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_refresh_overview()

	# 右栏：快速入口
	UI.section(_right_box, "项目", UI.MOD_OVERVIEW)
	var rows := [
		["角色", "%d 个" % balance.get("chars", {}).size()],
		["怪物", "%d 种" % balance.get("enemies", {}).size()],
		["物品 / 装备", "%d / %d" % [balance.get("items", {}).size(), balance.get("equipment", {}).size()]],
		["技能", "%d 个" % balance.get("skills", {}).size()],
		["楼层总数", str(balance.get("max_floor", "?"))],
		["事件", "%d 个" % (map_data.get("events", []) as Array).size()],
	]
	for r in rows:
		var h := UI.hbox(_right_box, 10)
		var l := UI.label(h, str(r[0]), 13, UI.DIM)
		l.custom_minimum_size.x = 96
		UI.mono_label(h, str(r[1]), 13, UI.TEXT)
	UI.hsep(_right_box)
	var errs: Array = []
	for pair in [["balance", balance], ["map", map_data]]:
		var e := Store.validate(str(pair[0]), pair[1])
		if e != "":
			errs.append("【%s】%s" % [pair[0], e])
	if (map_data.get("events", []) as Array).is_empty():
		errs.append("事件表为空：游戏里不会有任何剧情触发（不致命）")
	UI.section(_right_box, "完整性检查", UI.OK)
	if errs.is_empty():
		UI.label(_right_box, "· 结构完整，必需字段齐全", 13, UI.OK)
	else:
		for e2 in errs:
			var fatal := str(e2).find("不致命") < 0
			UI.label(_right_box, "· " + str(e2), 13, UI.ERR if fatal else UI.WARN)
	UI.hsep(_right_box)
	UI.section(_right_box, "去…", UI.MOD_NUMBERS)
	var q := UI.vbox(_right_box, 6)
	UI.button(q, "改数值参数", _goto.bind("param", "", -1), 140)
	UI.button(q, "写事件", _goto.bind("event", "", 0), 140)
	UI.button(q, "看地牢", _goto.bind("floor", "", 1), 140)
	UI.button(q, "画场景", _goto.bind("scene", "scene001", -1), 140)
	UI.hint(_right_box, "数据源：" + Store.BALANCE_PATH + " ／ " + Store.MAP_PATH)


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
	UI.hint(_ov_body, "在左侧树里选任何条目：中央出预览，右栏出属性。")
	UI.hsep(_ov_body)
	UI.section(_ov_body, "怎么用", UI.MOD_NUMBERS)
	for tip in [
		"数据库：左栏选实体，右栏改字段，中央实时预览。",
		"数值：左栏选参数组，右栏直接改；保存后游戏内热重载。",
		"事件：节点画布 + 底部命令列表，双视图同一份数据。",
		"关卡：调层号与种子看地牢形态；场景页画手工图块。",
	]:
		UI.hint(_ov_body, "· " + str(tip))


func _entity_of(kind: String, id: String) -> Dictionary:
	if kind == "boss":
		return balance.get("boss", {}) if balance.get("boss") is Dictionary else {}
	for c in CATS:
		if str(c[0]) == kind:
			var table: Dictionary = balance.get(str(c[2]), {})
			return table.get(id, {}) if table.get(id) is Dictionary else {}
	return {}


func _fill_entity() -> void:
	var kind := str(_sel.get("kind", ""))
	var id := str(_sel.get("id", ""))
	var ent := _entity_of(kind, id)
	if ent.is_empty():
		var hint := UI.label(_center, "没有这个条目。", 14, UI.WARN)
		hint.set_anchors_preset(Control.PRESET_CENTER)
		return

	# —— 中央：预览卡 ——
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_center.add_child(sc)
	DbPreview.build(sc, kind, id, ent)

	# —— 右栏：属性 ——
	var top := UI.hbox(_right_box, 8)
	UI.label(top, str(KIND_ZH.get(kind, kind)), 15, UI.TEXT)
	UI.id_chip(top, id)

	# 基础
	var base := UI.inspector_section(_right_box, "基础设置", UI.MOD_DATABASE)
	var nm := LineEdit.new()
	nm.text = str(ent.get("name", ""))
	nm.text_changed.connect(func(t):
		ent["name"] = t
		_mark_dirty()
		_touch_preview()
	)
	base.add_child(nm)
	if ent.has("title"):
		UI.editor_for(base, "title", ent["title"], _ent_set.bind(ent, "title"))
	if ent.has("desc"):
		UI.editor_for(base, "desc", ent["desc"], _ent_set.bind(ent, "desc"))

	# 图片（角色/怪物/首领）
	var spr: Variant = ent.get("sprite", null)
	if spr is Array and (spr as Array).size() >= 3:
		var sec := UI.inspector_section(_right_box, "图片", UI.MOD_TILES)
		var sv := SpriteView.new()
		sv.custom_minimum_size = Vector2(0, 120)
		sv.set_sprite(str(spr[0]), int(spr[1]), int(spr[2]))
		sec.add_child(sv)
		# 先建 picker 再建按钮：闭包只能捕获**已声明**的局部变量
		var picker_sc := ScrollContainer.new()
		picker_sc.custom_minimum_size = Vector2(0, 190)
		picker_sc.visible = false
		sec.add_child(picker_sc)
		var picker := SpriteView.new()
		picker.mode = "picker"
		picker.set_sprite(str(spr[0]), int(spr[1]), int(spr[2]))
		picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		picker_sc.add_child(picker)
		var pick_btn := Button.new()
		pick_btn.text = "展开精灵表"
		pick_btn.pressed.connect(func():
			picker_sc.visible = not picker_sc.visible
			pick_btn.text = "收起精灵表" if picker_sc.visible else "展开精灵表"
		)
		sec.add_child(pick_btn)
		picker.picked.connect(func(file: String, x: int, y: int):
			ent["sprite"] = [file, x, y]
			sv.set_sprite(file, x, y)
			_mark_dirty()
			_touch_preview()
			_set_status("已设置图片：%s @ (%d, %d)" % [str(file).get_file(), x, y], LV_OK)
		)

	# 其余字段：标量归「属性」，字典/数组各自成组
	var rest := UI.inspector_section(_right_box, "属性", UI.MOD_NUMBERS)
	var dbkind := kind
	for c in CATS:
		if str(c[0]) == kind:
			dbkind = str(c[2])
	var ordered: Array = DbPreview.ORDER.get(dbkind, [])
	var done := {"name": true, "sprite": true, "title": true, "desc": true}
	for k in ordered:
		if not ent.has(str(k)) or done.has(str(k)):
			continue
		done[str(k)] = true
		_ent_field(rest, ent, str(k))
	for k in ent.keys():
		if done.has(str(k)):
			continue
		done[str(k)] = true
		_ent_field(rest, ent, str(k))


func _ent_field(parent: Node, ent: Dictionary, k: String) -> void:
	var v = ent[k]
	if v is Dictionary:
		var sec := UI.inspector_section(parent, UI.pretty(k), UI.MOD_EVENTS)
		for sk in (v as Dictionary).keys():
			UI.editor_for(sec, str(sk), v[sk], _ent_sub_set.bind(v, str(sk)))
	else:
		UI.editor_for(parent, k, v, _ent_set.bind(ent, k))


func _ent_set(nv: Variant, container: Dictionary, key: String) -> void:
	container[key] = nv
	_mark_dirty()
	_touch_preview()


func _ent_sub_set(nv: Variant, container: Dictionary, key: String) -> void:
	container[key] = nv
	_mark_dirty()


## 中央预览延迟刷新：右栏每次改动后把中央卡片重建一遍（合帧，不抢焦点）
func _touch_preview() -> void:
	if _preview_pending:
		return
	_preview_pending = true
	_refresh_preview.call_deferred()


func _refresh_preview() -> void:
	_preview_pending = false
	if str(_sel.get("kind", "")) in ENTITY_KINDS:
		_center_clear()
		_fill_entity()


func _fill_param() -> void:
	var key := str(_sel.get("id", ""))
	var v = balance.get(key, null)
	# —— 中央：只读摘要 ——
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_center.add_child(sc)
	DbPreview.params_table(sc, key, v)
	# —— 右栏：编辑表单 ——
	UI.label(_right_box, UI.pretty(key), 16, UI.TEXT)
	UI.mono_label(_right_box, key, 11, UI.DIM)
	UI.hsep(_right_box)
	if v == null:
		UI.hint(_right_box, "这一组是空的。")
		return
	_sub_form(_right_box, key, v)
	UI.hint(_right_box, "全部来自 balance.json，保存即热重载。")


func _fill_floor() -> void:
	_center.add_child(_dv)
	_apply_level()
	# —— 右栏 ——
	UI.section(_right_box, "地牢参数", UI.MOD_LEVEL)
	UI.hint(_right_box, "只做预览与调参，不改生成算法。同一颗种子永远生成同一张图。")
	var fh := UI.hbox(_right_box, 6)
	UI.label(fh, "层号", 13, UI.DIM)
	var fs := SpinBox.new()
	fs.min_value = 1
	fs.max_value = 9
	fs.value = _lv_floor
	fs.custom_minimum_size.x = 92
	fs.value_changed.connect(func(v):
		_lv_floor = int(v)
		_apply_level()
	)
	fh.add_child(fs)
	var sh := UI.hbox(_right_box, 6)
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
	UI.button(_right_box, "换一张", func():
		_lv_seed = randi() % 1000000
		_apply_level()
	)
	UI.hsep(_right_box)
	UI.hint(_right_box, "把满意的种子填进「数值 → 全局 → 地牢种子」即可在游戏里复现。")
	_lv_info = UI.label(_right_box, "", 12, UI.DIM)
	_lv_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func _apply_level() -> void:
	if _dv == null:
		return
	var total := int(balance.get("max_floor", 5))
	_dv.rebuild(_lv_floor, _lv_seed)
	if is_instance_valid(_lv_info):
		_lv_info.text = "第 %d 层 / 共 %d 层　种子 %d" % [_dv.floor_no, total, _lv_seed]
		if _dv.floor_no >= total:
			_lv_info.text += "\n（最后一层：按设计生成首领单间）"


func _fill_scene() -> void:
	_center.add_child(_tiles.canvas_area)
	_right_box.add_child(_tiles.props_panel)
	_tiles.reset_view.call_deferred()


func _fill_event() -> void:
	var n := (map_data.get("events", []) as Array).size()
	if n == 0:
		UI.label(_center, "还没有事件——在底部事件条点「＋ 新建」开始。", 14, UI.DIM)
		return
	# 树节点带事件索引：路由进来先对齐选择，再挂画布、填右栏
	var idx := clampi(int(_sel.get("idx", 0)), 0, n - 1)
	if _ev.cur_event != idx or _ev.sel_path.is_empty():
		_ev.select_event(idx)
	_center.add_child(_ev.flow_canvas())
	_ev.build_inspector(_right_box)


# ———————— 数值表单（沿用旧版：类型递归 → 控件） ————————

func _num_top_keys() -> Array:
	var out: Array = []
	for k in balance.keys():
		var ks := str(k)
		if ks in ["chars", "enemies", "items", "equipment", "skills", "quests", "boss", "char_skills", "apc_units", "party", "equip_slots", "shop_stock", "floor_pools"]:
			continue
		out.append(ks)
	out.sort()
	return out


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
	_ev.setup(map_data.get("events", []), balance)
	_rebuild_tree()
	_route(_sel)


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


# ———————— 键盘 ————————

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.ctrl_pressed:
		var k := (event as InputEventKey).keycode
		if k == KEY_S:
			if str(_sel.get("kind", "")) == "scene":
				_tiles.save_scene()
			else:
				_save()
			get_viewport().set_input_as_handled()
		elif k == KEY_Z:
			if str(_sel.get("kind", "")) == "scene":
				_tiles.handle_key(KEY_Z, event.shift_pressed)
				get_viewport().set_input_as_handled()
			else:
				_set_status("撤销/重做只作用于场景页的绘制", LV_INFO)
