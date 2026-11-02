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

# 角色菜单 / 商店 / 任务提示
var game: Node
var menu_root: Control
var menu_tabs := {}
var menu_content: VBoxContainer
var menu_header: Label
var _menu_tab := "状态"
var _menu_ctx := {}
var shop_root: Control
var shop_gold: Label
var shop_list: VBoxContainer
var shop_tab := "buy"
var toast_label: Label

var _logs := []

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
	_build_settle()
	_build_pause()
	_build_party_panel()
	_build_debug_panel()
	_build_menu_ui()
	_build_shop_ui()
	_build_toast()


## 队伍面板：可滚动，支持任意 N（需求书 §5.7）
func _build_toast() -> void:
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
	toast_label.text = "任务完成：%s" % text
	toast_label.visible = true
	var tw := create_tween()
	tw.tween_interval(2.5)
	tw.tween_property(toast_label, "modulate:a", 0.0, 0.4)
	tw.tween_callback(func():
		toast_label.visible = false
		toast_label.modulate.a = 1.0)


func _build_menu_ui() -> void:
	menu_root = Control.new()
	menu_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_root.visible = false
	root.add_child(menu_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_root.add_child(dim)
	var panel := _panel_box()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -370
	panel.offset_right = 370
	panel.offset_top = -280
	panel.offset_bottom = 280
	menu_root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	menu_header = _label(20, Color(1, 0.95, 0.75))
	v.add_child(menu_header)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	v.add_child(tabs)
	for tname in ["状态", "背包", "技能", "任务", "系统"]:
		var b := _tab_btn(tname, tname == "状态")
		b.pressed.connect(_switch_menu_tab.bind(tname))
		tabs.add_child(b)
		menu_tabs[tname] = b
	menu_content = VBoxContainer.new()
	menu_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	menu_content.add_theme_constant_override("separation", 6)
	v.add_child(menu_content)
	var hint := _label(12, Color(1, 1, 1, 0.55), "C / Esc 关闭 · 菜单打开时游戏暂停")
	v.add_child(hint)
	menu_root.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if menu_root != null and menu_root.visible:
		if event.is_action_pressed("char_menu") or event.is_action_pressed("ui_cancel"):
			game._menu_close()
			get_viewport().set_input_as_handled()


func _switch_menu_tab(tname: String) -> void:
	_menu_tab = tname
	refresh_menu_ui()


func refresh_menu_ui() -> void:
	if not menu_root.visible or _menu_ctx.is_empty():
		return
	var rpg = _menu_ctx["rpg"]
	var player = _menu_ctx["player"]
	menu_header.text = "%s · Lv %d · %dG" % [player.uname, player.level, rpg.gold]
	for t in menu_tabs:
		menu_tabs[t].button_pressed = t == _menu_tab
	for c in menu_content.get_children():
		c.queue_free()
	match _menu_tab:
		"状态":
			_page_status()
		"背包":
			_page_bag()
		"技能":
			_page_skills()
		"任务":
			_page_quests()
		"系统":
			_page_sys()


func refresh_shop() -> void:
	var rpg = _menu_ctx["rpg"] if not _menu_ctx.is_empty() else game.rpg
	shop_gold.text = "金币 %dG" % rpg.gold
	for c in shop_list.get_children():
		c.queue_free()
	if shop_tab == "buy":
		for iid in game.shop.stock():
			var price: int = game.shop.price_of(iid)
			var can: bool = rpg.gold >= price
			var row := _menu_row("%s —— %dG" % [game.shop.name_of(iid), price],
				[["购买", func():
					var err: String = game.shop.buy(iid)
					refresh_shop()]], C_TEXT if can else C_TEXT_DIM)
			shop_list.add_child(row)
	else:
		var rows: Array = rpg.inventory.rows()
		if rows.is_empty():
			shop_list.add_child(_label(13, C_TEXT_DIM, "（背包空空如也 · 去地牢捡点战利品）"))
		for i in rows.size():
			var r: Dictionary = rows[i]
			var gain: int = maxi(1, int(round(int(r["value"]) * float(ArpgBalance.data.get("sell_ratio", 0.6))))) * int(r["count"])
			shop_list.add_child(_menu_row("%s ×%d —— +%dG" % [r["name"], r["count"], gain],
				[["卖出", func():
					game.shop.sell_slot(i)
					refresh_shop()]]))


func _menu_row(text: String, btn_defs: Array = [], row_color: Color = Color.WHITE) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var l := _label(14, row_color, text)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	for bd in btn_defs:
		h.add_child(_btn(str(bd[0]), bd[1]))
	return h


func _page_status() -> void:
	var rpg = _menu_ctx["rpg"]
	var player = _menu_ctx["player"]
	var need: int = int(ArpgBalance.xp_need(player.level))
	menu_content.add_child(_menu_row("等级 %d    经验 %d/%d" % [player.level, player.xp, need]))
	menu_content.add_child(_menu_row("HP %d/%d    SP %d/%d" % [player.hp, player.max_hp, player.sp, player.max_sp]))
	menu_content.add_child(_menu_row("攻击 %d（含装备）    防御 %d    移速 %d" % [player.eff_atk(), player.eff_def(), int(player.spd)]))
	menu_content.add_child(_menu_row("金币 %dG" % rpg.gold))
	menu_content.add_child(HSeparator.new())
	menu_content.add_child(_label(14, Color(1, 0.9, 0.6), "装备"))
	for slot in ArpgBalance.data.get("equip_slots", []):
		var iid: String = rpg.equipped.get(slot, "")
		var eq: Dictionary = ArpgBalance.data.get("equipment", {}).get(iid, {})
		var txt: String = ("%s：%s" % [slot, eq.get("name", "（空）")]) if iid != "" else ("%s：（空）" % slot)
		var btns := []
		if iid != "":
			btns.append(["卸下", func(): _menu_equip_off(slot)])
		menu_content.add_child(_menu_row(txt, btns))


func _page_bag() -> void:
	var rpg = _menu_ctx["rpg"]
	menu_content.add_child(_menu_row("背包 %d/%d 格" % [rpg.inventory.used(), rpg.inventory.cap]))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 230)
	var sbg := _style_box(Color(0, 0, 0, 0.25), 8, true)
	scroll.add_theme_stylebox_override("panel", sbg)
	menu_content.add_child(scroll)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 4)
	scroll.add_child(v)
	var rows: Array = rpg.inventory.rows()
	if rows.is_empty():
		v.add_child(_label(13, C_TEXT_DIM, "（空空如也 · 去地牢捡点战利品）"))
	for i in rows.size():
		var r: Dictionary = rows[i]
		var btns := []
		if r["kind"] == "use":
			btns.append(["使用", func(): _menu_use(i)])
		if r["kind"] == "equip":
			btns.append(["装备", func(): _menu_equip(str(r["id"]))])
		btns.append(["丢弃", func(): _menu_drop(i)])
		v.add_child(_menu_row("%s ×%d（%s）" % [r["name"], r["count"], r["kind"]], btns))


