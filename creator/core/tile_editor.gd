extends HBoxContainer
## 场景编辑器（RPG Maker 式）：图块调色板 + 画布 + 场景/图层属性。
##
## 三条设计决定：
##  1. **图块集用 Image 直接加载，不走导入系统**。这样用户把任意 PNG 丢进
##     `assets/tiles/`（或通过「导入」按钮复制进来）就立刻可用，不用重启编辑器等 `.import` 生成。
##  2. **画布无状态**。所有数据改动都经过本页，因为这里要同时处理撤销栈、脏标记、缩略图刷新。
##  3. **场景是纯数据**（宽高 + 若干图层的 int 数组），与游戏的地牢生成器完全解耦：
##     手搭的场景将来要进游戏，读的也是这份 JSON，不需要任何转换层。

signal dirty()
signal status(msg: String, level: int)

const UI := preload("res://creator/core/ui_kit.gd")
const TileScene := preload("res://creator/core/tile_scene.gd")
const TileCanvas := preload("res://creator/core/tile_canvas.gd")

const TILES_DIR := "res://assets/tiles"
const SCENE_DIR := "res://data/scenes"
const SCENE_FILE := "res://data/scenes/scene001.json"
const UNDO_MAX := 40

var scene = null
var _canvas = null
var _palette = null
var _tileset_opt: OptionButton
var _layer_list: VBoxContainer
var _size_w: SpinBox
var _size_h: SpinBox
var _name_edit: LineEdit
var _status: Label
var _zoom_label: Label
var _brush_label: Label
var _tool_btns: Array = []

var _undo: Array = []
var _redo: Array = []
var _tex_cache := {}
var _tilesets: Array = []
var _cur_tileset := ""


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	scene = TileScene.new()
	scene.setup_default()
	_build_ui()
	_scan_tilesets()
	if _tilesets.size() > 0:
		_load_tileset(str(_tilesets[0]))
	_canvas.fit_view()
	_refresh_layers()


# ———————— 布局 ————————

