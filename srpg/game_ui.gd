class_name SrpgGameUI
extends CanvasLayer
## 2D UI 层：回合信息、单位信息卡、行动菜单、伤害预告、回合横幅、对话框、结算画面。
## 全部控件由代码生成；中文字体走 Windows 系统字体（微软雅黑）。

signal action_chosen(action: String)
signal restart_requested
signal editor_requested

var font: SystemFont
var root: Control
var turn_label: Label
var hint_label: Label
var info_panel: PanelContainer
var portrait: TextureRect
var info_name: Label
var info_line1: Label
var info_line2: Label
var menu_panel: PanelContainer
var menu_box: VBoxContainer
var forecast_panel: PanelContainer
var fc_left: Label
var fc_right: Label
var banner_root: Control
var banner_bg: ColorRect
var banner_label: Label
var result_root: Control
var result_label: Label

# 对话框
var dlg_panel: PanelContainer
var dlg_portrait: TextureRect
var dlg_name: Label
var dlg_text: Label
var dlg_arrow: Label
var dlg_active := false
var _dlg_adv := false


func _ready() -> void:
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "sans-serif"])
	var t := Theme.new()
	t.default_font = font
	t.default_font_size = 15

	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = t
	add_child(root)

	# 回合信息（左上）
	var turn_panel := _panel()
	turn_panel.position = Vector2(12, 10)
	root.add_child(turn_panel)
	turn_label = _label(17, Color.WHITE)
	turn_panel.add_child(turn_label)

	# 操作提示（左下）
	hint_label = _label(13, Color(1, 1, 1, 0.75))
	hint_label.text = "左键：选择 / 确认    右键：取消    回车：结束回合    对话：点击或空格继续"
	hint_label.anchor_top = 1.0
	hint_label.anchor_bottom = 1.0
	hint_label.offset_left = 14
	hint_label.offset_top = -34
	hint_label.offset_right = 900
	hint_label.offset_bottom = -10
	root.add_child(hint_label)

	_build_info_panel()
	_build_menu()
	_build_forecast()
	_build_banner()
	_build_dialogue()
	_build_result()


func _build_info_panel() -> void:
	info_panel = _panel()
	info_panel.anchor_left = 1.0
	info_panel.anchor_right = 1.0
	info_panel.anchor_top = 1.0
	info_panel.anchor_bottom = 1.0
	info_panel.offset_left = -300
	info_panel.offset_top = -160
	info_panel.offset_right = -12
	info_panel.offset_bottom = -12
	info_panel.visible = false
	root.add_child(info_panel)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	info_panel.add_child(hbox)
	portrait = TextureRect.new()
	portrait.custom_minimum_size = Vector2(84, 84)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hbox.add_child(portrait)
	var vbox := VBoxContainer.new()
	hbox.add_child(vbox)
	info_name = _label(18, Color(1, 0.95, 0.8))
	vbox.add_child(info_name)
	info_line1 = _label(14, Color.WHITE)
	vbox.add_child(info_line1)
	info_line2 = _label(13, Color(0.85, 0.9, 1))
	vbox.add_child(info_line2)


func _build_menu() -> void:
	menu_panel = _panel()
	menu_panel.visible = false
	root.add_child(menu_panel)
	menu_box = VBoxContainer.new()
	menu_box.add_theme_constant_override("separation", 6)
	menu_panel.add_child(menu_box)


func _build_forecast() -> void:
	forecast_panel = _panel()
	forecast_panel.visible = false
	root.add_child(forecast_panel)
	var fh := HBoxContainer.new()
	fh.add_theme_constant_override("separation", 24)
	forecast_panel.add_child(fh)
	fc_left = _label(15, Color.WHITE)
	fh.add_child(fc_left)
	var vs := _label(15, Color(1, 0.7, 0.5))
	vs.text = "VS"
	fh.add_child(vs)
	fc_right = _label(15, Color.WHITE)
	fh.add_child(fc_right)


func _build_banner() -> void:
	banner_root = Control.new()
	banner_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	banner_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_root.visible = false
	root.add_child(banner_root)
	banner_bg = ColorRect.new()
	banner_bg.anchor_left = 0.0
	banner_bg.anchor_right = 1.0
	banner_bg.anchor_top = 0.5
	banner_bg.anchor_bottom = 0.5
	banner_bg.offset_top = -54.0
	banner_bg.offset_bottom = 54.0
	banner_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_root.add_child(banner_bg)
	banner_label = _label(34, Color.WHITE)
	banner_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner_bg.add_child(banner_label)


func _build_dialogue() -> void:
	dlg_panel = _panel()
	dlg_panel.anchor_left = 0.5
	dlg_panel.anchor_right = 0.5
	dlg_panel.anchor_top = 1.0
	dlg_panel.anchor_bottom = 1.0
	dlg_panel.offset_left = -440
	dlg_panel.offset_right = 440
	dlg_panel.offset_top = -176
	dlg_panel.offset_bottom = -14
	dlg_panel.visible = false
	root.add_child(dlg_panel)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	dlg_panel.add_child(hbox)
	dlg_portrait = TextureRect.new()
	dlg_portrait.custom_minimum_size = Vector2(96, 96)
	dlg_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dlg_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hbox.add_child(dlg_portrait)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(vbox)
	dlg_name = _label(18, Color(1, 0.95, 0.8))
	vbox.add_child(dlg_name)
	dlg_text = _label(16, Color.WHITE)
	dlg_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dlg_text.custom_minimum_size = Vector2(700, 0)
	dlg_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(dlg_text)
	dlg_arrow = _label(16, Color(1, 0.9, 0.5))
	dlg_arrow.text = "▼"
	hbox.add_child(dlg_arrow)


