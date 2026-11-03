extends Control
## 节点式事件画布：触发器是链头，命令纵向成流，条件分支真正分出「是 / 否」两列。
##
## 与 `editor/advanced_tabs.gd` 的 EditorEventCanvas（缩进式单列）不同：
## 这里用**单遍递归布局**，if 节点下 then 链摆在本列、else 链摆右移一档的新列，
## 两条链的出口作为「待连线」返回给主链的下一个节点，由它把两条线一起接到自己头顶
## ——这就是流程图里的「汇合」。空分支则从 if 底部对应锚点直接垂线过去。
##
## 坐标体系：布局与命中测试全在世界坐标（内容坐标）；绘制前 `draw_set_transform`
## 统一加 `_pan` 与 `zoom`，命中时把鼠标换算回世界坐标，缩放平移不破坏选中。
## 回调（title_of/lines_of/color_of/trigger_of）由事件编辑器注入，
## 画布不持有命令注册表——避免与 event_editor.gd 循环 preload。

signal node_selected(path: Array)

const UI := preload("res://creator/core/ui_kit.gd")

const NODE_W := 252.0
const NODE_HEAD := 25.0
const NODE_ROW := 19.0
const V_GAP := 20.0
const BRANCH_DX := 296.0
const MARGIN := 28.0

const COL_FLOW := Color(0.58, 0.70, 0.92, 0.85)
const COL_YES := Color(0.45, 0.8, 0.5, 0.95)
const COL_NO := Color(0.94, 0.55, 0.45, 0.95)
const COL_BG := Color("0d0c0b")
const COL_NODE := Color("171614")
const COL_NODE_TEXT := Color(0.86, 0.89, 0.86)
const COL_SEL := Color("f0c355")

var ev: Variant = null                 # 当前事件字典（引用）；null = 未选事件
var sel_path: Array = []               # 与事件编辑器共享的选择状态
var zoom := 1.0
var title_of: Callable = Callable()    # (cmd) -> String
var lines_of: Callable = Callable()    # (cmd) -> Array[String]
var color_of: Callable = Callable()    # (cmd) -> Color
var trigger_of: Callable = Callable()  # (trigger) -> {title, lines}

var _pan := Vector2(MARGIN, MARGIN)
var _rects: Array = []
var _font: Font
var _panning := false


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_font = UI.make_font(13)


func set_event(e: Variant) -> void:
	ev = e
	queue_redraw()


## 宿主切到本页时调用：回到初始视图
func reset_view() -> void:
	zoom = 1.0
	_pan = Vector2(MARGIN, MARGIN)
	queue_redraw()


func _world(p: Vector2) -> Vector2:
	return (p - _pan) / maxf(zoom, 0.001)


func _hit(wp: Vector2) -> Array:
	for i in range(_rects.size() - 1, -1, -1):
		var r: Dictionary = _rects[i]
		if (r["rect"] as Rect2).has_point(wp):
			return r["path"]
	return []


# ———————— 布局 + 绘制 ————————

func _draw() -> void:
	_rects.clear()
	draw_rect(Rect2(Vector2.ZERO, size), COL_BG)
	if ev == null or not (ev is Dictionary):
		_note("在左侧「事件」里选一个事件，命令流会画在这里")
		return
	if title_of.is_null() or lines_of.is_null() or color_of.is_null() or trigger_of.is_null():
		return

	draw_set_transform(_pan, 0.0, Vector2(zoom, zoom))

	# 背景网格（世界坐标下画，随缩放平移）
	var vp := Rect2(-_pan / zoom, size / zoom)
	var g := Color(1, 1, 1, 0.035)
	var gx := floorf(vp.position.x / 32.0) * 32.0
	while gx < vp.end.x:
		draw_line(Vector2(gx, vp.position.y), Vector2(gx, vp.end.y), g, 1.0)
		gx += 32.0
	var gy := floorf(vp.position.y / 32.0) * 32.0
	while gy < vp.end.y:
		draw_line(Vector2(vp.position.x, gy), Vector2(vp.end.x, gy), g, 1.0)
		gy += 32.0

	# 链头：触发器
	var th: Dictionary = trigger_of.call(ev.get("trigger", {}))
	var trect := _node(Vector2(0, 0), str(th.get("title", "触发器")), Color(0.72, 0.6, 0.28), th.get("lines", []), [])

	# 主链；汇合点由「待连线」机制接进每个节点头顶
	var cmds: Array = ev.get("commands", [])
	_chain(cmds, [], 0.0, trect.end.y + V_GAP,
		[{"from": Vector2(trect.position.x + NODE_W * 0.5, trect.end.y), "col": COL_FLOW, "label": ""}])
	if cmds.is_empty():
		_hint_world(Vector2(0, trect.end.y + V_GAP + 8.0),
			"这个事件还没有命令——用下方命令条或右栏「在此命令后添加」加一条")

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 铺一条命令链。返回 {bottom, right, pend}：
##   bottom = 链内最底内容的 y（不含尾距）；pend = 这条链的出口连线（汇合进父链下一节点）。
func _chain(cmds: Array, base: Array, x: float, y: float, incoming: Array) -> Dictionary:
	var cy := y
	var bottom := y - V_GAP
	var right := x + NODE_W
	var pend: Array = incoming.duplicate()
	var chain_col := COL_FLOW
	if incoming.size() > 0:
		chain_col = incoming[0]["col"]

	for i in cmds.size():
		var c: Dictionary = cmds[i]
		var path: Array = base.duplicate()
		path.append(i)
		var head_col: Color = color_of.call(c)
		var r := _node(Vector2(x, cy), str(title_of.call(c)), head_col, lines_of.call(c), path)
		_flush(pend, r)
		right = maxf(right, x + NODE_W)

		if str(c.get("cmd", "")) == "if":
			var bl := Vector2(x + NODE_W * 0.30, r.end.y)
			var br := Vector2(x + NODE_W * 0.70, r.end.y)
			var t := _chain(c.get("then", []), path + ["then"], x, r.end.y + V_GAP,
				[{"from": bl, "col": COL_YES, "label": "是"}])
			var e2 := _chain(c.get("else", []), path + ["else"], x + BRANCH_DX, r.end.y + V_GAP,
				[{"from": br, "col": COL_NO, "label": "否"}])
			right = maxf(right, maxf(t["right"], e2["right"]))
			bottom = maxf(t["bottom"], e2["bottom"])
			cy = bottom + V_GAP
			pend = []
			# 两条分支的出口一起汇进主链下一个节点
			for p in t["pend"]:
				pend.append(p)
			for p in e2["pend"]:
				pend.append(p)
			# 空分支：从 if 底部对应锚点直接垂线，不悬空
			var t_empty: bool = (c.get("then", []) as Array).is_empty()
			var e_empty: bool = (c.get("else", []) as Array).is_empty()
			if t_empty and e_empty:
				pend = [{"from": Vector2(x + NODE_W * 0.5, r.end.y), "col": chain_col, "label": ""}]
			else:
				if t_empty:
					pend.append({"from": bl, "col": COL_YES, "label": ""})
				if e_empty:
					pend.append({"from": br, "col": COL_NO, "label": ""})
		else:
			bottom = r.end.y
			cy = r.end.y + V_GAP
			pend = [{"from": Vector2(x + NODE_W * 0.5, r.end.y), "col": chain_col, "label": ""}]

	return {"bottom": bottom, "right": right, "pend": pend}


