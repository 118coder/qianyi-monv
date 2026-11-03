extends Control
## 精灵预览 / 精灵表选择器。
##
## 直读 PNG（Image.load，绕过导入系统）——与图块编辑器同一手法：
## 用户把新图丢进 assets/ 立刻可用，不等 .import、不用重启。
##
## 两种模式：
##   · single —— 显示 sprite:[文件, x, y] 指定的那一帧（48×48），居中放大；
##   · picker —— 把整张精灵表铺成网格供点击，选中的帧用强调色描边。
##
## 游戏侧约定（arpg/player.gd L127-131）：sprite 是 [贴图路径, 像素x, 像素y]，
## 帧固定 48×48，所以这里直接按 48 切网格，不做尺寸推断。

signal picked(file: String, x: int, y: int)

const UI := preload("res://creator/core/ui_kit.gd")

const FRAME := 48

static var _cache := {}    # 路径 -> Texture2D；Image 解码不便宜，必须复用

var mode := "single"       # "single" | "picker"
var file := ""
var fx := 0                # 帧的像素坐标（不是帧序号）
var fy := 0
var zoom := 2.6            # single 模式放大倍数
var picker_cell := 40.0    # picker 模式每格边长
var _cols := 1
var _rows := 1
var _hover := Vector2i(-1, -1)


static func tex_for(path: String) -> Texture2D:
	if str(path) == "":
		return null
	if _cache.has(path):
		return _cache[path]
	var img := Image.new()
	var abs := path if str(path).begins_with("res://") else ProjectSettings.globalize_path(path)
	if img.load(abs) != OK:
		return null
	img.convert(Image.FORMAT_RGBA8)
	var t := ImageTexture.create_from_image(img)
	_cache[path] = t
	return t


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	custom_minimum_size = Vector2(0, 128)
	_update_grid()


func set_sprite(path: String, x: int, y: int) -> void:
	file = path
	fx = x
	fy = y
	_update_grid()
	queue_redraw()


func _update_grid() -> void:
	_cols = 1
	_rows = 1
	var t := tex_for(file)
	if t != null:
		_cols = maxi(1, t.get_width() / FRAME)
		_rows = maxi(1, t.get_height() / FRAME)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("0b0a09"))
	if file == "":
		draw_string(UI.mono(), Vector2(10, 22), "未设置图片", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UI.DIM)
		return
	var t := tex_for(file)
	if t == null:
		draw_string(UI.mono(), Vector2(10, 22), "图片读取失败：" + file.get_file(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UI.ERR)
		return

	if mode == "single":
		var scale := zoom
		var dsize := Vector2(FRAME, FRAME) * scale
		if dsize.x > size.x or dsize.y > size.y:
			scale = minf(size.x / float(FRAME), size.y / float(FRAME))
			dsize = Vector2(FRAME, FRAME) * scale
		var org := (Vector2(size) - dsize) * 0.5
		draw_texture_rect_region(t, Rect2(org, dsize), Rect2(float(fx), float(fy), FRAME, FRAME))
		draw_rect(Rect2(org, dsize), UI.LINE, false, 1.0)
	else:
		var cell := minf(picker_cell, size.x / float(_cols))
		var sel_gx := fx / FRAME
		var sel_gy := fy / FRAME
		for gy in _rows:
			for gx in _cols:
				var px := float(gx) * cell
				var py := float(gy) * cell
				draw_texture_rect_region(t, Rect2(px, py, cell, cell),
					Rect2(float(gx * FRAME), float(gy * FRAME), FRAME, FRAME))
				if gx == sel_gx and gy == sel_gy:
					draw_rect(Rect2(px, py, cell, cell), UI.ACCENT, false, 2.0)
				elif gx == _hover.x and gy == _hover.y:
					draw_rect(Rect2(px, py, cell, cell), Color(1, 1, 1, 0.5), false, 1.0)


func _gui_input(ev: InputEvent) -> void:
	if mode != "picker" or file == "":
		return
	if ev is InputEventMouseMotion:
		var p := (ev as InputEventMouseMotion).position
		var g := Vector2i(int(p.x / _cell_w()), int(p.y / _cell_w()))
		if g != _hover:
			_hover = g
			queue_redraw()
	elif ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var gx := clampi(int(mb.position.x / _cell_w()), 0, _cols - 1)
			var gy := clampi(int(mb.position.y / _cell_w()), 0, _rows - 1)
			fx = gx * FRAME
			fy = gy * FRAME
			queue_redraw()
			picked.emit(file, fx, fy)


func _cell_w() -> float:
	return minf(picker_cell, size.x / float(_cols))
