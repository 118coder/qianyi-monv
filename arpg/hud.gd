class_name ArpgHUD
extends CanvasLayer
## 全部 UI：战斗 HUD（血条/SP/经验/背包/日志/Boss条/交互提示）+ 角色选择 + 结算 + 暂停菜单。
## process_mode 设为 ALWAYS，保证暂停时菜单仍可用。

signal start_selected(char_id: String)
signal back_to_title
signal resume_requested
signal retreat_requested

var font: SystemFont
var root: Control

# 战斗 HUD
var play_hud: Control
var hp_bar: ProgressBar
var sp_bar: ProgressBar
var xp_bar: ProgressBar
var lv_label: Label
var floor_label: Label
var bag_label: Label
var skill_label: Label
var perf_label: Label
var log_label: Label
var prompt_label: Label
var boss_box: VBoxContainer
var boss_bar: ProgressBar
var boss_name: Label

# 角色选择 / 结算 / 暂停
var select_root: Control
var settle_root: Control
var settle_title: Label
var settle_stats: Label
var settle_goods: Label
var settle_total: Label
var pause_root: Control

# 队伍面板 / 调试面板
var party_scroll: ScrollContainer
var party_box: VBoxContainer
var debug_panel: PanelContainer
var debug_label: Label
var _debug_visible := false

var _logs := []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "sans-serif"])
	var t := Theme.new()
	t.default_font = font
	t.default_font_size = 14
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = t
	add_child(root)
	_build_play_hud()
	_build_select()
	_build_settle()
	_build_pause()
	_build_party_panel()
	_build_debug_panel()


## 队伍面板：可滚动，支持任意 N（需求书 §5.7）
func _build_party_panel() -> void:
	party_scroll = ScrollContainer.new()
	party_scroll.position = Vector2(12, 108)
	party_scroll.custom_minimum_size = Vector2(250, 100)
	party_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	party_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(party_scroll)
	party_box = VBoxContainer.new()
	party_box.add_theme_constant_override("separation", 1)
	party_scroll.add_child(party_box)
	party_scroll.visible = false


func update_party(rows: Array, possessed_uid: String = "") -> void:
	if rows.is_empty():
		party_scroll.visible = false
		return
	party_scroll.visible = play_hud.visible
	for c in party_box.get_children():
		c.queue_free()
	for r in rows:
		var l := Label.new()
		var status := "倒下" if bool(r["dead"]) else ArpgAIController.cmd_name(str(r["cmd"]))
		var mark := "◆APC " if bool(r["apc"]) else ""
		var high := "▶ " if r["uid"] == possessed_uid else "   "
		l.text = "%s%s  HP %d/%d  %s" % [high, mark + str(r["name"]), r["hp"], r["max"], status]
		l.add_theme_font_size_override("font_size", 12)
		if bool(r["dead"]):
			l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		elif r["uid"] == possessed_uid:
			l.add_theme_color_override("font_color", Color(1, 0.95, 0.5))
		elif bool(r["apc"]):
			l.add_theme_color_override("font_color", Color(0.75, 0.85, 1))
		else:
			l.add_theme_color_override("font_color", Color(0.8, 1, 0.85))
		party_box.add_child(l)


## 调试面板（F1）：AI 状态 / 指令 / 主控日志一屏可见（需求书 §5.8）
func _build_debug_panel() -> void:
	debug_panel = _panel_box()
	debug_panel.anchor_left = 1.0
	debug_panel.anchor_right = 1.0
	debug_panel.offset_left = -430
	debug_panel.offset_right = -12
	debug_panel.offset_top = 10
	debug_panel.visible = false
	root.add_child(debug_panel)
	debug_label = _label(12, Color(0.85, 1, 0.9))
	debug_label.text = ""
	debug_panel.add_child(debug_label)


func toggle_debug() -> void:
	_debug_visible = not _debug_visible
	debug_panel.visible = _debug_visible