## 把所有待连线画到节点头顶（两段折线：先垂直到中高，再平移，再垂直到顶）
func _flush(pend: Array, r: Rect2) -> void:
	var to := Vector2(r.position.x + NODE_W * 0.5, r.position.y)
	for p in pend:
		var from: Vector2 = p["from"]
		var col: Color = p["col"]
		var mid_y := from.y + (to.y - from.y) * 0.45
		draw_line(from, Vector2(from.x, mid_y), col, 2.5)
		draw_line(Vector2(from.x, mid_y), Vector2(to.x, mid_y), col, 2.5)
		draw_line(Vector2(to.x, mid_y), to, col, 2.5)
		draw_circle(to, 3.5, Color(0.92, 0.96, 1.0, 0.95))
		var label := str(p.get("label", ""))
		if label != "":
			draw_string(_font, from.lerp(Vector2(to.x, mid_y), 0.5) + Vector2(7, -5),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)


func _node(pos: Vector2, title: String, head: Color, lines: Array, path: Array) -> Rect2:
	var n: int = maxi(1, lines.size())
	var h := NODE_HEAD + float(n) * NODE_ROW + 8.0
	var r := Rect2(pos, Vector2(NODE_W, h))
	_rects.append({"rect": r, "path": path.duplicate()})

	var sel: bool = path == sel_path
	draw_rect(r, COL_NODE, true)
	if sel:
		draw_rect(r, COL_SEL, false, 2.5)
	else:
		draw_rect(r, Color(1, 1, 1, 0.14), false, 1.0)
	draw_rect(Rect2(r.position, Vector2(r.size.x, NODE_HEAD)), Color(head.r, head.g, head.b, 0.85), true)
	draw_string(_font, r.position + Vector2(8, 17), title,
		HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 16, 13, Color(0.06, 0.06, 0.07))
	var yy := r.position.y + NODE_HEAD + 15.0
	for i in n:
		var t: String = str(lines[i]) if i < lines.size() else ""
		draw_string(_font, Vector2(r.position.x + 8, yy), t,
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 16, 12, COL_NODE_TEXT)
		yy += NODE_ROW
	return r


func _hint_world(pos: Vector2, text: String) -> void:
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.4))


func _note(text: String) -> void:
	draw_string(_font, Vector2(MARGIN, MARGIN + 20.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.45))


# ———————— 输入 ————————

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(mb.position, 1.12)
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(mb.position, 1.0 / 1.12)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var hit := _hit(_world(mb.position))
			sel_path = hit
			node_selected.emit(sel_path.duplicate())
			queue_redraw()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning and (mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0:
			_pan += mm.relative
			queue_redraw()


## 滚轮缩放以鼠标为锚：保持锚点的世界坐标不动
func _zoom_at(screen_p: Vector2, factor: float) -> void:
	var w := (screen_p - _pan) / maxf(zoom, 0.001)
	zoom = clampf(zoom * factor, 0.4, 2.5)
	_pan = screen_p - w * zoom
	queue_redraw()
