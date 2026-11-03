extends Control
## 「千亿魔女」战旗编辑器（类 RPG Maker 风格）。
## 左侧画布：左键绘制 / 放置 / 拖拽，右键擦除（地形擦成草原；山按 2x2 整块擦除）。
## 右侧面板：地形笔刷 / 单位放置 / 事件（触发器+命令）/ 地图设置。
## 保存到 res://data/maps/map001.json，「试玩」保存后直接进入战斗。

const MAP_PATH := SrpgMapLoader.PATH
const TILE := SrpgData.TILE

enum EdTool { TERRAIN, UNIT, ZONE, SPAWN }

# —— 地图数据 ——
var map_name := "新地图"
var gw := 20
var gh := 14
var grid := []            # grid[x][y] -> SrpgData.Terrain
var placements := []      # [{uid: String, tpl: String, cell: Vector2i}]
var events := []          # [{name, trigger, once, condition, commands}]
var win_cond := {"type": "rout", "uid": ""}

# —— 工具状态 ——
var cur_tool := EdTool.TERRAIN
var brush := SrpgData.Terrain.FOREST
var unit_tpl := "sword"
var painting := false
var erasing := false
var dragging_unit := -1
var editing_event := -1
var editing_spawn_cmd := {}          # 正在点选增援格子的命令
var zone_drag_start := Vector2i(-1, -1)
var uid_counter := 1

var hover := Vector2i(-1, -1)
var canvas: MapCanvas
var status: Label

# —— UI ——
var pages := {}
var terrain_buttons := {}
var event_list_box: VBoxContainer
var event_canvas
var event_props: VBoxContainer
var _sel_path: Array = []      # 选中节点在命令树中的路径（[] = 触发器）
var ai_tpl := "imp"
var ai_canvas
var ai_params: VBoxContainer
var sys_grid: GridContainer
var map_name_edit: LineEdit
var w_spin: SpinBox
var h_spin: SpinBox
var win_option: OptionButton
var boss_option: OptionButton
var boss_row: HBoxContainer
var tex_cache := {}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "sans-serif"])
	var t := Theme.new()
	t.default_font = font
	t.default_font_size = 14
	theme = t

	_load()
	_build_ui()
	_refresh_all()
	_update_status()


# ———————— 数据 ————————

func apply_dict(d: Dictionary) -> void:
	map_name = str(d.get("name", "新地图"))
	gw = clampi(int(d.get("width", 20)), 8, 40)
	gh = clampi(int(d.get("height", 14)), 8, 30)
	grid = []
	for x in gw:
		var col := []
		col.resize(gh)
		col.fill(SrpgData.Terrain.GRASS)
		grid.append(col)
	var rows: Array = d.get("rows", [])
	for y in gh:
		if y >= rows.size():
			break
		var row: String = rows[y]
		for x in gw:
			if x >= row.length():
				break
			grid[x][y] = SrpgMapLoader.CHARS.get(row[x], SrpgData.Terrain.GRASS)
	placements = []
	for p in d.get("placements", []):
		placements.append({
			"uid": str(p.get("uid", "")),
			"tpl": str(p.get("tpl", "sword")),
			"cell": Vector2i(int(p["cell"][0]), int(p["cell"][1])),
		})
	_fix_uid_counter()
	events = []
	for e in d.get("events", []):
		var ev: Dictionary = e
		if not ev.has("name"):
			ev["name"] = "事件"
		if not ev.has("trigger") or not (ev["trigger"] is Dictionary):
			ev["trigger"] = {"type": "turn_start", "turn": 1, "phase": "player"}
		if not ev.has("commands") or not (ev["commands"] is Array):
			ev["commands"] = []
		if not ev.has("condition") or not (ev["condition"] is Dictionary):
			ev["condition"] = {}
		events.append(ev)
	win_cond = d.get("win", {"type": "rout", "uid": ""})
	editing_event = -1
	_sel_path = []
	dragging_unit = -1


func _fix_uid_counter() -> void:
	uid_counter = 1
	for p in placements:
		var s := str(p["uid"])
		if s.begins_with("u") and s.substr(1).is_valid_int():
			uid_counter = maxi(uid_counter, int(s.substr(1)) + 1)