func _build_ui() -> void:
	# 左：图块集与调色板
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 204
	add_child(left)
	UI.section(left, "图块集", UI.MOD_TILES)
	_tileset_opt = OptionButton.new()
	_tileset_opt.item_selected.connect(func(i):
		if i >= 0 and i < _tilesets.size():
			_load_tileset(str(_tilesets[i]))
	)
	left.add_child(_tileset_opt)
	var imp := UI.hbox(left, 6)
	UI.button(imp, "导入 PNG", _import_tileset, 96)
	UI.button(imp, "刷新", func():
		_scan_tilesets()
		_set_status("已重新扫描 %s，共 %d 个图块集" % [TILES_DIR, _tilesets.size()], 1)
	, 72)
	UI.hint(left, "把 PNG 放进 assets/tiles 即可；点「刷新」立即可用，不用重启。")

	_palette = Palette.new()
	_palette.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_palette.picked.connect(_on_pick)
	left.add_child(_palette)
	_brush_label = UI.mono_label(left, "笔刷：#0", 12, UI.DIM)

	# 中：工具条 + 画布 + 状态条
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(mid)
	var bar := UI.hbox(mid, 6)
	for t in [["画笔", TileCanvas.TOOL_BRUSH], ["橡皮", TileCanvas.TOOL_ERASE], ["填充整层", TileCanvas.TOOL_FILL]]:
		var b := Button.new()
		b.text = str(t[0])
		b.toggle_mode = true
		b.button_pressed = int(t[1]) == TileCanvas.TOOL_BRUSH
		b.pressed.connect(_set_tool.bind(int(t[1])))
		bar.add_child(b)
		_tool_btns.append(b)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(sp)
	UI.button(bar, "适应窗口", func(): _canvas.fit_view(), 96).tooltip_text = "把整张场景缩放到刚好放进画布"
	UI.button(bar, "撤销", _do_undo, 64).tooltip_text = "Ctrl+Z"
	UI.button(bar, "重做", _do_redo, 64).tooltip_text = "Ctrl+Shift+Z"

	_canvas = TileCanvas.new()
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.scene = scene
	_canvas.paint_cell.connect(_on_paint)
	_canvas.fill_layer.connect(_on_fill)
	_canvas.stroke_begin.connect(_push_undo)
	_canvas.hover_changed.connect(_on_hover)
	_canvas.zoom_changed.connect(func(z): _zoom_label.text = "%d%%" % int(z * 100))
	mid.add_child(_canvas)

	var bottom := UI.hbox(mid, 14)
	_status = UI.label(bottom, "滚轮缩放 · 中键拖动 · 右键擦除 · Alt+左键吸管", 12, UI.DIM)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zoom_label = UI.mono_label(bottom, "100%", 12, UI.DIM)

	# 右：场景与图层
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 214
	add_child(right)
	UI.section(right, "场景", UI.MOD_TILES)
	_name_edit = LineEdit.new()
	_name_edit.text = scene.scene_name
	_name_edit.text_changed.connect(func(t):
		scene.scene_name = t
	)
	right.add_child(_name_edit)

	var sz := UI.hbox(right, 6)
	UI.label(sz, "宽", 12, UI.DIM)
	_size_w = SpinBox.new()
	_size_w.min_value = 4
	_size_w.max_value = 256
	_size_w.value = scene.cols
	_size_w.custom_minimum_size.x = 66
	_size_w.value_changed.connect(_on_resize)
	sz.add_child(_size_w)
	UI.label(sz, "高", 12, UI.DIM)
	_size_h = SpinBox.new()
	_size_h.min_value = 4
	_size_h.max_value = 256
	_size_h.value = scene.rows
	_size_h.custom_minimum_size.x = 66
	_size_h.value_changed.connect(_on_resize)
	sz.add_child(_size_h)

	UI.hsep(right)
	UI.section(right, "图层", UI.MOD_TILES)
	var lsc := ScrollContainer.new()
	lsc.custom_minimum_size.y = 130
	right.add_child(lsc)
	_layer_list = UI.vbox(lsc, 3)
	_layer_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var lacts := UI.hbox(right, 6)
	UI.button(lacts, "＋ 图层", func():
		_push_undo()
		scene.add_layer("图层 %d" % (scene.layers.size() + 1))
		_refresh_layers()
		_redraw()
	, 84)
	UI.button(lacts, "删除", func():
		_push_undo()
		scene.remove_layer(scene.cur_layer)
		_refresh_layers()
		_redraw()
	, 60)

	UI.hsep(right)
	UI.section(right, "存档", UI.MOD_TILES)
	UI.button(right, "保存场景", _save, 0).tooltip_text = SCENE_FILE
	UI.button(right, "重新载入", _load, 0)
	UI.button(right, "清空当前层", func():
		_push_undo()
		scene.fill_layer(scene.cur_layer, TileScene.EMPTY)
		_redraw()
	, 0)
	UI.hint(right, "场景以 JSON 存在 data/scenes/，每格记录图块集里的序号。")


# ———————— 图块集 ————————

func _scan_tilesets() -> void:
	_tilesets.clear()
	_tileset_opt.clear()
	var d := DirAccess.open(TILES_DIR)
	if d == null:
		return
	for f in d.get_files():
		if f.to_lower().ends_with(".png"):
			_tilesets.append(TILES_DIR + "/" + f)
	_tilesets.sort()
	for p in _tilesets:
		_tileset_opt.add_item(str(p).get_file())


func _load_tileset(path: String) -> void:
	var img: Image = _img(path)
	if img == null:
		_set_status("图块集读取失败：" + path, 3)
		return
	_cur_tileset = path
	scene.tileset_path = path
	scene.tileset_cols = maxi(1, img.get_width() / scene.tile_size)
	scene.tileset_rows = maxi(1, img.get_height() / scene.tile_size)
	_palette.set_tileset(_tex(path), scene.tile_size, scene.tileset_cols, scene.tileset_rows)
	_canvas.tex = _tex(path)
	_canvas.queue_redraw()
	for i in _tilesets.size():
		if str(_tilesets[i]) == path:
			_tileset_opt.select(i)
	_set_status("%s：%d × %d 格图块" % [path.get_file(), scene.tileset_cols, scene.tileset_rows], 1)


## 用 Image 直接解码，绕开 Godot 的导入流程 —— 用户丢进来的新 PNG 立刻能用
func _img(path: String) -> Image:
	var abs := path if path.begins_with("res://") else ProjectSettings.globalize_path(path)
	var img := Image.new()
	var err := img.load(abs)
	if err != OK:
		return null
	img.convert(Image.FORMAT_RGBA8)
	return img


