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
	var defs: Dictionary = ArpgBalance.data.get("quests", {})
	for qid in main.rpg.quests:
		var q: Dictionary = main.rpg.quests[qid]
		if q["state"] == "done" and not q.get("notified", false):
			q["notified"] = true   # 防重复弹：done 未领奖期间每次触发都会再扫到这里
			main.hud.log("任务完成：%s（在角色菜单领取奖励）" % defs.get(qid, {}).get("name", qid))
			main.hud.set_quest_toast(defs.get(qid, {}).get("name", qid))
			# 任务链：本任务完成 → 下游任务解锁提示
			for other_id in defs:
				if str(defs[other_id].get("requires", "")) == qid:
					main.hud.log("新任务解锁：%s" % defs[other_id].get("name", other_id))
					main.hud.set_quest_toast("新任务：" + str(defs[other_id].get("name", other_id)))


func claim(qid: String) -> String:
	var rw: Dictionary = ArpgBalance.data.get("quests", {}).get(qid, {}).get("rewards", {})
	var result: String = main.rpg.quest_claim(qid)
	if result != "":
		# xp 奖励真正入账（rpg_state.quest_claim 只拼文本；玩家个人经验，不走队伍分摊）
		if rw.has("xp") and main.player != null and is_instance_valid(main.player):
			main.player.gain_xp(int(rw["xp"]))
		main.hud.log("领取任务奖励：%s（%s）" % [
			ArpgBalance.data.get("quests", {}).get(qid, {}).get("name", qid), result])
		main.play_sfx("heal", -8.0)
	return result


## UI 用：任务行数据（未解锁的任务链下游不显示）
func rows() -> Array:
	var out := []
	for qid in main.rpg.quests:
		var q: Dictionary = main.rpg.quests[qid]
		var def: Dictionary = ArpgBalance.data.get("quests", {}).get(qid, {})
		if def.is_empty():
			continue
		if not main.rpg.quest_unlocked(qid):
			continue
		out.append({"id": qid, "name": def.get("name", qid), "desc": def.get("desc", ""),
			"progress": int(q["progress"]), "count": int(def.get("count", 1)),
			"state": str(q["state"]), "rewards": def.get("rewards", {})})
	return out