func build_dict() -> Dictionary:
	var rows := []
	for y in gh:
		var row := ""
		for x in gw:
			row += SrpgMapLoader.terrain_char(grid[x][y])
		rows.append(row)
	var pls := []
	for p in placements:
		pls.append({"uid": p["uid"], "tpl": p["tpl"], "cell": [p["cell"].x, p["cell"].y]})
	return {
		"name": map_name, "width": gw, "height": gh, "rows": rows,
		"win": win_cond, "placements": pls, "events": events,
	}


func _save() -> void:
	if SrpgMapLoader.save_file(MAP_PATH, build_dict()):
		_set_status("已保存到 " + MAP_PATH)
	else:
		_set_status("保存失败！")


func _load() -> void:
	var d := SrpgMapLoader.load_file(MAP_PATH)
	if d.is_empty():
		d = SrpgMapLoader.default_map_dict()
	apply_dict(d)


func _test_play() -> void:
	_save()
	get_tree().change_scene_to_file("res://srpg/main.tscn")


# ———————— UI 构建 ————————

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# 顶栏
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	root.add_child(top)
	var title := Label.new()
	title.text = "「千亿魔女」战旗编辑器"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(1, 0.95, 0.8))
	top.add_child(title)
	var group := ButtonGroup.new()
	for pname in ["地形", "单位", "事件", "AI 状态机", "系统数值", "地图"]:
		var b := Button.new()
		b.text = pname
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = pname == "地形"
		b.pressed.connect(_switch_page.bind(pname))
		top.add_child(b)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	var load_btn := Button.new()
	load_btn.text = "重新载入"
	load_btn.pressed.connect(func():
		_load()
		_refresh_all()
		_set_status("已重新载入 " + MAP_PATH))
	top.add_child(load_btn)
	var save_btn := Button.new()
	save_btn.text = "保存"
	save_btn.pressed.connect(_save)
	top.add_child(save_btn)
	var play_btn := Button.new()
	play_btn.text = "▶ 试玩"
	play_btn.pressed.connect(_test_play)
	top.add_child(play_btn)

	# 主体：画布 + 右侧面板
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 8)
	root.add_child(split)

	canvas = MapCanvas.new()
	canvas.ed = self
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(canvas)

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(380, 0)
	right.add_theme_constant_override("separation", 8)
	split.add_child(right)

	right.add_child(_make_terrain_page())
	right.add_child(_make_unit_page())
	right.add_child(_make_event_page())
	right.add_child(_make_map_page())
	_switch_page("地形")

	# 状态栏
	status = Label.new()
	status.add_theme_color_override("font_color", Color(0.85, 0.9, 1, 0.85))
	root.add_child(status)