func _tex(path: String) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	var img := _img(path)
	if img == null:
		return null
	var t := ImageTexture.create_from_image(img)
	_tex_cache[path] = t
	return t


func _import_tileset() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(["*.png ; 图块集"])
	fd.title = "选择要导入的图块集 PNG"
	fd.file_selected.connect(func(p: String):
		var dst: String = TILES_DIR + "/" + p.get_file()
		var err := DirAccess.copy_absolute(p, ProjectSettings.globalize_path(dst))
		if err != OK:
			_set_status("复制失败（错误码 %d）" % err, 3)
			return
		_scan_tilesets()
		_load_tileset(dst)
		_set_status("已导入 %s，立即可用" % p.get_file(), 1)
	)
	add_child(fd)
	fd.popup_centered_ratio(0.6)


# ———————— 绘制 ————————

func _set_tool(t: int) -> void:
	_canvas.tool = t
	for i in _tool_btns.size():
		(_tool_btns[i] as Button).button_pressed = (i == t)
	_set_status({0: "画笔：左键画，右键擦", 1: "橡皮：左键擦除", 2: "填充：点一下填满整层"}.get(t, ""), 0)


## 宿主切到本页时调用：此时容器已算出真实尺寸，适应窗口才有意义
func reset_view() -> void:
	if _canvas != null:
		_canvas.fit_view()


func _on_pick(idx: int) -> void:
	_canvas.brush = idx
	_brush_label.text = "笔刷：#%d" % idx


func _on_paint(x: int, y: int, erase: bool) -> void:
	if erase or _canvas.tool == TileCanvas.TOOL_ERASE:
		scene.set_cell(scene.cur_layer, x, y, TileScene.EMPTY)
	else:
		scene.set_cell(scene.cur_layer, x, y, _canvas.brush)
	_redraw()


func _on_fill(erase: bool) -> void:
	scene.fill_layer(scene.cur_layer, TileScene.EMPTY if erase else _canvas.brush)
	_redraw()


func _on_hover(x: int, y: int) -> void:
	if x < 0 or y < 0:
		return
	var idx: int = scene.get_cell(scene.cur_layer, x, y)
	_set_status("格 (%d, %d)　图块 %s　层「%s」" % [
		x, y, "空" if idx < 0 else "#%d" % idx, str(scene.layers[scene.cur_layer]["name"])], 0)


func _on_resize(_v: float) -> void:
	_push_undo()
	scene.resize(int(_size_w.value), int(_size_h.value))
	_canvas.fit_view()
	_redraw()


func _redraw() -> void:
	_canvas.queue_redraw()
	dirty.emit()


func _set_status(msg: String, level: int) -> void:
	if _status != null:
		_status.text = msg
		_status.add_theme_color_override("font_color",
			[UI.DIM, UI.OK, UI.WARN, UI.ERR][clampi(level, 0, 3)])
	status.emit(msg, level)


# ———————— 图层 ————————

func _refresh_layers() -> void:
	for c in _layer_list.get_children():
		_layer_list.remove_child(c)
		c.queue_free()
	for i in scene.layers.size():
		var L = scene.layers[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_layer_list.add_child(row)
		if i == scene.cur_layer:
			UI.accent_bar(row, UI.ACCENT, 3, 22)
		else:
			UI.accent_bar(row, Color(0, 0, 0, 0), 3, 22)
		var b := Button.new()
		b.text = str(L["name"])
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.flat = i != scene.cur_layer
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_select_layer.bind(i))
		row.add_child(b)
		var eye := Button.new()
		eye.text = "●" if bool(L["visible"]) else "○"
		eye.tooltip_text = "显示/隐藏"
		eye.custom_minimum_size.x = 30
		eye.pressed.connect(func():
			L["visible"] = not bool(L["visible"])
			_refresh_layers()
			_redraw()
		)
		row.add_child(eye)


func _select_layer(i: int) -> void:
	scene.cur_layer = i
	_refresh_layers()


# ———————— 撤销 ————————

func _push_undo() -> void:
	_undo.append(scene.snapshot())
	if _undo.size() > UNDO_MAX:
		_undo.pop_front()
	_redo.clear()


