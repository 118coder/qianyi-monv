class_name ArpgHUD
extends CanvasLayer
## 全部 UI：战斗 HUD（血条/SP/经验/背包/日志/Boss条/交互提示）+ 角色选择 + 结算 + 暂停菜单。
## process_mode 设为 ALWAYS，保证暂停时菜单仍可用。

signal start_selected(char_id: String)
var scene_mode := false   # 选人画面「试玩手搭场景」按钮置位 → start_run 时进入场景模式
signal back_to_title
signal resume_requested
signal retreat_requested

const Minimap := preload("res://arpg/minimap.gd")

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
var gold_label: Label
var debt_label: Label
var _debt_clear_shown := false
var _gold_tw: Tween
var minimap: Minimap
var skill_label: Label
var perf_label: Label
var log_label: Label
var log_bg: ColorRect
var prompt_label: Label
var boss_box: VBoxContainer
var boss_bar: ProgressBar
var boss_name: Label

# 角色选择 / 结算 / 暂停
var select_root: Control
var settle_screen: ArpgHudSettle   # 结算屏（hud_settle.gd，P1-2 按屏拆分）
var pause_screen: ArpgHudPause   # 暂停屏（hud_pause.gd，按屏拆分收官）

# 队伍面板 / 调试面板
var party_scroll: ScrollContainer
var party_box: VBoxContainer
var debug_panel: PanelContainer
var debug_label: Label
var _debug_visible := false

# 角色菜单 / 商店 / 任务提示
var game: Node
var menu_screen: ArpgHudMenu   # 角色菜单屏（hud_menu.gd，P1-2 按屏拆分）
var _menu_ctx := {}            # 屏间共享上下文快照（结算屏商店/菜单页共同读取）
var menu_tabs := {}
var shop_screen: ArpgHudShop   # 商店屏（hud_shop.gd，P1-2 按屏拆分）
var toast_label: Label
var toast_bg: ColorRect

var _logs := []

# 事件 UI（横幅 / 对话框；事件系统经 main.ui 调用）
var banner_root: Control
var banner_bg: ColorRect
var banner_label: Label
var dlg_panel: PanelContainer
var dlg_portrait: TextureRect
var dlg_name: Label
var dlg_text: Label
var dlg_active := false
var _dlg_adv := false

# ———————— 设计 token（Operate 模式：克制度为底线，语义色统一） ————————
const C_SURFACE := Color(0.07, 0.09, 0.15, 0.94)
const C_SURFACE2 := Color(0.11, 0.13, 0.21, 0.94)
const C_BTN := Color(0.17, 0.20, 0.30)
const C_BTN_HOVER := Color(0.24, 0.28, 0.41)
const C_BTN_PRESS := Color(0.13, 0.15, 0.23)
const C_ACCENT := Color(1.0, 0.84, 0.38)
const C_TEXT := Color(0.94, 0.95, 1.0)
const C_TEXT_DIM := Color(0.72, 0.77, 0.88)
const C_DANGER := Color(0.92, 0.38, 0.32)
const C_SUCCESS := Color(0.5, 0.9, 0.6)
const C_BORDER := Color(1, 1, 1, 0.07)

## 事件对话讲者沿用战棋角色 id → ARPG 角色 id（剑士在战棋叫 sword）
const SPEAKER_ALIAS := {"sword": "fencer"}


