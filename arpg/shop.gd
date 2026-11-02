class_name ArpgShop
extends RefCounted
## 商店系统（经营循环的地面端）：
## · 卖出：背包中的商品按 value × sell_ratio 换金币（装备按其价格）
## · 买入：固定货架 + 按玩家等级解锁的高阶货架；金币支付入背包/直接装备
## · 与背包/装备/任务(collect)/金币结算互通；每次交易都有日志与音效反馈

var main: Node


func setup(m: Node) -> void:
	main = m


func stock() -> Array:
	var st: Dictionary = ArpgBalance.data.get("shop_stock", {})
	var out := []
	for id in st.get("always", []):
		out.append(id)
	for id in st.get("tier2", []):
		out.append(id)
	for id in st.get("tier3", []):
		out.append(id)
	return out


func price_of(item_id: String) -> int:
	var eq: Dictionary = ArpgBalance.data.get("equipment", {}).get(item_id, {})
	var it: Dictionary = ArpgBalance.ITEMS.get(item_id, {})
	return int(eq.get("price", it.get("value", 0))) if not eq.is_empty() else int(it.get("value", 0)) * 2


func name_of(item_id: String) -> String:
	var eq: Dictionary = ArpgBalance.data.get("equipment", {}).get(item_id, {})
	if not eq.is_empty():
		return str(eq["name"])
	return str(ArpgBalance.ITEMS.get(item_id, {}).get("name", item_id))


## 买入：金币足 → 物品进背包（容量满失败）；返回错误文案（空串=成功）
func buy(item_id: String) -> String:
	var price := price_of(item_id)
	if price <= 0:
		return "该物品不可购买"
	if main.rpg.gold < price:
		return "金币不足（需 %dG）" % price
	if not main.rpg.inventory.add(item_id):
		return "背包已满"
	main.rpg.gold -= price
	main.play_sfx("cursor", -6.0)
	main.hud.log("购入 %s（-%dG）" % [name_of(item_id), price])
	return ""


## 卖出：按格卖（含堆叠全部）；商品按 value×sell_ratio，装备按价格×sell_ratio
func sell_slot(slot_idx: int) -> String:
	var rows: Array = main.rpg.inventory.rows()
	if slot_idx < 0 or slot_idx >= rows.size():
		return "没有这个物品"
	var r: Dictionary = rows[slot_idx]
	var ratio := float(ArpgBalance.data.get("sell_ratio", 0.6))
	var unit_value := int(r["value"])
	var gain := maxi(1, int(round(unit_value * ratio))) * int(r["count"])
	var iid: String = r["id"]
	if not main.rpg.inventory.remove(iid, int(r["count"])):
		return "卖出失败"
	# 装备着的东西不可卖：remove 前已由 UI 屏蔽（装备中的物品不在背包内）
	main.rpg.gold += gain
	main.play_sfx("heal", -10.0)
	main.hud.log("卖出 %s ×%d（+%dG）" % [r["name"], r["count"], gain])
	return ""


## 一键卖出全部商品类（结算屏快捷入口）；装备类保留
func sell_all_goods() -> int:
	var total := 0
	var ratio := float(ArpgBalance.data.get("sell_ratio", 0.6))
	var rows: Array = main.rpg.inventory.rows()
	for r in rows:
		if r["kind"] != "goods":
			continue
		var gain := maxi(1, int(round(int(r["value"]) * ratio))) * int(r["count"])
		if main.rpg.inventory.remove(str(r["id"]), int(r["count"])):
			total += gain
	if total > 0:
		main.rpg.gold += total
		main.hud.log("战利品售出：+%dG" % total)
		main.play_sfx("heal", -8.0)
	return total