func set_debug_lines(lines: Array) -> void:
	if not _debug_visible:
		return
	debug_label.text = "\n".join(lines)


# ———————— 小工具 ————————

func _label(size: int, col: Color, text := "") -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _bar(fill: Color, size: Vector2) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = size
	b.show_percentage = false
	b.max_value = 1.0
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.05, 0.09, 0.85)
	bg.set_corner_radius_all(3)
	var fg := StyleBoxFlat.new()
	fg.bg_color = fill
	fg.set_corner_radius_all(3)
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fg)
	return b


func _panel_box() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.12, 0.88)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(12)
	p.add_theme_stylebox_override("panel", sb)
	return p


# ———————— 战斗 HUD ————————

func _build_play_hud() -> void:
	play_hud = Control.new()
	play_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	play_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	play_hud.visible = false
	root.add_child(play_hud)

	var top_left := VBoxContainer.new()
	top_left.position = Vector2(12, 10)
	top_left.add_theme_constant_override("separation", 3)
	play_hud.add_child(top_left)
	hp_bar = _bar(Color(0.4, 0.85, 0.4), Vector2(230, 16))
	top_left.add_child(hp_bar)
	sp_bar = _bar(Color(0.4, 0.62, 1.0), Vector2(230, 9))
	top_left.add_child(sp_bar)
	xp_bar = _bar(Color(0.95, 0.85, 0.35), Vector2(230, 5))
	top_left.add_child(xp_bar)
	lv_label = _label(13, Color(1, 1, 1, 0.9))
	top_left.add_child(lv_label)

	floor_label = _label(22, Color(1, 0.95, 0.8))
	floor_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	floor_label.anchor_left = 0.5
	floor_label.anchor_right = 0.5
	floor_label.offset_left = -80
	floor_label.offset_right = 80
	floor_label.offset_top = 10
	floor_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	play_hud.add_child(floor_label)

	var top_right := VBoxContainer.new()
	top_right.anchor_left = 1.0
	top_right.anchor_right = 1.0
	top_right.offset_left = -220
	top_right.offset_right = -12
	top_right.offset_top = 10
	top_right.add_theme_constant_override("separation", 2)
	play_hud.add_child(top_right)
	bag_label = _label(14, Color(1, 1, 1))
	bag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(bag_label)
	skill_label = _label(13, Color(0.8, 0.9, 1))
	skill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(skill_label)
	perf_label = _label(12, Color(0.6, 1.0, 0.75, 0.9))
	perf_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(perf_label)

	log_label = _label(13, Color(1, 1, 1, 0.85))
	log_label.anchor_top = 1.0
	log_label.anchor_bottom = 1.0
	log_label.offset_left = 14
	log_label.offset_top = -140
	log_label.offset_right = 520
	log_label.offset_bottom = -46
	play_hud.add_child(log_label)

	prompt_label = _label(18, Color(1, 0.95, 0.6))
	prompt_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	prompt_label.anchor_left = 0.5
	prompt_label.anchor_right = 0.5
	prompt_label.anchor_top = 1.0
	prompt_label.anchor_bottom = 1.0
	prompt_label.offset_left = -160
	prompt_label.offset_right = 160
	prompt_label.offset_top = -170
	prompt_label.offset_bottom = -140
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_label.visible = false
	play_hud.add_child(prompt_label)

	boss_box = VBoxContainer.new()
	boss_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	boss_box.anchor_left = 0.5
	boss_box.anchor_right = 0.5
	boss_box.offset_left = -220
	boss_box.offset_right = 220
	boss_box.offset_top = 44
	boss_box.visible = false
	play_hud.add_child(boss_box)
	boss_name = _label(15, Color(1, 0.6, 0.55))
	boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boss_box.add_child(boss_name)
	boss_bar = _bar(Color(0.85, 0.25, 0.2), Vector2(440, 12))
	boss_box.add_child(boss_bar)