func _style_box(bg: Color, radius: int = 8, border: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	if border:
		sb.set_border_width_all(1)
		sb.border_color = C_BORDER
	return sb


## 统一按钮工厂：kind = ghost（次要）/ primary（主操作·金）/ danger
func _btn(text: String, cb: Callable, kind: String = "ghost") -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	var normal := _style_box(C_ACCENT if kind == "primary" else (Color(0.32, 0.14, 0.12) if kind == "danger" else C_BTN), 6)
	var hover := _style_box(C_ACCENT.lightened(0.08) if kind == "primary" else (Color(0.4, 0.18, 0.16) if kind == "danger" else C_BTN_HOVER), 6)
	var press := _style_box(C_BTN_PRESS if kind == "ghost" else C_ACCENT.darkened(0.15), 6)
	var focus := _style_box(Color(0, 0, 0, 0), 6)
	focus.set_border_width_all(2)
	focus.border_color = C_ACCENT
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", press)
	b.add_theme_stylebox_override("focus", focus)
	var fc := Color(0.1, 0.09, 0.06) if kind == "primary" else C_TEXT
	b.add_theme_color_override("font_color", fc)
	b.add_theme_color_override("font_hover_color", fc)
	b.add_theme_color_override("font_pressed_color", fc)
	b.add_theme_color_override("font_focus_color", fc)
	b.add_theme_font_size_override("font_size", 14)
	b.pressed.connect(cb)
	return b


## 页签按钮：选中态 = 金色底边（下划线语义）
func _tab_btn(text: String, is_on: bool) -> Button:
	var b := _btn(text, func(): pass)
	b.toggle_mode = true
	b.button_pressed = is_on
	var on := _style_box(C_SURFACE2, 6)
	on.border_width_bottom = 3
	on.border_color = C_ACCENT
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	return b


func _first_button(node: Node) -> Button:
	if node is Button:
		return node
	for c in node.get_children():
		var r := _first_button(c)
		if r != null:
			return r
	return null


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
	settle_screen = ArpgHudSettle.new(self)
	settle_screen.build()
	pause_screen = ArpgHudPause.new(self)
	pause_screen.build()
	_build_party_panel()
	_build_debug_panel()
	menu_screen = ArpgHudMenu.new(self)
	menu_screen.build()
	shop_screen = ArpgHudShop.new(self)
	shop_screen.build()
	_build_toast()
	_build_banner()
	_build_dialogue()


## 队伍面板：可滚动，支持任意 N（需求书 §5.7）
func _build_toast() -> void:
	# 章节卡衬底：「新任务解锁」用大字号+暗底横条（章节推进的仪式感），普通完成用小字
	toast_bg = ColorRect.new()
	toast_bg.color = Color(0.04, 0.04, 0.08, 0.78)
	toast_bg.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_bg.anchor_left = 0.5
	toast_bg.anchor_right = 0.5
	toast_bg.offset_left = -260
	toast_bg.offset_right = 260
	toast_bg.offset_top = 66
	toast_bg.offset_bottom = 106
	toast_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_bg.visible = false
	root.add_child(toast_bg)
	toast_label = _label(16, Color(1, 0.9, 0.4))
	toast_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_label.anchor_left = 0.5
	toast_label.anchor_right = 0.5
	toast_label.offset_left = -220
	toast_label.offset_right = 220
	toast_label.offset_top = 74
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.visible = false
	root.add_child(toast_label)


func set_quest_toast(text: String) -> void:
	# 队列式 toast：连续完成+解锁两条同帧弹出时排队轮播，不再互相覆盖成一行
	_toast_queue.append(text)
	if _toast_playing:
		return
	_toast_playing = true
	_play_next_toast()


var _toast_queue: Array = []
var _toast_playing := false


func _play_next_toast() -> void:
	if _toast_queue.is_empty():
		_toast_playing = false
		toast_label.visible = false
		if toast_bg != null:
			toast_bg.visible = false
		return
	var txt: String = str(_toast_queue.pop_front())
	var is_chapter: bool = txt.begins_with("新任务解锁")
	toast_label.text = txt
	toast_label.visible = true
	toast_label.modulate.a = 0.0
	# 章节卡（新任务解锁）：大金字+暗底横条；普通完成保持小字
	if is_chapter:
		toast_label.add_theme_font_size_override("font_size", 22)
		toast_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.25))
		toast_label.offset_top = 72
		toast_bg.visible = true
		toast_bg.modulate.a = 0.0
	else:
		toast_label.add_theme_font_size_override("font_size", 16)
		toast_label.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
		toast_label.offset_top = 74
		if toast_bg != null:
			toast_bg.visible = false
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(toast_label, "modulate:a", 1.0, 0.18)
	if is_chapter:
		tw.tween_property(toast_bg, "modulate:a", 1.0, 0.18)
	tw.chain().tween_interval(1.8)
	tw.chain().tween_property(toast_label, "modulate:a", 0.0, 0.35)
	if is_chapter:
		tw.parallel().tween_property(toast_bg, "modulate:a", 0.0, 0.35)
	tw.chain().tween_callback(_play_next_toast)


## 菜单屏（hud_menu.gd 屏组件）：外部调用点保持不变
func show_menu_ui(snap: Dictionary) -> void:
	menu_screen.show(snap)


func hide_menu_ui() -> void:
	menu_screen.hide()