func _do_undo() -> void:
	if _undo.is_empty():
		_set_status("没有可撤销的操作", 2)
		return
	_redo.append(scene.snapshot())
	scene.restore(_undo.pop_back())
	_refresh_layers()
	_redraw()
	_set_status("已撤销", 0)


func _do_redo() -> void:
	if _redo.is_empty():
		_set_status("没有可重做的操作", 2)
		return
	_undo.append(scene.snapshot())
	scene.restore(_redo.pop_back())
	_refresh_layers()
	_redraw()
	_set_status("已重做", 0)


# ———————— 存档 ————————

func _save() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCENE_DIR))
	var f := FileAccess.open(SCENE_FILE, FileAccess.WRITE)
	if f == null:
		_set_status("保存失败（错误码 %d）" % FileAccess.get_open_error(), 3)
		return
	f.store_string(JSON.stringify(scene.to_dict(), "  ", false))
	f.close()
	_set_status("已保存 %s" % SCENE_FILE, 1)


func _load() -> void:
	if not FileAccess.file_exists(SCENE_FILE):
		_set_status("还没有存档：%s" % SCENE_FILE, 2)
		return
	var f := FileAccess.open(SCENE_FILE, FileAccess.READ)
	if f == null:
		_set_status("读取失败", 3)
		return
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if not (d is Dictionary):
		_set_status("存档解析失败", 3)
		return
	scene = TileScene.from_dict(d)
	_canvas.scene = scene
	_name_edit.text = scene.scene_name
	_size_w.set_value_no_signal(scene.cols)
	_size_h.set_value_no_signal(scene.rows)
	if scene.tileset_path != "":
		_load_tileset(scene.tileset_path)
	_refresh_layers()
	_canvas.fit_view()
	_redraw()
	_set_status("已载入 %s" % SCENE_FILE, 1)


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed and event.ctrl_pressed:
		var k := (event as InputEventKey).keycode
		if k == KEY_Z:
			if (event as InputEventKey).shift_pressed:
				_do_redo()
			else:
				_do_undo()
			get_viewport().set_input_as_handled()
		elif k == KEY_S:
			_save()
			get_viewport().set_input_as_handled()


# ———————— 调色板 ————————

## 图块缩略面板：自适应铺满宽度，格子小但可辨认；选中格用强调色描边。
class Palette extends Control:
	signal picked(idx: int)

	var tex: Texture2D = null
	var ts := 32
	var cols := 16
	var rows := 12
	var sel := 0
	var _hover := -1
	var _font: Font

	func _ready() -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_STOP
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		custom_minimum_size = Vector2(0, 150)
		_font = SystemFont.new()
		_font.font_names = PackedStringArray(["Consolas", "DejaVu Sans Mono"])

	func set_tileset(t: Texture2D, tile: int, c: int, r: int) -> void:
		tex = t
		ts = tile
		cols = maxi(1, c)
		rows = maxi(1, r)
		sel = 0
		queue_redraw()

	func _cell_w() -> float:
		return maxf(6.0, size.x / float(cols))

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color("100f0d"))
		if tex == null:
			return
		var cw := _cell_w()
		for i in cols * rows:
			var cx := float((i % cols) * cw)
			var cy := float((i / cols) * cw)
			var src := Rect2(float((i % cols) * ts), float((i / cols) * ts), float(ts), float(ts))
			draw_texture_rect_region(tex, Rect2(cx, cy, cw, cw), src)
			if i == sel:
				draw_rect(Rect2(cx, cy, cw, cw), Color("e8873a"), false, 2.0)
			elif i == _hover:
				draw_rect(Rect2(cx, cy, cw, cw), Color(1, 1, 1, 0.55), false, 1.0)

	func _gui_input(ev: InputEvent) -> void:
		if tex == null:
			return
		var cw := _cell_w()
		if ev is InputEventMouseMotion:
			var p := (ev as InputEventMouseMotion).position
			var idx := int((p.y / cw)) * cols + int(p.x / cw)
			idx = clampi(idx, 0, cols * rows - 1)
			if idx != _hover:
				_hover = idx
				queue_redraw()
		elif ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				var idx := int((mb.position.y / cw)) * cols + int(mb.position.x / cw)
				idx = clampi(idx, 0, cols * rows - 1)
				sel = idx
				queue_redraw()
				picked.emit(idx)