func update_bars(player: ArpgPlayer, bag_n: int, potion_n: int, floor_no: int, boss_floor: bool) -> void:
	hp_bar.value = float(player.hp) / player.max_hp
	sp_bar.value = float(player.sp) / player.max_sp
	xp_bar.value = float(player.xp) / ArpgBalance.xp_need(player.level)
	lv_label.text = "Lv %d    攻 %d    HP %d/%d" % [player.level, player.atk, player.hp, player.max_hp]
	floor_label.text = "地下 %d 层%s" % [floor_no, "　★ BOSS" if boss_floor else ""]
	bag_label.text = "背包 %d/%d    药水×%d [Q]" % [bag_n, ArpgBalance.BAG_CAP, potion_n]
	var sk: Dictionary = player.tpl["skill"]
	skill_label.text = "技能 %s [K]  消耗SP%d  %s" % [sk["name"], sk["sp"], ("冷却中" if player.skill_cd > 0.0 else "就绪")]


func set_perf(fps: int, mob_n: int, proj_n: int, sim_ms: float) -> void:
	perf_label.text = "FPS %d · 敌 %d · 弹 %d · AI %.2fms" % [fps, mob_n, proj_n, sim_ms]


func log(msg: String) -> void:
	_logs.append(msg)
	while _logs.size() > 5:
		_logs.pop_front()
	log_label.text = "\n".join(_logs)


func set_prompt(text: String) -> void:
	prompt_label.visible = text != ""
	prompt_label.text = text


func show_boss_bar(show_it: bool, ratio: float, boss_name_text: String) -> void:
	boss_box.visible = show_it
	boss_bar.value = ratio
	boss_name.text = boss_name_text


# ———————— 角色选择 ————————

func _build_select() -> void:
	select_root = Control.new()
	select_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	select_root.visible = false
	root.add_child(select_root)
	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.06, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	select_root.add_child(bg)

	var title := _label(34, Color(1, 0.95, 0.75), "千亿魔女 · 地牢试炼（战斗原型）")
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.anchor_left = 0.5
	title.anchor_right = 0.5
	title.offset_left = -400
	title.offset_right = 400
	title.offset_top = 46
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	select_root.add_child(title)
	var sub := _label(15, Color(1, 1, 1, 0.65), "选择一名冒险者进入地牢 —— 战利品带回店铺售卖（经营系统施工中）")
	sub.set_anchors_preset(Control.PRESET_CENTER_TOP)
	sub.anchor_left = 0.5
	sub.anchor_right = 0.5
	sub.offset_left = -400
	sub.offset_right = 400
	sub.offset_top = 92
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	select_root.add_child(sub)

	var cards := HBoxContainer.new()
	cards.set_anchors_preset(Control.PRESET_CENTER)
	cards.anchor_left = 0.5
	cards.anchor_right = 0.5
	cards.anchor_top = 0.5
	cards.anchor_bottom = 0.5
	cards.grow_horizontal = Control.GROW_DIRECTION_BOTH
	cards.grow_vertical = Control.GROW_DIRECTION_BOTH
	cards.add_theme_constant_override("separation", 18)
	select_root.add_child(cards)
	for id in ArpgBalance.CHARS:
		cards.add_child(_char_card(id))

	var hint := _label(14, Color(1, 1, 1, 0.6),
		"移动 WASD/方向键/左摇杆    普攻 J/Z/A·RT    技能 K/X/X·LT    药水 Q/Y    互动 E/B    暂停 Esc/Start\nTab 切换主控    T 队伍指令（进攻/跟随/待机）    F1 调试面板    F9/F10 队伍存档\n升级会完全回满 HP/SP · 宝箱有陷阱 · 背包上限 20 · 打倒第 5 层魔王即可凯旋 · 手柄带震动")
	hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint.anchor_left = 0.5
	hint.anchor_right = 0.5
	hint.anchor_top = 1.0
	hint.anchor_bottom = 1.0
	hint.offset_left = -420
	hint.offset_right = 420
	hint.offset_top = -110
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	select_root.add_child(hint)