func _unhandled_input(event: InputEvent) -> void:
	if dlg_active:
		var adv := false
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			adv = true
		elif event is InputEventKey and event.pressed and not event.echo \
				and event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
			adv = true
		if adv:
			get_viewport().set_input_as_handled()
			_dlg_adv = true
			return
	if shop_screen != null and shop_screen.shop_root != null and shop_screen.shop_root.visible:
		# 地牢商店开着时 ESC 只关商店（而不是叠一层暂停菜单）
		if event.is_action_pressed("ui_cancel"):
			close_shop()
			get_viewport().set_input_as_handled()
		return
	if menu_screen.menu_root != null and menu_screen.menu_root.visible:
		if event.is_action_pressed("char_menu") or event.is_action_pressed("ui_cancel"):
			game._menu_close()
			get_viewport().set_input_as_handled()




func refresh_menu_ui() -> void:
	menu_screen.refresh()


## 暂停屏（hud_pause.gd 屏组件）：外部调用点保持不变
func show_pause() -> void:
	pause_screen.show()


func hide_pause() -> void:
	pause_screen.hide()


## 商店屏（hud_shop.gd 屏组件）：外部调用点保持不变
func show_shop(from_dungeon: bool = false) -> void:
	shop_screen.show(from_dungeon)


func close_shop() -> void:
	shop_screen.close()


## 结算屏（hud_settle.gd 屏组件）：main 的调用点保持不变
func show_settle(title: String, title_col: Color, stats: String, goods: String, total: int,
		best_combo: int = 0, paid: int = 0, debt_left: int = 0) -> void:
	settle_screen.show(title, title_col, stats, goods, total, best_combo, paid, debt_left)


## 商店统一关闭出口：地牢模式要恢复世界（结算屏模式本来就 paused，不动）
## 队伍面板：可滚动，支持任意 N（需求书 §5.7）
func _build_party_panel() -> void:
	var party_panel := _panel_box()
	party_panel.position = Vector2(12, 106)
	party_panel.custom_minimum_size = Vector2(258, 0)
	root.add_child(party_panel)
	party_scroll = ScrollContainer.new()
	party_scroll.custom_minimum_size = Vector2(240, 96)
	party_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	party_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	party_panel.add_child(party_scroll)
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

func _menu_row(text: String, btn_defs: Array = [], row_color: Color = Color.WHITE, btn_disabled: bool = false) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var l: Label = _label(14, row_color, text)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	for bd in btn_defs:
		var b: Button = _btn(str(bd[0]), bd[1])
		b.disabled = btn_disabled
		h.add_child(b)
	return h



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
	var sb := _style_box(C_SURFACE, 12, true)
	sb.set_content_margin_all(16)
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

	var top_right_panel := _panel_box()
	top_right_panel.anchor_left = 1.0
	top_right_panel.anchor_right = 1.0
	top_right_panel.offset_left = -232
	top_right_panel.offset_right = -8
	top_right_panel.offset_top = 6
	play_hud.add_child(top_right_panel)
	var top_right := VBoxContainer.new()
	top_right.add_theme_constant_override("separation", 3)
	top_right_panel.add_child(top_right)
	gold_label = _label(15, Color(1, 0.86, 0.36))
	gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(gold_label)
	debt_label = _label(14, Color(1, 0.66, 0.55))
	debt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(debt_label)
	bag_label = _label(14, Color(1, 1, 1))
	bag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(bag_label)
	skill_label = _label(13, Color(0.8, 0.9, 1))
	skill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(skill_label)
	perf_label = _label(12, Color(0.6, 1.0, 0.75, 0.9))
	perf_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(perf_label)

	# 小地图：右下角（左下是战斗日志、右上是数值面板，右下最干净）
	minimap = Minimap.new()
	play_hud.add_child(minimap)
	minimap.bind_hud(self)

	# 战斗日志底板：半透明黑衬底，日志不再直接压在地砖上（视觉走查反馈）
	# 无日志时整块隐藏，不留空黑框（第二轮走查反馈）
	log_bg = ColorRect.new()
	log_bg.color = Color(0.03, 0.035, 0.05, 0.62)
	log_bg.anchor_top = 1.0
	log_bg.anchor_bottom = 1.0
	log_bg.offset_left = 8
	log_bg.offset_top = -146
	log_bg.offset_right = 526
	log_bg.offset_bottom = -42
	log_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_bg.visible = false
	play_hud.add_child(log_bg)
	play_hud.move_child(log_bg, 0)
	log_label = _label(13, Color(1, 1, 1, 0.92))
	log_label.visible = false
	log_label.anchor_top = 1.0
	log_label.anchor_bottom = 1.0
	log_label.offset_left = 16
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