func _page_box(title_text: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	var l := Label.new()
	l.text = "— " + title_text + " —"
	l.add_theme_color_override("font_color", Color(1, 0.95, 0.75))
	v.add_child(l)
	pages[title_text] = v
	return v


func _make_terrain_page() -> Control:
	var v := _page_box("地形")
	var hint := _lbl("左键涂刷（可拖动），右键擦成草原；山按 2x2 整块放置/擦除")
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	v.add_child(hint)
	var grid_box := GridContainer.new()
	grid_box.columns = 3
	grid_box.add_theme_constant_override("h_separation", 6)
	v.add_child(grid_box)
	var defs := [
		[SrpgData.Terrain.GRASS, "草原"], [SrpgData.Terrain.DIRT, "荒地"],
		[SrpgData.Terrain.FOREST, "森林"], [SrpgData.Terrain.MOUNTAIN, "山（2x2）"],
		[SrpgData.Terrain.WATER, "深水"],
	]
	for d in defs:
		var b := Button.new()
		b.text = d[1]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(110, 30)
		b.pressed.connect(func():
			brush = d[0]
			cur_tool = EdTool.TERRAIN
			_refresh_terrain_buttons()
			_update_status())
		terrain_buttons[d[0]] = b
		grid_box.add_child(b)
	return v


func _make_unit_page() -> Control:
	var v := _page_box("单位")
	var hint := _lbl("选模板后左键放置；按住已放置单位可拖动；右键删除。山上/水里不能放。")
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	v.add_child(hint)
	for tpl_id in SrpgData.UNITS:
		var tpl: Dictionary = SrpgData.UNITS[tpl_id]
		var b := Button.new()
		var tag := "我方" if tpl["faction"] == "player" else "敌方"
		b.text = "%s（%s）" % [tpl["name"], tag]
		b.custom_minimum_size = Vector2(200, 30)
		b.pressed.connect(func():
			unit_tpl = tpl_id
			cur_tool = EdTool.UNIT
			_update_status())
		v.add_child(b)
	return v


func _make_event_page() -> Control:
	var v := _page_box("事件")
	v.custom_minimum_size = Vector2(560, 0)
	var top := HBoxContainer.new()
	v.add_child(top)
	var add_btn := Button.new()
	add_btn.text = "＋ 新建事件"
	add_btn.pressed.connect(_add_event)
	top.add_child(add_btn)
	var del_btn := Button.new()
	del_btn.text = "删除选中"
	del_btn.pressed.connect(_delete_event)
	top.add_child(del_btn)
	top.add_child(ed_event_note())
	event_list_box = VBoxContainer.new()
	event_list_box.add_theme_constant_override("separation", 4)
	v.add_child(event_list_box)
	v.add_child(HSeparator.new())
	# 节点画布（流程可视化）+ 属性面板（选中节点的字段）
	var flow := VBoxContainer.new()
	flow.add_theme_constant_override("separation", 6)
	v.add_child(flow)
	var cscroll := ScrollContainer.new()
	cscroll.custom_minimum_size = Vector2(520, 240)
	cscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	flow.add_child(cscroll)
	event_canvas = EditorAdvancedTabs.EditorEventCanvas.new()
	event_canvas.ed = self
	cscroll.add_child(event_canvas)
	var pscroll := ScrollContainer.new()
	pscroll.custom_minimum_size = Vector2(520, 240)
	pscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	flow.add_child(pscroll)
	event_props = VBoxContainer.new()
	event_props.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	event_props.add_theme_constant_override("separation", 6)
	pscroll.add_child(event_props)
	return v


func ed_event_note() -> Control:
	var l := _lbl("点节点→右侧改属性；「是/否」= 条件分支")
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	return l


func _make_map_page() -> Control:
	var v := _page_box("地图")
	var nrow := HBoxContainer.new()
	v.add_child(nrow)
	nrow.add_child(_lbl("地图名"))
	map_name_edit = LineEdit.new()
	map_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_name_edit.text_changed.connect(func(s): map_name = s)
	nrow.add_child(map_name_edit)

	var srow := HBoxContainer.new()
	v.add_child(srow)
	srow.add_child(_lbl("宽"))
	w_spin = SpinBox.new()
	w_spin.min_value = 8
	w_spin.max_value = 40
	w_spin.custom_minimum_size = Vector2(70, 0)
	w_spin.value_changed.connect(func(val): _resize(int(val), gh))
	srow.add_child(w_spin)
	srow.add_child(_lbl("高"))
	h_spin = SpinBox.new()
	h_spin.min_value = 8
	h_spin.max_value = 30
	h_spin.custom_minimum_size = Vector2(70, 0)
	h_spin.value_changed.connect(func(val): _resize(gw, int(val)))
	srow.add_child(h_spin)

	var wrow := HBoxContainer.new()
	v.add_child(wrow)
	wrow.add_child(_lbl("胜利条件"))
	win_option = OptionButton.new()
	win_option.add_item("歼灭全部敌人")
	win_option.add_item("击败头目（指定单位）")
	win_option.item_selected.connect(func(i):
		win_cond["type"] = "rout" if i == 0 else "boss"
		boss_row.visible = i == 1)
	wrow.add_child(win_option)
	boss_row = HBoxContainer.new()
	v.add_child(boss_row)
	boss_row.add_child(_lbl("头目"))
	boss_option = OptionButton.new()
	boss_option.item_selected.connect(func(i): win_cond["uid"] = boss_option.get_item_metadata(i))
	boss_row.add_child(boss_option)
	boss_row.visible = false
	return v


func _lbl(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func tool_is_zone() -> bool:
	return cur_tool == EdTool.ZONE


func tool_is_spawn() -> bool:
	return cur_tool == EdTool.SPAWN


func _switch_page(pname: String) -> void:
	for key in pages:
		pages[key].visible = key == pname
	if pname == "地图":
		_refresh_map_page()


# ———————— 刷新 ————————

func _refresh_all() -> void:
	_refresh_terrain_buttons()
	_refresh_event_list()
	refresh_event_canvas()
	_refresh_map_page()
	EditorAdvancedTabs.refresh_ai_page(self)
	EditorAdvancedTabs.refresh_systems(self)
	if canvas != null:
		canvas.queue_redraw()


func _refresh_terrain_buttons() -> void:
	for t in terrain_buttons:
		terrain_buttons[t].button_pressed = (t == brush and cur_tool == EdTool.TERRAIN)


func _refresh_map_page() -> void:
	if map_name_edit == null:
		return
	map_name_edit.text = map_name
	w_spin.value = gw
	h_spin.value = gh
	win_option.selected = 0 if str(win_cond.get("type", "rout")) == "rout" else 1
	boss_row.visible = str(win_cond.get("type", "")) == "boss"
	boss_option.clear()
	var sel := -1
	for p in placements:
		if str(SrpgData.UNITS.get(p["tpl"], {}).get("faction", "")) != "enemy":
			continue
		boss_option.add_item("%s · %s" % [p["uid"], SrpgData.UNITS[p["tpl"]]["name"]])
		boss_option.set_item_metadata(boss_option.item_count - 1, p["uid"])
		if p["uid"] == str(win_cond.get("uid", "")):
			sel = boss_option.item_count - 1
	if sel >= 0:
		boss_option.select(sel)


# ———————— 事件编辑 ————————

func _add_event() -> void:
	events.append({
		"name": "新事件",
		"trigger": {"type": "turn_start", "turn": 1, "phase": "player"},
		"once": true, "condition": {}, "commands": [],
	})
	editing_event = events.size() - 1
	_sel_path = []
	_refresh_event_list()
	refresh_event_canvas()


func _delete_event() -> void:
	if editing_event < 0 or editing_event >= events.size():
		return
	events.remove_at(editing_event)
	editing_event = -1
	_sel_path = []
	_refresh_event_list()
	refresh_event_canvas()


func _refresh_event_list() -> void:
	for c in event_list_box.get_children():
		c.queue_free()
	for i in events.size():
		var b := Button.new()
		b.text = "%d. %s（%s）" % [i + 1, events[i].get("name", "?"), _trigger_desc(events[i])]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		if i == editing_event:
			b.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
		b.pressed.connect(_select_event.bind(i))
		event_list_box.add_child(b)


func _select_event(i: int) -> void:
	editing_event = i
	_sel_path = []
	_refresh_event_list()
	refresh_event_canvas()


func refresh_event_canvas() -> void:
	if event_canvas != null:
		event_canvas.custom_minimum_size = Vector2.ZERO
		event_canvas.queue_redraw()
	EditorAdvancedTabs.build_event_props(self)


func _trigger_desc(ev: Dictionary) -> String:
	var t: Dictionary = ev.get("trigger", {})
	match str(t.get("type", "")):
		"turn_start":
			return "第%d回合·%s" % [int(t.get("turn", 1)), _phase_name(str(t.get("phase", "any")))]
		"unit_death":
			return "死亡:%s" % str(t.get("unit", "任意"))
		"zone":
			var r: Array = t.get("rect", [0, 0, 0, 0])
			return "进入(%d,%d)+%dx%d" % [r[0], r[1], r[2], r[3]]
	return "?"


func _phase_name(ph: String) -> String:
	return {"player": "玩家", "enemy": "敌方", "any": "任意"}.get(ph, ph)


func canvas_input(cv: MapCanvas, ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		hover = cv.cell_from_local(ev.position)
		if painting:
			_paint_stroke(hover)
		cv.queue_redraw()
		_update_status()
	elif ev is InputEventMouseButton and ev.pressed:
		var c := cv.cell_from_local(ev.position)
		if ev.button_index == MOUSE_BUTTON_LEFT:
			_canvas_left(c)
		elif ev.button_index == MOUSE_BUTTON_RIGHT:
			_canvas_right(c)
		cv.queue_redraw()
		_update_status()
	elif ev is InputEventMouseButton and not ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		painting = false
		erasing = false
		var c2 := cv.cell_from_local(ev.position)
		if dragging_unit >= 0:
			_drop_unit(c2)
		if cur_tool == EdTool.ZONE and zone_drag_start.x >= 0:
			_finish_zone(c2)
		cv.queue_redraw()


func _canvas_left(c: Vector2i) -> void:
	if not _in_bounds(c):
		if cur_tool == EdTool.ZONE:
			zone_drag_start = Vector2i(-1, -1)
		return
	match cur_tool:
		EdTool.TERRAIN:
			painting = true
			erasing = false
			_paint_stroke(c)
		EdTool.UNIT:
			var idx := _unit_at(c)
			if idx >= 0:
				dragging_unit = idx
			else:
				_place_unit(unit_tpl, c)
		EdTool.ZONE:
			zone_drag_start = c
		EdTool.SPAWN:
			if not editing_spawn_cmd.is_empty():
				var cells: Array = editing_spawn_cmd.get("cells", [])
				var found := false
				for cc in cells:
					if cc[0] == c.x and cc[1] == c.y:
						cells.erase(cc)
						found = true
						break
				if not found:
					cells.append([c.x, c.y])
				EditorAdvancedTabs.build_event_props(self)


func _canvas_right(c: Vector2i) -> void:
	if not _in_bounds(c):
		return
	if cur_tool == EdTool.UNIT:
		var idx := _unit_at(c)
		if idx >= 0:
			placements.remove_at(idx)
			if dragging_unit == idx:
				dragging_unit = -1
			_refresh_map_page()
			return
		return
	painting = true
	erasing = true
	_paint_stroke(c)


## 一次涂刷：笔刷 / 擦除（山按 2x2 整块处理）
func _paint_stroke(c: Vector2i) -> void:
	if not _in_bounds(c):
		return
	if erasing:
		if grid[c.x][c.y] == SrpgData.Terrain.MOUNTAIN:
			_erase_mountain(c)
		else:
			grid[c.x][c.y] = SrpgData.Terrain.GRASS
	elif brush == SrpgData.Terrain.MOUNTAIN:
		for dx in 2:
			for dy in 2:
				var cc := c + Vector2i(dx, dy)
				if _in_bounds(cc):
					grid[cc.x][cc.y] = SrpgData.Terrain.MOUNTAIN
	else:
		grid[c.x][c.y] = brush


## 把点击处的 2x2 山块（含其左上方向邻居）擦成草原
func _erase_mountain(c: Vector2i) -> void:
	for dx in [-1, 0]:
		for dy in [-1, 0]:
			var cc := c + Vector2i(dx, dy)
			if _in_bounds(cc) and grid[cc.x][cc.y] == SrpgData.Terrain.MOUNTAIN:
				grid[cc.x][cc.y] = SrpgData.Terrain.GRASS


func _in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < gw and c.y < gh


func _unit_at(c: Vector2i) -> int:
	for i in placements.size():
		if placements[i]["cell"] == c:
			return i
	return -1


func _cell_walkable(c: Vector2i) -> bool:
	return _in_bounds(c) and int(SrpgData.TERRAIN[grid[c.x][c.y]]["cost"]) <= 90


func _place_unit(tpl_id: String, c: Vector2i) -> void:
	if not _cell_walkable(c):
		_set_status("山上 / 水里不能放单位")
		return
	if _unit_at(c) >= 0:
		return
	placements.append({"uid": "u%d" % uid_counter, "tpl": tpl_id, "cell": c})
	uid_counter += 1
	_refresh_map_page()


func _drop_unit(c: Vector2i) -> void:
	var idx := dragging_unit
	dragging_unit = -1
	if idx < 0 or idx >= placements.size():
		return
	if not _cell_walkable(c) or (_unit_at(c) >= 0 and c != placements[idx]["cell"]):
		_set_status("不能放到那里")
		return
	placements[idx]["cell"] = c
	_refresh_map_page()


func _finish_zone(end_cell: Vector2i) -> void:
	var s := zone_drag_start
	zone_drag_start = Vector2i(-1, -1)
	if not (_in_bounds(s) and _in_bounds(end_cell)) or editing_event < 0 or editing_event >= events.size():
		return
	var x1 := mini(s.x, end_cell.x)
	var y1 := mini(s.y, end_cell.y)
	var w := absi(s.x - end_cell.x) + 1
	var h := absi(s.y - end_cell.y) + 1
	events[editing_event]["trigger"]["rect"] = [x1, y1, w, h]
	cur_tool = EdTool.TERRAIN
	_refresh_event_list()
	EditorAdvancedTabs.build_event_props(self)
	_set_status("区域已设置")


func _resize(w: int, h: int) -> void:
	w = clampi(w, 8, 40)
	h = clampi(h, 8, 30)
	var ng := []
	for x in w:
		var col := []
		col.resize(h)
		col.fill(SrpgData.Terrain.GRASS)
		for y in mini(h, gh):
			if x < gw:
				col[y] = grid[x][y]
		ng.append(col)
	grid = ng
	gw = w
	gh = h
	placements = placements.filter(func(p): return p["cell"].x < w and p["cell"].y < h)
	if canvas != null:
		canvas.queue_redraw()


func _set_status(s: String) -> void:
	if status != null:
		status.text = s


func _update_status() -> void:
	if status == null:
		return
	var tool_name := "地形"
	if cur_tool == EdTool.UNIT:
		tool_name = "单位"
	elif cur_tool == EdTool.ZONE:
		tool_name = "框选区域"
	elif cur_tool == EdTool.SPAWN:
		tool_name = "选增援格"
	var terr := ""
	if _in_bounds(hover):
		terr = SrpgData.TERRAIN[grid[hover.x][hover.y]]["name"]
	status.text = "工具: %s | 格子 (%d, %d) %s | 单位 %d | 事件 %d" % [
		tool_name, hover.x, hover.y, terr, placements.size(), events.size()]


func tex(path: String) -> Texture2D:
	if not tex_cache.has(path):
		tex_cache[path] = load(path)
	return tex_cache[path]


# ———————— 画布控件 ————————

class MapCanvas extends Control:
	var ed

	func _gui_input(ev: InputEvent) -> void:
		ed.canvas_input(self, ev)

	func _map_px() -> Vector2:
		return Vector2(ed.gw, ed.gh) * float(ed.TILE)

	func calc_offset() -> Vector2:
		return Vector2(maxf(8, (size.x - _map_px().x) / 2), maxf(8, (size.y - _map_px().y) / 2))

	func cell_from_local(p: Vector2) -> Vector2i:
		return Vector2i(((p - calc_offset()) / float(ed.TILE)).floor())

	func cell_center(c: Vector2i) -> Vector2:
		return calc_offset() + Vector2(c) * float(ed.TILE) + Vector2.ONE * (ed.TILE * 0.5)

	func cell_rect(c: Vector2i) -> Rect2:
		return Rect2(calc_offset() + Vector2(c) * float(ed.TILE), Vector2.ONE * ed.TILE)

	func _draw() -> void:
		if ed.grid.is_empty():
			return
		# 地面
		for x in ed.gw:
			for y in ed.gh:
				var c := Vector2i(x, y)
				var r := cell_rect(c)
				var t: int = ed.grid[x][y]
				if t == SrpgData.Terrain.WATER:
					draw_texture_rect_region(SrpgBattleMap.TEX_WATER, r, SrpgBattleMap.SRC_WATER)
				else:
					draw_texture_rect_region(SrpgBattleMap.TEX_GROUND, r, SrpgBattleMap.SRC_GRASS)
				if t == SrpgData.Terrain.DIRT:
					draw_texture_rect_region(SrpgBattleMap.TEX_GROUND, r, SrpgBattleMap.SRC_DIRT)
				elif t == SrpgData.Terrain.FOREST:
					var fi: int = (x % 2) + (y % 2) * 2
					draw_texture_rect_region(SrpgBattleMap.TEX_GROUND, r, SrpgBattleMap.SRC_FOREST[fi])
		for m in SrpgMapLoader.mountain_anchors_from(ed.grid, ed.gw, ed.gh):
			draw_texture_rect_region(SrpgBattleMap.TEX_OVERWORLD,
				Rect2(calc_offset() + Vector2(m) * float(ed.TILE), Vector2(64, 64)), SrpgBattleMap.SRC_MOUNTAIN)
		# 网格线
		var line_col := Color(0, 0, 0, 0.14)
		for x in ed.gw + 1:
			var px: float = calc_offset().x + x * float(ed.TILE)
			draw_line(Vector2(px, calc_offset().y), Vector2(px, calc_offset().y + ed.gh * float(ed.TILE)), line_col, 1.0)
		for y in ed.gh + 1:
			var py: float = calc_offset().y + y * float(ed.TILE)
			draw_line(Vector2(calc_offset().x, py), Vector2(calc_offset().x + ed.gw * float(ed.TILE), py), line_col, 1.0)
		# 事件区域预览
		if ed.tool_is_zone():
			var rect := Rect2()
			if ed.zone_drag_start.x >= 0 and ed._in_bounds(ed.hover):
				var tl := Vector2(mini(ed.zone_drag_start.x, ed.hover.x), mini(ed.zone_drag_start.y, ed.hover.y))
				var br := Vector2(maxi(ed.zone_drag_start.x, ed.hover.x), maxi(ed.zone_drag_start.y, ed.hover.y))
				rect = Rect2(calc_offset() + tl * float(ed.TILE), (br - tl) * float(ed.TILE) + Vector2.ONE * ed.TILE)
			elif ed.editing_event >= 0 and ed.editing_event < ed.events.size():
				var r: Array = ed.events[ed.editing_event].get("trigger", {}).get("rect", [])
				if r.size() == 4:
					rect = Rect2(calc_offset() + Vector2(r[0], r[1]) * float(ed.TILE), Vector2(r[2], r[3]) * float(ed.TILE))
			if rect.size.x > 0:
				draw_rect(rect, Color(0.4, 1, 0.55, 0.22), true)
				draw_rect(rect, Color(0.4, 1, 0.55, 0.9), false, 2.0)
		# 增援格子预览
		if ed.tool_is_spawn() and not ed.editing_spawn_cmd.is_empty():
			for cc in ed.editing_spawn_cmd.get("cells", []):
				draw_rect(cell_rect(Vector2i(cc[0], cc[1])), Color(1, 0.7, 0.2, 0.35), true)
				draw_rect(cell_rect(Vector2i(cc[0], cc[1])), Color(1, 0.8, 0.3, 0.9), false, 2.0)
		# 单位
		for i in ed.placements.size():
			var p: Dictionary = ed.placements[i]
			var tpl: Dictionary = SrpgData.UNITS.get(p["tpl"], {})
			if tpl.is_empty():
				continue
			var t: Texture2D = ed.tex(tpl["sprite"][0])
			var b: Vector2i = Vector2i(tpl["sprite"][1], tpl["sprite"][2])
			var pos := cell_center(p["cell"])
			draw_texture_rect_region(t, Rect2(pos + Vector2(-24, -29), Vector2(48, 48)), Rect2(b.x, b.y, 48, 48))
			if i == ed.dragging_unit:
				draw_arc(pos, 13.0, 0, TAU, 40, Color(1, 0.95, 0.5, 0.95), 2.5)
		# 拖拽幽灵
		if ed.dragging_unit >= 0 and ed._in_bounds(ed.hover):
			var p2: Dictionary = ed.placements[ed.dragging_unit]
			var tpl2: Dictionary = SrpgData.UNITS.get(p2["tpl"], {})
			if not tpl2.is_empty():
				var t2: Texture2D = ed.tex(tpl2["sprite"][0])
				var b2: Vector2i = Vector2i(tpl2["sprite"][1], tpl2["sprite"][2])
				draw_texture_rect_region(t2, Rect2(cell_center(ed.hover) + Vector2(-24, -29), Vector2(48, 48)),
					Rect2(b2.x, b2.y, 48, 48))
		# 悬停框
		if ed._in_bounds(ed.hover):
			draw_rect(cell_rect(ed.hover), Color(1, 1, 1, 0.8), false, 2.0)
