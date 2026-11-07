class_name ArpgHudSettle
extends RefCounted
## 结算屏（P1-2 hud 按屏拆分第一步）：结算面板构建 / 展示 / 继续经营 / 一键卖出。
## 屏组件模式：持有 hud 引用（root 挂载点 / _label 等工厂 / back_to_title 信号 / game），
## 控件成员全部本类持有，hud.show_settle 转调本类——后续商店/菜单屏照此模式拆。

var hud: Node

var settle_root: Control
var settle_title: Label
var settle_stats: Label
var settle_goods: Label
var settle_total: Label
var settle_combo: Label
var settle_debt: Label


func _init(h: Node) -> void:
	hud = h


func build() -> void:
	settle_root = Control.new()
	settle_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	settle_root.visible = false
	hud.root.add_child(settle_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.66)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	settle_root.add_child(dim)
	var panel: PanelContainer = hud._panel_box()
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
	settle_title = hud._label(34, Color(1, 0.95, 0.75))
	settle_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(settle_title)
	settle_stats = hud._label(15, Color(1, 1, 1))
	v.add_child(settle_stats)
	var sep := HSeparator.new()
	v.add_child(sep)
	var goods_title: Label = hud._label(16, Color(1, 0.9, 0.6), "带回的商品（入库待售）")
	v.add_child(goods_title)
	settle_goods = hud._label(14, Color(0.9, 0.95, 1))
	v.add_child(settle_goods)
	settle_total = hud._label(20, Color(1, 0.85, 0.35))
	settle_total.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(settle_total)
	settle_combo = hud._label(16, Color(1, 0.85, 0.3))
	settle_combo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(settle_combo)
	settle_debt = hud._label(18, Color(1, 0.72, 0.6))
	settle_debt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(settle_debt)
	var bh := HBoxContainer.new()
	bh.alignment = BoxContainer.ALIGNMENT_CENTER
	bh.add_theme_constant_override("separation", 12)
	v.add_child(bh)
	bh.add_child(hud._btn("回到标题", func(): hud.back_to_title.emit()))
	# 经营循环闭环：金币/装备/天数跨局保留（rpg_state），直接开启下一天的打捞
	# （文本不带天数——build 在 _ready 期 rpg 还未 setup，天数点击后由开场日志呈现）
	bh.add_child(hud._btn("继续经营 ▸ 下一局", func(): hide_and_continue(), "primary"))
	bh.add_child(hud._btn("进入店铺", func(): hud.show_shop()))
	bh.add_child(hud._btn("一键卖出战利品", func(): sell_loot()))


func hide_and_continue() -> void:
	settle_root.visible = false
	hud.game.start_run(hud.game.char_id)


func sell_loot() -> void:
	var g: int = hud.game.shop.sell_all_goods()
	if g > 0:
		settle_total.text = "已售出 +%dG（金币 %dG）" % [g, hud.game.rpg.gold]


func show(title: String, title_col: Color, stats: String, goods: String, total: int,
		best_combo: int = 0, paid: int = 0, debt_left: int = 0) -> void:
	settle_title.text = title
	settle_title.add_theme_color_override("font_color", title_col)
	settle_stats.text = stats
	settle_goods.text = goods
	settle_total.text = "商品总价值：%d G" % total
	if settle_combo != null:
		settle_combo.text = "最高连杀 ×%d" % best_combo
	# 跨局成就行：历史积累（露塞提娅式经营记分簿）
	var life = hud.game.rpg if hud.game != null and hud.game.rpg != null else hud._menu_ctx.get("rpg", null)
	if life != null:
		settle_combo.text += "　·　历史：累计击杀 %d · 最深 %d 层 · 最高连杀 ×%d" % [
			life.lifetime_kills, life.best_floor, life.best_combo]
	if settle_debt != null:
		if debt_left <= 0:
			settle_debt.text = "债务清零！"
			settle_debt.add_theme_font_size_override("font_size", 30)
			settle_debt.add_theme_color_override("font_color", hud.C_ACCENT)
		else:
			settle_debt.text = "偿还债务 %dG（剩余 %dG）" % [paid, debt_left]
			settle_debt.add_theme_font_size_override("font_size", 18)
			settle_debt.add_theme_color_override("font_color", Color(1, 0.72, 0.6))
	settle_root.visible = true