## 金币显示：吃到掉落时闪一下（modulate 高亮再回落，不受容器布局影响）
func pop_gold(v: int) -> void:
	if gold_label == null:
		return
	gold_label.text = "%d G" % v
	if _gold_tw != null and _gold_tw.is_valid():
		_gold_tw.kill()
	gold_label.modulate = Color(1.75, 1.5, 0.75)
	_gold_tw = create_tween()
	_gold_tw.tween_property(gold_label, "modulate", Color.WHITE, 0.30)


## 静默刷新（商店买卖/读档后同步，不做高亮）
func set_gold(v: int) -> void:
	if gold_label != null:
		gold_label.text = "%d G" % v


func update_bars(player: ArpgPlayer, bag_n: int, potion_n: int, floor_no: int, boss_floor: bool) -> void:
	hp_bar.value = float(player.hp) / player.max_hp
	sp_bar.value = float(player.sp) / player.max_sp
	xp_bar.value = float(player.xp) / ArpgBalance.xp_need(player.level)
	lv_label.text = "Lv %d    攻 %d    HP %d/%d" % [player.level, player.atk, player.hp, player.max_hp]
	if debt_label != null and game != null and game.rpg != null:
		var d: int = game.rpg.debt
		var cleared := d <= 0
		debt_label.text = "债务已清零" if cleared else "债务 %dG" % d
		if cleared != _debt_clear_shown:
			_debt_clear_shown = cleared
			debt_label.add_theme_color_override("font_color",
				C_ACCENT if cleared else Color(1, 0.66, 0.55))
	floor_label.text = "地下 %d 层%s" % [floor_no, "　★ BOSS" if boss_floor else ""]
	bag_label.text = "背包 %d/%d    药水×%d [Q]" % [bag_n, ArpgBalance.BAG_CAP, potion_n]
	var sks: Array = player.available_skills()
	var sk: Dictionary = ArpgBalance.data.get("skills", {}).get(str(sks[0]) if sks.size() > 0 else "", {})
	if sk.is_empty():
		sk = player.tpl.get("skill", {})
	# 技能槽提示：列出已解锁槽位（K/L/U）；未满 3 槽时预告下一个解锁（成长钩子）
	var slot_txt := ""
	for si in sks.size():
		var sd: Dictionary = ArpgBalance.data.get("skills", {}).get(str(sks[si]), {})
		slot_txt += "%s[%s] " % [sd.get("name", "?"), ["K", "L", "U"][si] if si < 3 else "?"]
	if sks.size() < 3:
		var next_def: Dictionary = {}
		for sid2 in ArpgBalance.data.get("char_skills", {}).get(player.char_id, []):
			var dd: Dictionary = ArpgBalance.data.get("skills", {}).get(str(sid2), {})
			if not dd.is_empty() and player.level < int(dd.get("unlock_level", 1)) \
					and (next_def.is_empty() or int(dd.get("unlock_level", 1)) < int(next_def.get("unlock_level", 1))):
				next_def = dd
		if not next_def.is_empty():
			slot_txt += "Lv%d解锁「%s」" % [int(next_def["unlock_level"]), next_def.get("name", "?")]
	skill_label.text = slot_txt + ("  冷却中" if player.skill_cd > 0.0 else "  就绪")


func set_perf(fps: int, mob_n: int, proj_n: int, sim_ms: float) -> void:
	perf_label.text = "FPS %d · 敌 %d · 弹 %d · AI %.2fms" % [fps, mob_n, proj_n, sim_ms]


func log(msg: String) -> void:
	_logs.append(msg)
	while _logs.size() > 5:
		_logs.pop_front()
	log_label.text = "\n".join(_logs)
	if not log_label.visible:
		log_label.visible = true
		log_bg.visible = true


func set_prompt(text: String) -> void:
	prompt_label.visible = text != ""
	prompt_label.text = text


func show_boss_bar(show_it: bool, ratio: float, boss_name_text: String) -> void:
	boss_box.visible = show_it
	boss_bar.value = ratio
	boss_name.text = boss_name_text


# ———————— 事件 UI（横幅 / 对话框） ————————

