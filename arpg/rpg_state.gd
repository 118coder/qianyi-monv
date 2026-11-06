class_name ArpgRpgState
extends RefCounted
## RPG 元状态层（跨楼层持久，存档 v2 的核心）：
## · 金币 / 背包（ArpgInventory）/ 已穿装备 / 任务进度
## · 装备加成计算（攻/防/血/SP 上限），供 player/friends 派生属性
## · 与技能表（char_skills + 等级解锁）、商店、任务、存档系统互通

var gold := 0
var debt := 300                # 露塞提娅核心循环：开局欠款（三百枚金币）
var debt_paid := 0             # 累计已还债务
var inventory := ArpgInventory.new()
var equipped := {"weapon": "", "armor": "", "trinket": ""}
var quests := {}               # qid -> {"state": "active/done/claimed", "progress": int}
# 跨局成就统计（露塞提娅式经营积累感；结算时更新，随存档走）
var lifetime_kills := 0        # 历史累计击杀
var best_floor := 0            # 历史最深楼层
var best_combo := 0            # 历史最高连杀


func setup() -> void:
	inventory.setup(int(ArpgBalance.BAG_CAP))
	# 初始债务读配置；已开始还债（debt_paid > 0）时保留进度，避免每局重置
	var debt_cfg: Dictionary = ArpgBalance.data.get("debt", {})
	if debt_paid <= 0:
		debt = int(debt_cfg.get("initial", 300))
	for qid in ArpgBalance.data.get("quests", {}):
		if not quests.has(qid):
			quests[qid] = {"state": "active", "progress": 0}


# ———————— 装备 ————————

func equip_bonus(key: String) -> int:
	var total := 0
	var eq_table: Dictionary = ArpgBalance.data.get("equipment", {})
	for slot in equipped:
		var iid: String = equipped[slot]
		if iid == "" or not eq_table.has(iid):
			continue
		total += int(eq_table[iid].get(key, 0))
	return total


## 穿装备（物品须在背包且是装备类）；同槽旧装备退回背包
func equip(item_id: String) -> bool:
	var eq: Dictionary = ArpgBalance.data.get("equipment", {}).get(item_id, {})
	if eq.is_empty() or not inventory.has(item_id):
		return false
	var slot: String = eq["slot"]
	if not ArpgBalance.data.get("equip_slots", ["weapon", "armor", "trinket"]).has(slot):
		return false
	if not inventory.remove(item_id, 1):
		return false
	if equipped[slot] != "":
		inventory.add(equipped[slot])   # 旧装备回包（容量满则放弃换装，原子性）
		if not inventory.has(equipped[slot]) and equipped[slot] != item_id:
			inventory.add(item_id)      # 回滚
			return false
	equipped[slot] = item_id
	return true


func unequip(slot: String) -> bool:
	var iid: String = equipped.get(slot, "")
	if iid == "" or not inventory.add(iid):
		return false
	equipped[slot] = ""
	return true


# ———————— 任务 ————————

## 任务链：前置任务（requires）完成（done/claimed）才解锁；无前置恒解锁
func quest_unlocked(qid: String) -> bool:
	var req: String = str(ArpgBalance.data.get("quests", {}).get(qid, {}).get("requires", ""))
	if req == "":
		return true
	var rq: Dictionary = quests.get(req, {})
	return rq.get("state", "") in ["done", "claimed"]


## 事件推进：etype = kill/collect/reach_floor，target = 模板id/物品id/"any"/"boss"
func quest_progress(etype: String, target: String, amount: int = 1) -> void:
	for qid in quests:
		var q: Dictionary = quests[qid]
		if q["state"] != "active":
			continue
		if not quest_unlocked(qid):
			continue
		var def: Dictionary = ArpgBalance.data.get("quests", {}).get(qid, {})
		if def.get("type", "") != etype:
			continue
		var t: String = str(def.get("target", "any"))
		if t != "any" and t != target:
			continue
		q["progress"] = int(q["progress"]) + amount
		if int(q["progress"]) >= int(def.get("count", 1)):
			q["state"] = "done"


## 领取已完成任务的奖励（返回描述文本，供 UI/日志）
func quest_claim(qid: String) -> String:
	var q: Dictionary = quests.get(qid, {})
	var def: Dictionary = ArpgBalance.data.get("quests", {}).get(qid, {})
	if q.get("state", "") != "done" or def.is_empty():
		return ""
	q["state"] = "claimed"
	var rw: Dictionary = def.get("rewards", {})
	var parts := []
	if rw.has("gold"):
		gold += int(rw["gold"])
		parts.append("%dG" % int(rw["gold"]))
	if rw.has("xp"):
		parts.append("%d 经验" % int(rw["xp"]))
	if rw.has("item"):
		for iid in rw["item"]:
			if inventory.add(str(iid), int(rw["item"][iid])):
				parts.append("%s×%d" % [ArpgBalance.ITEMS.get(iid, {}).get("name", iid), int(rw["item"][iid])])
	return "；".join(parts)


# ———————— 序列化（存档 v2） ————————

func to_dict() -> Dictionary:
	return {"gold": gold, "debt": debt, "debt_paid": debt_paid, "inventory": inventory.to_dict(),
		"equipped": equipped.duplicate(), "quests": quests.duplicate(true),
		"lifetime_kills": lifetime_kills, "best_floor": best_floor, "best_combo": best_combo}


func from_dict(d: Dictionary) -> void:
	gold = int(d.get("gold", 0))
	debt = int(d.get("debt", 300))          # 旧档没有债务字段：按开局债务补齐
	debt_paid = int(d.get("debt_paid", 0))
	lifetime_kills = int(d.get("lifetime_kills", 0))
	best_floor = int(d.get("best_floor", 0))
	best_combo = int(d.get("best_combo", 0))
	inventory.from_dict(d.get("inventory", {}))
	var eq: Dictionary = d.get("equipped", {})
	for slot in equipped:
		equipped[slot] = str(eq.get(slot, ""))
	quests = d.get("quests", {}).duplicate(true)
	# 新增任务（版本更迭/热更后补齐）
	for qid in ArpgBalance.data.get("quests", {}):
		if not quests.has(qid):
			quests[qid] = {"state": "active", "progress": 0}
