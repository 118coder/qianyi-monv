extends Control
## 图块画布：绘制、擦除、缩放、平移。
##
## 两条性能约束决定了写法：
##   · **只画可见格子**。40×24 全画是 960 格 × 图层数，大地图会拖慢；
##     按 `off/zoom` 反算出屏幕内的行列范围，滚动 200×150 的图也只画一屏。
##   · **事件驱动重绘**。`_draw` 只在数据或视图变化时触发，不做每帧重绘。
##
## 画布本身**不持有数据**：它只发信号，真正改 `TileScene` 的是编辑器页面，
## 因为编辑器要顺手记撤销栈、标脏、刷新缩略图。画布保持无状态才好复用。

const UI := preload("res://creator/core/ui_kit.gd")

signal paint_cell(x: int, y: int, erase: bool)
signal fill_layer(erase: bool)
signal stroke_begin()
signal stroke_end()
signal hover_changed(x: int, y: int)
signal zoom_changed(z: float)

const TOOL_BRUSH := 0
const TOOL_ERASE := 1
const TOOL_FILL := 2

var scene = null
var tex: Texture2D = null
var brush := 0
var tool := TOOL_BRUSH
var zoom := 1.0
var off := Vector2.ZERO
var show_grid := true

var _painting := false
var _panning := false
var _pan_prev := Vector2.ZERO
var _hover := Vector2i(-1, -1)
var _last_cell := Vector2i(-1, -1)
var _shift := false


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	focus_mode = Control.FOCUS_ALL


# ———————— 坐标换算 ————————

func _ts() -> float:
	return float(scene.tile_size if scene != null else 32) * zoom


func cell_at(p: Vector2) -> Vector2i:
	var ts := _ts()
	if ts <= 0.0:
		return Vector2i(-1, -1)
	var v := (p - off) / ts
	return Vector2i(floori(v.x), floori(v.y))


func center_view() -> void:
	if scene == null:
		return
	var map_px := Vector2(scene.cols, scene.rows) * float(scene.tile_size) * zoom
	off = (size - map_px) * 0.5
	queue_redraw()


func fit_view() -> void:
	if scene == null or size.x < 10 or size.y < 10:
		return
	var map_px := Vector2(scene.cols, scene.rows) * float(scene.tile_size)
	zoom = clampf(minf(size.x / map_px.x, size.y / map_px.y) * 0.94, 0.15, 4.0)
	center_view()
	zoom_changed.emit(zoom)


func set_zoom_at(p: Vector2, factor: float) -> void:
	var before := (p - off) / maxf(_ts(), 0.001)
	zoom = clampf(zoom * factor, 0.15, 6.0)
	off = p - before * _ts()
	queue_redraw()
	zoom_changed.emit(zoom)