## 存档读档回调（core/save/save_system）：层号刷到顶栏（事件引擎把楼层当回合）
func update_turn(n: int, phase: String) -> void:
	floor_label.text = "地下 %d 层 · %s" % [n, phase]


func _build_banner() -> void:
	banner_root = Control.new()
	banner_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	banner_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_root.visible = false
	root.add_child(banner_root)
	banner_bg = ColorRect.new()
	banner_bg.anchor_right = 1.0
	banner_bg.anchor_top = 0.40
	banner_bg.anchor_bottom = 0.54
	banner_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_root.add_child(banner_bg)
	banner_label = _label(26, C_TEXT)
	banner_label.anchor_right = 1.0
	banner_label.anchor_bottom = 1.0
	banner_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_root.add_child(banner_label)


## 楼层/事件横幅：淡入停留淡出（事件序列 await 本函数结束再继续）
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
	banner_root.modulate.a = 1.0


func _build_dialogue() -> void:
	dlg_panel = _panel_box()
	dlg_panel.anchor_left = 0.5
	dlg_panel.anchor_right = 0.5
	dlg_panel.anchor_top = 1.0
	dlg_panel.anchor_bottom = 1.0
	dlg_panel.offset_left = -420
	dlg_panel.offset_right = 420
	dlg_panel.offset_top = -186
	dlg_panel.offset_bottom = -20
	dlg_panel.visible = false
	root.add_child(dlg_panel)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	dlg_panel.add_child(h)
	dlg_portrait = TextureRect.new()
	dlg_portrait.custom_minimum_size = Vector2(96, 96)
	dlg_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dlg_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	dlg_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	h.add_child(dlg_portrait)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 4)
	h.add_child(v)
	dlg_name = _label(15, C_ACCENT)
	v.add_child(dlg_name)
	dlg_text = _label(14, C_TEXT)
	dlg_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dlg_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # 压满 VBox 宽度（走查：440px 就折行）
	dlg_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dlg_text.custom_minimum_size = Vector2(560, 0)
	v.add_child(dlg_text)
	v.add_child(_label(12, Color(0.88, 0.86, 0.72), "空格 / 点击 · 继续"))


## 事件对话框：逐行显示、等输入推进；期间暂停世界（退出时恢复原暂停态）
func show_dialogue(speaker_id: String, lines: Array) -> void:
	if lines.is_empty():
		return
	var sid: String = SPEAKER_ALIAS.get(speaker_id, speaker_id)
	var tpl: Dictionary = ArpgBalance.CHARS.get(sid, {})
	if tpl.is_empty():
		dlg_portrait.visible = false
		dlg_name.text = "旁白"
	else:
		dlg_portrait.visible = true
		var at := AtlasTexture.new()
		at.atlas = load(str(tpl["sprite"][0]))
		at.region = Rect2(float(tpl["sprite"][1]), float(tpl["sprite"][2]), 48, 48)
		dlg_portrait.texture = at
		dlg_name.text = str(tpl["name"])
	dlg_panel.visible = true
	dlg_active = true
	# 对话期间收起战斗日志：两者同占左下，层级冲突会截断日志文本（视觉走查反馈）
	var log_was := log_label.visible
	log_label.visible = false
	log_bg.visible = false
	var was_paused := get_tree().paused
	get_tree().paused = true
	for line in lines:
		dlg_text.text = str(line)
		_dlg_adv = false
		while not _dlg_adv:
			await get_tree().process_frame
	dlg_active = false
	dlg_panel.visible = false
	log_label.visible = log_was
	log_bg.visible = log_was
	get_tree().paused = was_paused


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
		"移动 WASD/左摇杆    普攻 J/Z/A·RT    技能 K/X·LT / L    药水 Q/Y    互动 E/B    暂停 Esc/Start
Tab 切换主控    T 队伍指令    C 角色菜单    F1 调试面板    F9/F10 存档    F2 重载平衡    F3 重载地图    F4 重开
升级完全回满 · 宝箱陷阱 · 背包上限 20 · 击败第 5 层魔王凯旋 · 手柄带震动 · 店铺试营业")
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
	v.add_child(_btn("选择出击", func(): start_selected.emit(id), "primary"))
	v.add_child(_btn("试玩手搭场景", func():
		scene_mode = true
		start_selected.emit(id)))
	return panel


# ———————— 结算 ————————

# ———————— 暂停 ————————

func show_select() -> void:
	select_root.visible = true


func hide_select() -> void:
	select_root.visible = false
