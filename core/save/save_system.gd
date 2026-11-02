class_name ArpgSaveSystem
extends RefCounted
## 存档 v2（需求：RPG 全量状态 + 队伍 + 楼层 + 主控 + 运行统计）：
## · user://save.json，version 字段向前兼容
## · 内容：RPG 状态（金币/背包/装备/任务）+ 玩家等级属性 + 队友（稳定 uid）+ 楼层/击杀/背包
## · F9 保存 / F10 读取；读档后队伍数量、指令、APC、任务进度一致（需求 §9）

const VERSION := 2
const MAX_SLOTS := 3


func _path(slot: int) -> String:
	return "user://save_%d.json" % clampi(slot, 1, MAX_SLOTS)

var main: Node


func setup(m: Node) -> void:
	main = m


func save_game(slot: int = 1) -> bool:
	var path := _path(slot)
	var d := {
		"version": VERSION,
		"char_id": main.char_id,
		"floor": main.floor_no,
		"kills": main.kills,
		"rpg": main.rpg.to_dict(),
		"player": {"hp": main.player.hp, "sp": main.player.sp,
			"level": main.player.level, "xp": main.player.xp,
			"command": main.player.command},
		"party": main.party.to_dict(),
		"possessed_uid": main.possession.current_unit.uid if main.possession.current_unit != null else "player",
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		main.hud.log("存档失败（无法写入）")
		return false
	f.store_string(JSON.stringify(d, "  "))
	f.close()
	main.hud.log("已存档到槽位 %d（F10 读取）" % slot)
	print("[SAVE] saved slot=", slot, " floor=", main.floor_no)
	return true


## 读档：返回错误文案（空串 = 成功）
func load_game(slot: int = 1) -> String:
	if not FileAccess.file_exists(_path(slot)):
		return "槽位 %d 没有存档（F9 保存）" % slot
	var f := FileAccess.open(_path(slot), FileAccess.READ)
	if f == null:
		return "存档无法读取"
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed == null or not (parsed is Dictionary):
		return "存档损坏"
	var d: Dictionary = parsed
	if int(d.get("version", 0)) > VERSION:
		return "存档版本过新"
	# 楼层与运行数据
	main.floor_no = int(d.get("floor", 1))
	main.kills = int(d.get("kills", 0))
	main.char_id = str(d.get("char_id", main.char_id))
	# 重建楼层（世界/导航），再灌入 RPG 状态与队伍
	main.build_floor()
	main.rpg.from_dict(d.get("rpg", {}))
	# 玩家属性
	var pd: Dictionary = d.get("player", {})
	main.player.level = int(pd.get("level", 1))
	main.player.xp = int(pd.get("xp", 0))
	main.player.hp = int(pd.get("hp", main.player.max_hp))
	main.player.sp = int(pd.get("sp", main.player.sp))
	main.player.command = str(pd.get("command", "follow"))
	main.player.hp_bar.update_values(float(main.player.hp) / main.player.max_hp, float(main.player.sp) / main.player.max_sp)
	# 队伍（稳定 uid 恢复）
	main.party.from_dict(d.get("party", {}))
	# 主控
	var puid := str(d.get("possessed_uid", "player"))
	if puid != "player":
		var fu = main.party.by_uid(puid)
		if fu != null and not fu.dead:
			main.possession.switch_to(fu, true)
	main.state = main.State.PLAY
	main.hud.update_turn(main.floor_no, "探索中")
	main.hud.log("读档完成（槽位 %d）—— 地下 %d 层" % [slot, main.floor_no])
	print("[SAVE] loaded slot=", slot, " floor=", main.floor_no)
	return ""


## 槽位元信息（UI 列表用）
func slot_meta(slot: int) -> Dictionary:
	var path := _path(slot)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed == null or not (parsed is Dictionary):
		return {}
	var rpg: Dictionary = parsed.get("rpg", {})
	var player: Dictionary = parsed.get("player", {})
	return {
		"slot": slot,
		"floor": int(parsed.get("floor", 1)),
		"gold": int(rpg.get("gold", 0)),
		"level": int(player.get("level", 1)),
		"time": FileAccess.get_modified_time(path),
	}