func _page_skills() -> void:
	var player = _menu_ctx["player"]
	var all_ids: Array = ArpgBalance.data.get("char_skills", {}).get(player.char_id, [])
	for sid in all_ids:
		var def: Dictionary = ArpgBalance.data.get("skills", {}).get(str(sid), {})
		if def.is_empty():
			continue
		var locked: bool = player.level < int(def.get("unlock_level", 1))
		var col := Color(0.55, 0.55, 0.6) if locked else Color.WHITE
		menu_content.add_child(_label(14, col, "%s  [Lv%d 解锁]  SP%d  CD%.1fs
    %s" % [
			def.get("name", sid), def.get("unlock_level", 1), def.get("sp", 0), def.get("cd", 0), def.get("desc", "")]))


func _page_quests() -> void:
	var quests = _menu_ctx["quests"]
	for r in quests.rows():
		var col := C_SUCCESS if r["state"] == "done" else (C_TEXT_DIM if r["state"] == "claimed" else Color.WHITE)
		var prog: String = ("（%d/%d）" % [r["progress"], r["count"]]) if r["state"] == "active" else ""
		var st_name: String = {"active": "进行中", "done": "已完成", "claimed": "已领取"}.get(r["state"], str(r["state"]))
		menu_content.add_child(_menu_row("%s · %s %s" % [st_name, r["name"], prog], [], col))
		menu_content.add_child(_label(12, C_TEXT_DIM, "    %s    奖励：%s" % [r["desc"], str(r["rewards"])]))
		if r["state"] == "done":
			menu_content.add_child(_menu_row("", [["领取奖励", func(): _menu_claim(str(r["id"]))]]))
		menu_content.add_child(HSeparator.new())


func _page_sys() -> void:
	menu_content.add_child(_label(14, Color(1, 0.9, 0.6), "设置"))
	for pair in [["主音量", "master_vol"], ["音乐", "music_vol"], ["音效", "sfx_vol"], ["震屏", "screen_shake"], ["手柄震动", "rumble"]]:
		var key: String = pair[1]
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		var l := _label(13, C_TEXT, pair[0])
		l.custom_minimum_size = Vector2(90, 0)
		h.add_child(l)
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.05
		slider.value = float(_menu_ctx["settings"].get_value(key))
		slider.custom_minimum_size = Vector2(180, 16)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value_changed.connect(func(v: float): _menu_ctx["settings"].set_value(key, v))
		h.add_child(slider)
		menu_content.add_child(h)
	menu_content.add_child(HSeparator.new())
	menu_content.add_child(_label(14, Color(1, 0.9, 0.6), "存档槽位"))
	for slot in [1, 2, 3]:
		var meta: Dictionary = _menu_ctx["save_sys"].slot_meta(slot)
		var txt: String = "槽位 %d：（空）" % slot if meta.is_empty() else "槽位 %d：地下 %d 层 · Lv %d · %dG" % [slot, meta["floor"], meta["level"], meta["gold"]]
		var btns := [["读取", func(): _menu_load_slot(slot)], ["覆盖保存", func(): _menu_ctx["save_sys"].save_game(slot); refresh_menu_ui()]]
		menu_content.add_child(_menu_row(txt, btns))
	menu_content.add_child(_menu_row("快捷键 F9 / F10 = 槽位 1", [["回到标题", func():
		hide_menu_ui()
		game._menu_close()
		game._back_to_title()]]))
	menu_content.add_child(_menu_row("", [["回到标题", func():
		hide_menu_ui()
		game._menu_close()
		game._back_to_title()]]))