func _char_card(id: String) -> Control:
	var tpl: Dictionary = ArpgBalance.CHARS[id]
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.11, 0.18)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(14)
	sb.border_width_bottom = 3
	sb.border_color = Color(1, 0.85, 0.4, 0.35)
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size = Vector2(230, 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	var at := AtlasTexture.new()
	at.atlas = load(tpl["sprite"][0])
	at.region = Rect2(tpl["sprite"][1], tpl["sprite"][2], 48, 48)
	var tr := TextureRect.new()
	tr.texture = at
	tr.custom_minimum_size = Vector2(0, 110)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	v.add_child(tr)
	var name_l := _label(19, Color(1, 0.95, 0.8), tpl["name"])
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(name_l)
	var role := _label(13, Color(0.75, 0.85, 1), tpl["title"])
	role.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(role)
	var stats := _label(13, Color(1, 1, 1, 0.85),
		"HP %d   SP %d   攻 %d\n移速 %d" % [tpl["hp"], tpl["sp"], tpl["atk"], int(tpl["spd"])])
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(stats)
	var sk: Dictionary = tpl["skill"]
	var skl := _label(13, Color(1, 0.8, 0.5), "技能「%s」：%s" % [sk["name"], sk["desc"]])
	skl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	skl.custom_minimum_size = Vector2(200, 0)
	v.add_child(skl)
	var btn := Button.new()
	btn.text = "选择出击"
	btn.pressed.connect(func(): start_selected.emit(id))
	v.add_child(btn)
	return panel


# ———————— 结算 ————————

func _build_settle() -> void:
	settle_root = Control.new()
	settle_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	settle_root.visible = false
	root.add_child(settle_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.66)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	settle_root.add_child(dim)
	var panel := _panel_box()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	settle_root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	settle_title = _label(34, Color(1, 0.95, 0.75))
	settle_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(settle_title)
	settle_stats = _label(15, Color(1, 1, 1))
	v.add_child(settle_stats)
	var sep := HSeparator.new()
	v.add_child(sep)
	var goods_title := _label(16, Color(1, 0.9, 0.6), "带回的商品（入库待售）")
	v.add_child(goods_title)
	settle_goods = _label(14, Color(0.9, 0.95, 1))
	v.add_child(settle_goods)
	settle_total = _label(20, Color(1, 0.85, 0.35))
	settle_total.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(settle_total)
	var btn := Button.new()
	btn.text = "回到标题"
	btn.pressed.connect(func(): back_to_title.emit())
	v.add_child(btn)


func show_settle(title: String, title_col: Color, stats: String, goods: String, total: int) -> void:
	settle_title.text = title
	settle_title.add_theme_color_override("font_color", title_col)
	settle_stats.text = stats
	settle_goods.text = goods
	settle_total.text = "商品总价值：%d G" % total
	settle_root.visible = true


# ———————— 暂停 ————————

func _build_pause() -> void:
	pause_root = Control.new()
	pause_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_root.visible = false
	root.add_child(pause_root)
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
	v.add_child(_label(26, Color(1, 1, 1), "暂停"))
	var tip := _label(14, Color(1, 1, 1, 0.7), "继续深入，还是见好就收？")
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(tip)
	var b1 := Button.new()
	b1.text = "继续探索"
	b1.pressed.connect(func(): resume_requested.emit())
	v.add_child(b1)
	var b2 := Button.new()
	b2.text = "撤退结算（带走全部战利品）"
	b2.pressed.connect(func(): retreat_requested.emit())
	v.add_child(b2)


func show_pause() -> void:
	pause_root.visible = true


func hide_pause() -> void:
	pause_root.visible = false


func show_select() -> void:
	select_root.visible = true


func hide_select() -> void:
	select_root.visible = false
