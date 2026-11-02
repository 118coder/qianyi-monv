class_name ArpgQuestManager
extends RefCounted
## 任务系统：目标类型 kill / collect / reach_floor；全部数据来自 balance.json 的 quests 段。
## 状态机：active → done（进度满）→ claimed（领奖）。完成与领奖都有 UI 反馈，禁止无声失败。

var main: Node


func setup(m: Node) -> void:
	main = m


func on_kill(tpl_id: String, is_boss: bool) -> void:
	main.rpg.quest_progress("kill", "boss" if is_boss else tpl_id, 1)
	_check_done()


func on_pickup(item_id: String) -> void:
	main.rpg.quest_progress("collect", item_id, 1)
	_check_done()


func on_reach_floor(floor_no: int) -> void:
	main.rpg.quest_progress("reach_floor", "floor", floor_no)
	_check_done()


func _check_done() -> void:
	for qid in main.rpg.quests:
		if main.rpg.quests[qid]["state"] == "done":
			var name: String = ArpgBalance.data.get("quests", {}).get(qid, {}).get("name", qid)
			main.hud.log("任务完成：%s（在角色菜单领取奖励）" % name)
			main.hud.set_quest_toast(ArpgBalance.data.get("quests", {}).get(qid, {}).get("name", qid))


func claim(qid: String) -> String:
	var result: String = main.rpg.quest_claim(qid)
	if result != "":
		main.hud.log("领取任务奖励：%s（%s）" % [
			ArpgBalance.data.get("quests", {}).get(qid, {}).get("name", qid), result])
		main.play_sfx("heal", -8.0)
	return result


## UI 用：任务行数据
func rows() -> Array:
	var out := []
	for qid in main.rpg.quests:
		var q: Dictionary = main.rpg.quests[qid]
		var def: Dictionary = ArpgBalance.data.get("quests", {}).get(qid, {})
		if def.is_empty():
			continue
		out.append({"id": qid, "name": def.get("name", qid), "desc": def.get("desc", ""),
			"progress": int(q["progress"]), "count": int(def.get("count", 1)),
			"state": str(q["state"]), "rewards": def.get("rewards", {})})
	return out