func _menu_use(slot_idx: int) -> void:
	var rows: Array = _menu_ctx["rpg"].inventory.rows()
	if slot_idx < rows.size() and rows[slot_idx]["id"] == "potion":
		game.drink_potion()
	refresh_menu_ui()


func _menu_equip(item_id: String) -> void:
	if _menu_ctx["rpg"].equip(item_id):
		_menu_ctx["player"].recalc_equipment()
		game.hud.log("已装备")
	refresh_menu_ui()


func _menu_equip_off(slot: String) -> void:
	if _menu_ctx["rpg"].unequip(slot):
		_menu_ctx["player"].recalc_equipment()
	refresh_menu_ui()


func _menu_drop(slot_idx: int) -> void:
	var rows: Array = _menu_ctx["rpg"].inventory.rows()
	if slot_idx < rows.size():
		_menu_ctx["rpg"].inventory.remove(str(rows[slot_idx]["id"]), int(rows[slot_idx]["count"]))
	refresh_menu_ui()


func _menu_load_slot(slot: int) -> void:
	hide_menu_ui()
	var err: String = _menu_ctx["save_sys"].load_game(slot)
	if err != "":
		game.hud.log("读档失败：" + err)


func _menu_claim(qid: String) -> void:
	_menu_ctx["quests"].claim(qid)
	refresh_menu_ui()


## 队伍面板：可滚动，支持任意 N（需求书 §5.7）


func show_menu_ui(snap: Dictionary) -> void:
	menu_root.visible = true
	_menu_ctx = snap
	refresh_menu_ui()
	var fb := _first_button(menu_header.get_parent())
	if fb != null:
		fb.grab_focus()


func hide_menu_ui() -> void:
	menu_root.visible = false


func _build_shop_ui() -> void:
	shop_root = Control.new()
	shop_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	shop_root.visible = false
	root.add_child(shop_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	shop_root.add_child(dim)
	var panel := _panel_box()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -330
	panel.offset_right = 330
	panel.offset_top = -250
	panel.offset_bottom = 250
	shop_root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	shop_gold = _label(20, C_ACCENT)
	v.add_child(shop_gold)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	v.add_child(tabs)
	for pair in [["买入", "buy"], ["卖出", "sell"]]:
		var b := _tab_btn(pair[0], pair[1] == "buy")
		b.pressed.connect(func():
			shop_tab = pair[1]
			refresh_shop())
		tabs.add_child(b)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_theme_stylebox_override("panel", _style_box(Color(0, 0, 0, 0.25), 8, true))
	v.add_child(scroll)
	shop_list = VBoxContainer.new()
	shop_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shop_list.add_theme_constant_override("separation", 4)
	scroll.add_child(shop_list)
	var close := _btn("离开商店 (Esc)", func(): shop_root.visible = false)
	var ch := HBoxContainer.new()
	ch.alignment = BoxContainer.ALIGNMENT_CENTER
	ch.add_child(close)
	v.add_child(ch)
	shop_root.visible = false


func show_shop() -> void:
	shop_root.visible = true
	refresh_shop()
	var fb := _first_button(shop_list)
	if fb != null:
		fb.grab_focus()


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
	var sks: Array = player.available_skills()
	var sk: Dictionary = ArpgBalance.data.get("skills", {}).get(str(sks[0]) if sks.size() > 0 else "", {})
	if sk.is_empty():
		sk = player.tpl.get("skill", {})
	skill_label.text = "技能 %s [K/L]  消耗SP%d  %s" % [sk.get("name", "?"), sk.get("sp", 0), ("冷却中" if player.skill_cd > 0.0 else "就绪")]


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
	var bh := HBoxContainer.new()
	bh.alignment = BoxContainer.ALIGNMENT_CENTER
	bh.add_theme_constant_override("separation", 12)
	v.add_child(bh)
	bh.add_child(_btn("回到标题", func(): back_to_title.emit()))
	bh.add_child(_btn("进入店铺", func(): show_shop(), "primary"))
	bh.add_child(_btn("一键卖出战利品", func(): _sell_loot_from_settle()))


func _sell_loot_from_settle() -> void:
	var g: int = game.shop.sell_all_goods()
	if g > 0:
		settle_total.text = "已售出 +%dG（金币 %dG）" % [g, game.rpg.gold]


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
	var b1 := _btn("继续探索", func(): resume_requested.emit(), "primary")
	v.add_child(b1)
	var b2 := _btn("撤退结算（带走全部战利品）", func(): retreat_requested.emit())
	v.add_child(b2)


func show_pause() -> void:
	pause_root.visible = true


func hide_pause() -> void:
	pause_root.visible = false


func show_select() -> void:
	select_root.visible = true


func hide_select() -> void:
	select_root.visible = false
