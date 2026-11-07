class_name ArpgHudMenu
extends RefCounted
## 角色菜单屏（P1-2 hud 按屏拆分第三步）：状态/背包/技能/任务/系统五页签。
## 屏组件模式（同 hud_settle/hud_shop）：持有 hud 引用，控件成员全部本类持有。

var hud: Node

var menu_root: Control
var menu_content: VBoxContainer
var menu_header: Label
var _menu_tab := "状态"
var _menu_ctx := {}


func _init(h: Node) -> void:
	hud = h


func build() -> void:
	menu_root = Control.new()
	menu_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_root.visible = false
	hud.root.add_child(menu_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_root.add_child(dim)
	var panel: PanelContainer = hud._panel_box()
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
	menu_header = hud._label(20, Color(1, 0.95, 0.75))
	v.add_child(menu_header)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	v.add_child(tabs)
	for tname in ["状态", "背包", "技能", "任务", "系统"]:
		var b: Button = hud._tab_btn(tname, tname == "状态")
		b.pressed.connect(_switch_menu_tab.bind(tname))
		tabs.add_child(b)
		hud.menu_tabs[tname] = b
	menu_content = VBoxContainer.new()
	menu_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	menu_content.add_theme_constant_override("separation", 6)
	v.add_child(menu_content)
	var hint: Label = hud._label(12, Color(1, 1, 1, 0.55), "C / Esc 关闭 · 菜单打开时游戏暂停")
	v.add_child(hint)
	menu_root.visible = false


func _switch_menu_tab(tname: String) -> void:
	_menu_tab = tname
	refresh()


func refresh() -> void:
	if not menu_root.visible or _menu_ctx.is_empty():
		return
	var rpg = _menu_ctx["rpg"]
	var player = _menu_ctx["player"]
	menu_header.text = "%s · Lv %d · %dG" % [player.uname, player.level, rpg.gold]
	for t in hud.menu_tabs:
		hud.menu_tabs[t].button_pressed = t == _menu_tab
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


## 铁砧行：装备名 +N / 下级费用 / 强化按钮（金币不足置灰）
func main_play_sfx() -> void:
	hud.game.play_sfx("cursor")


## 买入/卖出页签选中态：当前页高亮（视觉走查反馈：两页签看不出差别）
func _menu_row(text: String, btn_defs: Array = [], row_color: Color = Color.WHITE, btn_disabled: bool = false) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var l: Label = hud._label(14, row_color, text)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	for bd in btn_defs:
		var b: Button = hud._btn(str(bd[0]), bd[1])
		b.disabled = btn_disabled
		h.add_child(b)
	return h


func _page_status() -> void:
	var rpg = _menu_ctx["rpg"]
	var player = _menu_ctx["player"]
	var need: int = int(ArpgBalance.xp_need(player.level))
	menu_content.add_child(hud._menu_row("等级 %d    经验 %d/%d" % [player.level, player.xp, need]))
	menu_content.add_child(hud._menu_row("HP %d/%d    SP %d/%d" % [player.hp, player.max_hp, player.sp, player.max_sp]))
	menu_content.add_child(hud._menu_row("攻击 %d（含装备）    防御 %d    移速 %d" % [player.eff_atk(), player.eff_def(), int(player.spd)]))
	menu_content.add_child(hud._menu_row("金币 %dG" % rpg.gold))
	menu_content.add_child(HSeparator.new())
	menu_content.add_child(hud._label(14, Color(1, 0.9, 0.6), "装备"))
	for slot in ArpgBalance.data.get("equip_slots", []):
		var iid: String = rpg.equipped.get(slot, "")
		var eq: Dictionary = ArpgBalance.data.get("equipment", {}).get(iid, {})
		var txt: String = ("%s：%s" % [slot, eq.get("name", "（空）")]) if iid != "" else ("%s：（空）" % slot)
		var btns := []
		if iid != "":
			btns.append(["卸下", func(): _menu_equip_off(slot)])
		menu_content.add_child(hud._menu_row(txt, btns))


func _page_bag() -> void:
	var rpg = _menu_ctx["rpg"]
	menu_content.add_child(hud._menu_row("背包 %d/%d 格" % [rpg.inventory.used(), rpg.inventory.cap]))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 230)
	var sbg: StyleBoxFlat = hud._style_box(Color(0, 0, 0, 0.25), 8, true)
	scroll.add_theme_stylebox_override("panel", sbg)
	menu_content.add_child(scroll)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 4)
	scroll.add_child(v)
	var rows: Array = rpg.inventory.rows()
	if rows.is_empty():
		v.add_child(hud._label(13, hud.C_TEXT_DIM, "（空空如也 · 去地牢捡点战利品）"))
	for i in rows.size():
		var r: Dictionary = rows[i]
		var btns := []
		if r["kind"] == "use":
			btns.append(["使用", func(): _menu_use(i)])
		if r["kind"] == "equip":
			btns.append(["装备", func(): _menu_equip(str(r["id"]))])
		btns.append(["丢弃", func(): _menu_drop(i)])
		v.add_child(hud._menu_row("%s ×%d（%s）" % [r["name"], r["count"], r["kind"]], btns))


