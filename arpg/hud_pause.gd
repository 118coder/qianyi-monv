class_name ArpgHudPause
extends RefCounted
## 暂停屏（P1-2 hud 按屏拆分收官）：继续探索 / 撤退结算二选一。
## 屏组件模式（同 hud_settle/hud_shop/hud_menu）：持有 hud 引用，控件成员本类持有。

var hud: Node

var pause_root: Control


func _init(h: Node) -> void:
	hud = h


func build() -> void:
	pause_root = Control.new()
	pause_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_root.visible = false
	hud.root.add_child(pause_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_root.add_child(dim)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_CENTER)
	v.anchor_left = 0.5
	v.anchor_right = 0.5
	v.anchor_top = 0.5
	v.anchor_bottom = 0.5
	v.grow_horizontal = Control.GROW_DIRECTION_BOTH
	v.grow_vertical = Control.GROW_DIRECTION_BOTH
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 12)
	pause_root.add_child(v)
	v.add_child(hud._label(26, Color(1, 1, 1), "暂停"))
	var tip: Label = hud._label(14, Color(1, 1, 1, 0.7), "继续深入，还是见好就收？")
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(tip)
	var b1: Button = hud._btn("继续探索", func(): hud.resume_requested.emit(), "primary")
	v.add_child(b1)
	var b2: Button = hud._btn("撤退结算（带走全部战利品）", func(): hud.retreat_requested.emit())
	v.add_child(b2)


func show() -> void:
	pause_root.visible = true


func hide() -> void:
	pause_root.visible = false