# ———————— 绘制 ————————

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), UI.BG)
	if scene == null:
		return
	var ts := _ts()
	# 地图区域底板：让「画布范围」和「界外」一眼可分
	var map_rect := Rect2(off, Vector2(scene.cols, scene.rows) * ts)
	draw_rect(map_rect, Color("100f0d"))
	draw_rect(map_rect, Color(1, 1, 1, 0.10), false, 1.0)

	# 可见行列范围（外扩 1 格，避免边缘半格漏画）
	var x0 := maxi(0, floori(-off.x / ts))
	var y0 := maxi(0, floori(-off.y / ts))
	var x1 := mini(scene.cols - 1, ceili((size.x - off.x) / ts))
	var y1 := mini(scene.rows - 1, ceili((size.y - off.y) / ts))
	if x1 < x0 or y1 < y0:
		return

	# 逐层画：上层盖下层，空图块（-1）跳过
	var tcols := maxi(1, scene.tileset_cols)
	for li in scene.layers.size():
		var L = scene.layers[li]
		if not bool(L["visible"]):
			continue
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var idx: int = scene.get_cell(li, x, y)
				if idx < 0 or tex == null:
					continue
				var src := Rect2(float((idx % tcols) * scene.tile_size),
					float((idx / tcols) * scene.tile_size),
					float(scene.tile_size), float(scene.tile_size))
				draw_texture_rect_region(tex, Rect2(off + Vector2(x, y) * ts, Vector2(ts, ts)), src)

	# 网格：太小的格子画线反而糊成一片，所以有阈值
	if show_grid and ts >= 12.0:
		var g := Color(1, 1, 1, 0.07)
		for x in range(x0, x1 + 2):
			draw_line(Vector2(off.x + x * ts, off.y + y0 * ts),
				Vector2(off.x + x * ts, off.y + (y1 + 1) * ts), g, 1.0)
		for y in range(y0, y1 + 2):
			draw_line(Vector2(off.x + x0 * ts, off.y + y * ts),
				Vector2(off.x + (x1 + 1) * ts, off.y + y * ts), g, 1.0)

	# 悬停格：十字高亮，比整格描边更容易定位
	if _hover.x >= 0 and _hover.y >= 0 and scene.in_bounds(_hover.x, _hover.y):
		var r := Rect2(off + Vector2(_hover) * ts, Vector2(ts, ts))
		draw_rect(Rect2(r.position, Vector2(ts, 1.5)), UI.ACCENT)
		draw_rect(Rect2(r.position + Vector2(0, ts - 1.5), Vector2(ts, 1.5)), UI.ACCENT)
		draw_rect(Rect2(r.position, Vector2(1.5, ts)), UI.ACCENT)
		draw_rect(Rect2(r.position + Vector2(ts - 1.5, 0), Vector2(1.5, ts)), UI.ACCENT)


# ———————— 输入 ————————

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if not mb.pressed:
			if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
				_end_stroke()
			elif mb.button_index == MOUSE_BUTTON_MIDDLE:
				_panning = false
			return

		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				set_zoom_at(mb.position, 1.15)
			MOUSE_BUTTON_WHEEL_DOWN:
				set_zoom_at(mb.position, 1.0 / 1.15)
			MOUSE_BUTTON_MIDDLE:
				_panning = true
				_pan_prev = mb.position
			MOUSE_BUTTON_LEFT:
				_begin_stroke(mb.position, mb.alt_pressed, false)
			MOUSE_BUTTON_RIGHT:
				_begin_stroke(mb.position, mb.alt_pressed, true)

	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		if _panning:
			off += mm.position - _pan_prev
			_pan_prev = mm.position
			queue_redraw()
			return
		_update_hover(mm.position)
		if _painting and not in_tool_fill():
			var c := cell_at(mm.position)
			if c != _last_cell:
				_last_cell = c
				_paint(c, false)

	elif ev is InputEventKey:
		var ke := ev as InputEventKey
		if ke.pressed and ke.keycode == KEY_SHIFT:
			_shift = true


func in_tool_fill() -> bool:
	return tool == TOOL_FILL


func _update_hover(p: Vector2) -> void:
	var c := cell_at(p)
	if c != _hover:
		_hover = c
		hover_changed.emit(c.x, c.y)
		queue_redraw()


func _begin_stroke(p: Vector2, alt: bool, right: bool) -> void:
	# Alt + 左键 = 吸管（取当前格图块当笔刷），不落笔
	if alt and not right and scene != null:
		var c := cell_at(p)
		if scene.in_bounds(c.x, c.y):
			var idx: int = scene.get_cell(scene.cur_layer, c.x, c.y)
			if idx >= 0:
				brush = idx
				paint_cell.emit(c.x, c.y, false)   # 让编辑器同步调色板高亮
		return

	if in_tool_fill():
		stroke_begin.emit()
		fill_layer.emit(right)
		stroke_end.emit()
		return

	_painting = true
	_last_cell = cell_at(p)
	stroke_begin.emit()
	_paint(_last_cell, false)


func _paint(c: Vector2i, _unused: bool) -> void:
	if scene != null and scene.in_bounds(c.x, c.y):
		paint_cell.emit(c.x, c.y, tool == TOOL_ERASE)


func _end_stroke() -> void:
	if _painting:
		_painting = false
		_last_cell = Vector2i(-1, -1)
		stroke_end.emit()