func _page_skills() -> void:
	var player = _menu_ctx["player"]
	var all_ids: Array = ArpgBalance.data.get("char_skills", {}).get(player.char_id, [])
	for sid in all_ids:
		var def: Dictionary = ArpgBalance.data.get("skills", {}).get(str(sid), {})
		if def.is_empty():
			continue
		var locked: bool = player.level < int(def.get("unlock_level", 1))
		var col := Color(0.55, 0.55, 0.6) if locked else Color.WHITE
		menu_content.add_child(hud._label(14, col, "%s  [Lv%d 解锁]  SP%d  CD%.1fs
    %s" % [
			def.get("name", sid), def.get("unlock_level", 1), def.get("sp", 0), def.get("cd", 0), def.get("desc", "")]))


func _page_quests() -> void:
	var quests = _menu_ctx["quests"]
	for r in quests.rows():
		var col: Color = hud.C_SUCCESS if r["state"] == "done" else (hud.C_TEXT_DIM if r["state"] == "claimed" else Color.WHITE)
		var prog: String = ("（%d/%d）" % [r["progress"], r["count"]]) if r["state"] == "active" else ""
		var st_name: String = {"active": "进行中", "done": "已完成", "claimed": "已领取"}.get(r["state"], str(r["state"]))
		menu_content.add_child(hud._menu_row("%s · %s %s" % [st_name, r["name"], prog], [], col))
		menu_content.add_child(hud._label(12, hud.C_TEXT_DIM, "    %s    奖励：%s" % [r["desc"], _rewards_text(r["rewards"])]))
		if r["state"] == "done":
			menu_content.add_child(hud._menu_row("", [["领取奖励", func(): _menu_claim(str(r["id"]))]]))
		menu_content.add_child(HSeparator.new())


func _page_sys() -> void:
	menu_content.add_child(hud._label(14, Color(1, 0.9, 0.6), "设置"))
	for pair in [["主音量", "master_vol"], ["音乐", "music_vol"], ["音效", "sfx_vol"], ["震屏", "screen_shake"], ["手柄震动", "rumble"]]:
		var key: String = pair[1]
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		var l: Label = hud._label(13, hud.C_TEXT, pair[0])
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
	menu_content.add_child(hud._label(14, Color(1, 0.9, 0.6), "存档槽位"))
	for slot in [1, 2, 3]:
		var meta: Dictionary = _menu_ctx["save_sys"].slot_meta(slot)
		var txt: String = "槽位 %d：（空）" % slot if meta.is_empty() else "槽位 %d：地下 %d 层 · Lv %d · %dG" % [slot, meta["floor"], meta["level"], meta["gold"]]
		var btns := [["读取", func(): _menu_load_slot(slot)], ["覆盖保存", func(): _menu_ctx["save_sys"].save_game(slot); refresh()]]
		menu_content.add_child(hud._menu_row(txt, btns))
	menu_content.add_child(hud._menu_row("快捷键 F9 / F10 = 槽位 1", [["回到标题", func():
		hud.hide_menu_ui()
		hud.game._menu_close()
		hud.game._back_to_title()]]))
	menu_content.add_child(hud._menu_row("", [["回到标题", func():
		hud.hide_menu_ui()
		hud.game._menu_close()
		hud.game._back_to_title()]]))


func _menu_use(slot_idx: int) -> void:
	var rows: Array = _menu_ctx["rpg"].inventory.rows()
	if slot_idx < rows.size() and rows[slot_idx]["id"] == "potion":
		hud.game.drink_potion()
	refresh()


func _menu_equip(item_id: String) -> void:
	if _menu_ctx["rpg"].equip(item_id):
		_menu_ctx["player"].recalc_equipment()
		hud.game.hud.log("已装备")
	refresh()


func _menu_equip_off(slot: String) -> void:
	if _menu_ctx["rpg"].unequip(slot):
		_menu_ctx["player"].recalc_equipment()
	refresh()


func _menu_drop(slot_idx: int) -> void:
	var rows: Array = _menu_ctx["rpg"].inventory.rows()
	if slot_idx < rows.size():
		_menu_ctx["rpg"].inventory.remove(str(rows[slot_idx]["id"]), int(rows[slot_idx]["count"]))
	refresh()


func _menu_load_slot(slot: int) -> void:
	hud.hide_menu_ui()
	var err: String = _menu_ctx["save_sys"].load_game(slot)
	if err != "":
		hud.game.hud.log("读档失败：" + err)


func _menu_claim(qid: String) -> void:
	_menu_ctx["quests"].claim(qid)


## 奖励字典 → 中文文本（「60G / 20 经验 / 药水×2」）；别把原始 JSON 泄给玩家
func _rewards_text(rw: Dictionary) -> String:
	var parts := []
	for key in rw:
		match str(key):
			"gold":
				parts.append("%dG" % int(rw[key]))
			"xp":
				parts.append("%d 经验" % int(rw[key]))
			"item":
				var itd: Dictionary = rw[key]
				for iid in itd:
					parts.append("%s×%d" % [ArpgBalance.ITEMS.get(str(iid), {}).get("name", str(iid)), int(itd[iid])])
	return " / ".join(parts)
	refresh()


## 队伍面板：可滚动，支持任意 N（需求书 §5.7）


func show(snap: Dictionary) -> void:
	menu_root.visible = true
	_menu_ctx = snap
	refresh()
	var fb: Button = hud._first_button(menu_header.get_parent())
	if fb != null:
		fb.grab_focus()


func hide() -> void:
	menu_root.visible = false