func _build_result() -> void:
	result_root = Control.new()
	result_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	result_root.visible = false
	root.add_child(result_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	result_root.add_child(dim)
	var cv := VBoxContainer.new()
	cv.set_anchors_preset(Control.PRESET_CENTER)
	cv.grow_horizontal = Control.GROW_DIRECTION_BOTH
	cv.grow_vertical = Control.GROW_DIRECTION_BOTH
	cv.alignment = BoxContainer.ALIGNMENT_CENTER
	cv.add_theme_constant_override("separation", 14)
	result_root.add_child(cv)
	result_label = _label(42, Color(1, 0.95, 0.75))
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(result_label)
	var bh := HBoxContainer.new()
	bh.alignment = BoxContainer.ALIGNMENT_CENTER
	bh.add_theme_constant_override("separation", 14)
	cv.add_child(bh)
	var btn := Button.new()
	btn.text = "再来一局"
	btn.custom_minimum_size = Vector2(150, 42)
	btn.pressed.connect(func(): restart_requested.emit())
	bh.add_child(btn)
	var btn2 := Button.new()
	btn2.text = "返回编辑器"
	btn2.custom_minimum_size = Vector2(150, 42)
	btn2.pressed.connect(func(): editor_requested.emit())
	bh.add_child(btn2)


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.15, 0.85)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _label(size: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func world_to_screen(p: Vector2) -> Vector2:
	return root.get_viewport().get_canvas_transform() * p


# ———————— 常规 UI ————————

func update_turn(n: int, phase: String) -> void:
	turn_label.text = "第 %d 回合 · %s" % [n, phase]


func update_info(u, terrain_desc: String) -> void:
	if u == null:
		info_panel.visible = false
		return
	var at := AtlasTexture.new()
	at.atlas = u.sprite.texture
	at.region = Rect2(u.block.x, u.block.y, 48, 48)
	portrait.texture = at
	info_name.text = u.uname + ("　★头目" if u.is_boss else "")
	info_line1.text = "HP %d/%d    攻 %d    防 %d" % [u.hp, u.max_hp, u.atk, u.def]
	var rng := str(u.rmin) if u.rmin == u.rmax else "%d~%d" % [u.rmin, u.rmax]
	info_line2.text = "移动 %d    射程 %s    %s" % [u.mov, rng, terrain_desc]
	info_panel.visible = true


func show_menu(u, actions: Array) -> void:
	for c in menu_box.get_children():
		c.queue_free()
	for a in actions:
		var b := Button.new()
		b.text = a
		b.custom_minimum_size = Vector2(96, 34)
		b.pressed.connect(func(): action_chosen.emit(a))
		menu_box.add_child(b)
	menu_panel.visible = true
	menu_panel.reset_size()
	var sp := world_to_screen(u.position)
	var vp := root.get_viewport_rect().size
	menu_panel.position = Vector2(
		clampf(sp.x + 24, 8, vp.x - menu_panel.size.x - 8),
		clampf(sp.y - menu_panel.size.y - 8, 8, vp.y - menu_panel.size.y - 8))


func hide_menu() -> void:
	menu_panel.visible = false


func show_forecast(a, d, dmg: int, counter: int, lethal: bool) -> void:
	var kill_mark := "（击破！）" if lethal else ""
	fc_left.text = "%s\nHP %d  →  造成 %d%s" % [a.uname, a.hp, dmg, kill_mark]
	fc_right.text = "%s\nHP %d  反击 %d" % [d.uname, d.hp, counter]
	forecast_panel.visible = true
	forecast_panel.reset_size()
	var vp := root.get_viewport_rect().size
	forecast_panel.position = Vector2((vp.x - forecast_panel.size.x) / 2, 14)


func hide_forecast() -> void:
	forecast_panel.visible = false


func show_banner(text: String, col: Color) -> void:
	banner_label.text = text
	banner_bg.color = Color(col.r, col.g, col.b, 0.82)
	banner_root.visible = true
	banner_root.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(banner_root, "modulate:a", 1.0, 0.18)
	tw.tween_interval(0.65)
	tw.tween_property(banner_root, "modulate:a", 0.0, 0.22)
	await tw.finished
	banner_root.visible = false


# ———————— 对话框（事件系统用） ————————

## speaker_id：SrpgData.UNITS 的模板 id（带头像），其他值按旁白处理
func show_dialogue(speaker_id: String, lines: Array) -> void:
	if lines.is_empty():
		return
	var tpl: Dictionary = SrpgData.UNITS.get(speaker_id, {})
	if tpl.is_empty():
		dlg_portrait.visible = false
		dlg_name.text = "旁白"
	else:
		dlg_portrait.visible = true
		var at := AtlasTexture.new()
		at.atlas = load(tpl["sprite"][0])
		at.region = Rect2(tpl["sprite"][1], tpl["sprite"][2], 48, 48)
		dlg_portrait.texture = at
		dlg_name.text = tpl["name"]
	dlg_panel.visible = true
	dlg_active = true
	for line in lines:
		dlg_text.text = str(line)
		_dlg_adv = false
		while not _dlg_adv:
			await get_tree().process_frame
	dlg_active = false
	dlg_panel.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not dlg_active:
		return
	var adv := false
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		adv = true
	elif event is InputEventKey and event.pressed and not event.echo \
			and event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
		adv = true
	if adv:
		get_viewport().set_input_as_handled()
		_dlg_adv = true


func show_result(win: bool) -> void:
	result_label.text = "胜  利 ！" if win else "败  北 ……"
	result_root.visible = true
