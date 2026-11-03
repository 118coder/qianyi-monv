extends Control
## 创作器里的地牢预览：按当前「层号 / 种子」生成一张图并画出来。
##
## 和编辑器里那个 `arpg/editor_preview.gd` 是**同一套生成器、同一套画法**，
## 区别只在于这里画在 UI 控件里（能跟着窗口缩放），那边画在 2D 场景里。
## 之所以不共用一份代码：一个跑在编辑器视口（Node2D._draw），一个跑在运行时 UI
## （Control._draw），基类和坐标系都不同，硬合并反而让两边都别扭。
##
## 绘制采用逐行合并：44×32=1408 个格子压成几十条 draw_rect，拖动窗口也不掉帧。

const Dungeon := preload("res://arpg/dungeon_gen.gd")
const Balance := preload("res://arpg/balance.gd")
const UI := preload("res://creator/core/ui_kit.gd")

const TILE := 32.0

const COL_VOID := Color(0.075, 0.082, 0.098)
const COL_WALL := Color(0.205, 0.220, 0.250)
const COL_FLOOR := Color(0.784, 0.804, 0.843)
const COL_ROOM := Color(1, 1, 1, 0.22)
const COL_START := Color(0.361, 0.918, 0.549)
const COL_STAIRS := Color(1, 0.839, 0.353)
const COL_LOOT := Color(1, 0.678, 0.322)

var floor_no := 1
var seed_val := 20261103
var pick_mode := false          # 点格子时发出 cell_picked（事件编辑器用来选点）

signal cell_picked(cell: Vector2i)

var _d = null
var _scale := 1.0
var _off := Vector2.ZERO
var _font: Font            # 缓存：_draw 会随窗口拖动频繁调用，不能每次都 new SystemFont


func _ready() -> void:
	custom_minimum_size = Vector2(480, 360)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_font = UI.make_font(12)


func rebuild(f: int, s: int) -> void:
	floor_no = maxi(1, f)
	seed_val = s
	Balance.reload_data()
	if int(Balance.MAX_FLOOR) < 2:
		Balance.MAX_FLOOR = 5
	var lv := clampi(floor_no, 1, int(Balance.MAX_FLOOR))
	var dd = Dungeon.new()
	dd.generate(lv, seed_val)
	# 与预览层同一条保险：不是最后一层却生成了 Boss 层 → 说明 MAX_FLOOR 判定异常
	if bool(dd.boss_floor) and lv != int(Balance.MAX_FLOOR):
		lv = 1
		dd = Dungeon.new()
		dd.generate(lv, seed_val)
	_d = dd
	floor_no = lv
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COL_VOID)
	if _d == null:
		return
	var w: int = int(_d.w)
	var h: int = int(_d.h)
	if w <= 0 or h <= 0:
		return
	var pad := 10.0
	_scale = minf((size.x - pad * 2.0) / (w * TILE), (size.y - pad * 2.0) / (h * TILE))
	_scale = maxf(_scale, 0.25)
	_off = Vector2(
		(pad + (size.x - pad * 2.0 - w * TILE * _scale) * 0.5),
		(pad + (size.y - pad * 2.0 - h * TILE * _scale) * 0.5))

	var full := Rect2(_off, Vector2(w, h) * TILE * _scale)
	draw_rect(full, COL_WALL)

	# 地板：逐行合并
	var fi: int = Dungeon.FLOOR
	for y in h:
		var x := 0
		while x < w:
			if int(_d.grid[x][y]) != fi:
				x += 1
				continue
			var run := 1
			while x + run < w and int(_d.grid[x + run][y]) == fi:
				run += 1
			draw_rect(Rect2(
				_off + Vector2(x, y) * TILE * _scale,
				Vector2(run, 1) * TILE * _scale), COL_FLOOR)
			x += run

	# 房间框（颜色即类型）
	if _d.room_kind.size() == _d.rooms.size():
		for i in _d.rooms.size():
			var r: Rect2i = _d.rooms[i]
			var kind := int(_d.room_kind[i])
			var col := COL_ROOM
			match kind:
				Dungeon.RoomKind.START: col = COL_START
				Dungeon.RoomKind.STAIRS: col = COL_STAIRS
				Dungeon.RoomKind.TREASURE: col = COL_LOOT
			draw_rect(Rect2(
				_off + Vector2(r.position) * TILE * _scale,
				Vector2(r.size) * TILE * _scale), col, false, 1.5)

	# 起点 / 楼梯
	var sp: Vector2 = _off + Vector2(_d.start_cell) * TILE * _scale + Vector2.ONE * TILE * _scale * 0.5
	draw_circle(sp, maxf(4.0, TILE * _scale * 0.34), COL_START)
	if _d.stair_cell.x >= 0:
		var tp: Vector2 = _off + Vector2(_d.stair_cell) * TILE * _scale + Vector2.ONE * TILE * _scale * 0.5
		var hs := maxf(4.0, TILE * _scale * 0.36)
		draw_rect(Rect2(tp - Vector2.ONE * hs, Vector2.ONE * hs * 2.0), COL_STAIRS, false, 2.0)

	# 信息角标
	if _font != null:
		var txt := "%d×%d · %s" % [w, h, str(_d.debug_stats())]
		draw_string(_font, Vector2(10, size.y - 10), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.78, 0.82, 0.88))


func _gui_input(ev: InputEvent) -> void:
	if not pick_mode:
		return
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		if _d == null:
			return
		var cell := Vector2i(((ev.position - _off) / (TILE * _scale)).floor())
		if cell.x >= 0 and cell.y >= 0 and cell.x < int(_d.w) and cell.y < int(_d.h):
			cell_picked.emit(cell)
