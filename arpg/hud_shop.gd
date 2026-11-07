class_name ArpgHudShop
extends RefCounted
## 商店屏（P1-2 hud 按屏拆分第二步）：买入/卖出/强化三页签 + 地牢商人开关（期间暂停世界）。
## 屏组件模式（同 hud_settle）：持有 hud 引用（root/工厂方法/game/_menu_ctx），控件成员全部本类持有。

var hud: Node

var shop_root: Control
var shop_gold: Label
var shop_list: VBoxContainer
var shop_tab := "buy"
var shop_tab_nodes: Array = []   # 买入/卖出/强化页签按钮（选中态高亮用）
var shop_in_dungeon := false   # 地牢商人打开的商店：期间暂停世界，关闭恢复


func _init(h: Node) -> void:
	hud = h


func build() -> void:
	shop_root = Control.new()
	shop_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	shop_root.visible = false
	hud.root.add_child(shop_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	shop_root.add_child(dim)
	var panel: PanelContainer = hud._panel_box()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	shop_root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	shop_gold = hud._label(20, hud.C_ACCENT)
	v.add_child(shop_gold)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	v.add_child(tabs)
	shop_tab_nodes = []
	for pair in [["买入", "buy"], ["卖出", "sell"], ["强化", "forge"]]:
		var b: Button = hud._tab_btn(pair[0], pair[1] == "buy")
		b.set_meta("tab", pair[1])
		b.pressed.connect(func():
			shop_tab = pair[1]
			refresh())
		tabs.add_child(b)
		shop_tab_nodes.append(b)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_theme_stylebox_override("panel", hud._style_box(Color(0, 0, 0, 0.25), 8, true))
	v.add_child(scroll)
	shop_list = VBoxContainer.new()
	shop_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shop_list.add_theme_constant_override("separation", 4)
	scroll.add_child(shop_list)
	var close: Button = hud._btn("离开商店 (Esc)", func(): close())
	var ch := HBoxContainer.new()
	ch.alignment = BoxContainer.ALIGNMENT_CENTER
	ch.add_child(close)
	v.add_child(ch)


func show(from_dungeon: bool = false) -> void:
	shop_root.visible = true
	shop_in_dungeon = from_dungeon
	if from_dungeon:
		hud.get_tree().paused = true   # 地牢里逛街时世界暂停，不然怪在你身后磨刀
	refresh()
	var fb = hud._first_button(shop_list)
	if fb != null:
		fb.grab_focus()


## 商店统一关闭出口：地牢模式要恢复世界（结算屏模式本来就 paused，不动）
func close() -> void:
	shop_root.visible = false
	if shop_in_dungeon:
		shop_in_dungeon = false
		hud.get_tree().paused = false


func refresh() -> void:
	var rpg = hud._menu_ctx["rpg"] if not hud._menu_ctx.is_empty() else hud.game.rpg
	shop_gold.text = "金币 %dG" % rpg.gold
	for c in shop_list.get_children():
		c.queue_free()
	if shop_tab == "buy":
		for iid in hud.game.shop.stock():
			var price: int = hud.game.shop.price_of(iid)
			var can: bool = rpg.gold >= price
			var row: Control = hud._menu_row("%s —— %dG%s" % [hud.game.shop.name_of(iid), price, "" if can else "（金币不足）"],
				[["购买", func():
					var err: String = hud.game.shop.buy(iid)
					if err != "":
						hud.game.hud.log(err)
					refresh()]], hud.C_TEXT if can else hud.C_TEXT_DIM, not can)
			shop_list.add_child(row)
	elif shop_tab == "forge":
		# 铁砧：已拥有（背包+已穿）的装备强化——金币的第二出口，与还债的抉择张力
		var seen := {}
		var eq_table: Dictionary = ArpgBalance.data.get("equipment", {})
		for slot in rpg.equipped:
			var eid: String = str(rpg.equipped[slot])
			if eid != "" and eq_table.has(eid) and not seen.has(eid):
				seen[eid] = true
				shop_list.add_child(_forge_row(rpg, eid))
		for r2 in rpg.inventory.rows():
			if str(r2.get("kind", "")) == "equip" and eq_table.has(str(r2["id"])) and not seen.has(str(r2["id"])):
				seen[str(r2["id"])] = true
				shop_list.add_child(_forge_row(rpg, str(r2["id"])))
		if seen.is_empty():
			shop_list.add_child(hud._label(13, hud.C_TEXT_DIM, "（还没有装备——先去商店买一件或从地牢打捞）"))
	else:
		var rows: Array = rpg.inventory.rows()
		if rows.is_empty():
			shop_list.add_child(hud._label(13, hud.C_TEXT_DIM, "（背包空空如也 · 去地牢捡点战利品）"))
		for i in rows.size():
			var r: Dictionary = rows[i]
			var gain: int = maxi(1, int(round(int(r["value"]) * float(ArpgBalance.data.get("sell_ratio", 0.6))))) * int(r["count"])
			shop_list.add_child(hud._menu_row("%s ×%d —— +%dG" % [r["name"], r["count"], gain],
				[["卖出", func():
					hud.game.shop.sell_slot(i)
					refresh()]]))
	shop_list.add_child(hud._label(11, hud.C_TEXT_DIM, " "))
	shop_list.add_child(hud._label(11, hud.C_TEXT_DIM, "打捞提示：战利品在结算时自动折价还债，背包不留也行。"))
	_refresh_tabs()


## 铁砧行：装备名 +N / 下级费用 / 强化按钮（金币不足置灰）
func _forge_row(rpg, item_id: String) -> Control:
	var eq: Dictionary = ArpgBalance.data.get("equipment", {}).get(item_id, {})
	var cur: int = int(rpg.forge_level.get(item_id, 0))
	var at_max: bool = cur >= int(ArpgBalance.data.get("forge", {}).get("max_plus", 3))
	var cost: int = rpg.forge_cost(item_id)
	var can: bool = not at_max and rpg.gold >= cost
	var plus_txt := " +%d" % cur if cur > 0 else ""
	var next_txt := " —— %dG" % cost if not at_max else "（已至上限）"
	var row: Control = hud._menu_row("%s%s —— 攻+%d%s" % [eq.get("name", item_id), plus_txt,
		int(eq.get("atk", 0)) + cur * int(ArpgBalance.data.get("forge", {}).get("atk_per", 2)), next_txt],
		[["强化", func():
			var err: String = rpg.forge_item(item_id)
			if err != "":
				hud.game.hud.log(err)
			else:
				hud.game.hud.log("%s 强化成功，当前 +%d" % [eq.get("name", item_id), int(rpg.forge_level.get(item_id, 0))])
				hud.game.play_sfx("cursor")
			refresh()]], hud.C_TEXT if can else hud.C_TEXT_DIM, not can)
	return row


## 页签选中态：当前页高亮（视觉走查反馈：页签看不出差别）
func _refresh_tabs() -> void:
	for t in shop_tab_nodes:
		var is_cur: bool = str(t.get_meta("tab", "")) == shop_tab
		t.modulate = Color(1, 1, 1, 1.0) if is_cur else Color(1, 1, 1, 0.45)
