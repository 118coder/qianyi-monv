class_name ArpgEconomy
extends RefCounted
## 经营经济结算（P1-2 从 main._settle 拆出）：还债 / 日租 / 跨局成就统计。
## 露塞提娅循环的「账本」：金币 → 还债 + 店租，付不起的租金滚进债务（雪球压力）。
## 数据全部在 rpg_state（跨楼层/随存档），本类只做「结算时刻的账目操作」。

var main: Node


func setup(m: Node) -> void:
	main = m


## 结算经济账。返回：
##  { paid: 本局还债额, overdue: 债主超期天数（0 = 未超期）, rent_paid: 本次实付租金 }
func settle() -> Dictionary:
	var rpg = main.rpg
	# ① 还债：金币尽力偿（结算屏展示的「偿还债务 XG」）
	var paid: int = mini(rpg.gold, rpg.debt)
	if paid > 0:
		rpg.gold -= paid
		rpg.debt_paid += paid
		rpg.debt -= paid
	# ② 跨局成就统计（历史击杀/最深楼层/最高连杀，随存档走）
	rpg.lifetime_kills += main.kills
	rpg.best_floor = maxi(rpg.best_floor, main.floor_no)
	rpg.best_combo = maxi(rpg.best_combo, main.combo_best)
	# ③ 一天过去 → 收店租（露塞提娅循环的固定支出压力）
	var rent_cfg: Dictionary = ArpgBalance.data.get("rent", {})
	var rent: int = int(rent_cfg.get("daily", 0))
	var rent_paid := 0
	var overdue := 0
	if rent > 0:
		rpg.day += 1
		# 日常委托刷新：daily 任务在新的一天重置（done/claimed → active），支撑第 2 天起的稳定收入线
		for qid in rpg.quests:
			var qd: Dictionary = rpg.quests[qid]
			if bool(ArpgBalance.data.get("quests", {}).get(qid, {}).get("daily", false)) 					and str(qd.get("state", "")) in ["done", "claimed"]:
				qd["state"] = "active"
				qd["progress"] = 0
				qd.erase("notified")
		if rpg.gold >= rent:
			rpg.gold -= rent
			rpg.debt_paid += rent
			rpg.debt -= rent
			rent_paid = rent
			main.hud.log("第 %d 天：支付店租 %dG" % [rpg.day - 1, rent])
		else:
			var lack: int = rent - rpg.gold
			rpg.debt += lack
			rpg.gold = 0
			main.hud.log("第 %d 天：店租 %dG 付不起，欠款又多了 %dG……" % [rpg.day - 1, rent, lack])
		# 债主期限的叙事压力（不做硬失败，Demo 留悬念）
		var due: int = int(rent_cfg.get("ten_days", 10))
		if rpg.day > due and rpg.debt > 0:
			overdue = rpg.day - due
	return {"paid": paid, "overdue": overdue, "rent_paid": rent_paid}


## 还债/租金结算后的 flavor 叙事行（供结算屏拼接）
func flavor_after(r: Dictionary) -> String:
	var rpg = main.rpg
	var out := ""
	if int(r["overdue"]) > 0:
		out = "\n第 %d 天了……债主的耐心正在耗尽。" % rpg.day
	elif rpg.debt <= 0:
		out = "\n一千二百枚金币，一枚不少。债主的脸色从未这么好看过。"
	elif int(r["paid"]) > 0:
		out = "\n这一趟还了 %dG——离自由又近了一天。" % int(r["paid"])
	return out
