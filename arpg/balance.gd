class_name ArpgBalance
extends RefCounted
## 热重载数据中枢：所有可调数值都在 data/balance.json。
## 改完保存 → 文件监视器自动重载（或 F2 手动）→ 新生成单位立即用新值，
## 存活敌人按血量比例换算（mob_system.apply_balance）。
## JSON 缺失/损坏时回退内置默认并告警，禁止无声失败。

const PATH := "res://data/balance.json"

static var data := {}
static var loaded_ok := false
static var last_error := ""
static var _mtime := 0

# —— 供全游戏读取的静态表（reload 时整体替换，调用点即取即用）——
static var CHARS := {}
static var ENEMIES := {}
static var BOSS := {}
static var ITEMS := {}
static var APC_UNITS := {}
static var ELITE_TINT := Color(1.3, 1.15, 0.5)
static var BAG_CAP := 20
static var MAX_FLOOR := 5
static var TRAP_CHANCE := 0.45
static var ELITE_CHANCE := 0.12
static var DEATH_LOSS := 0.5


static func _static_init() -> void:
	reload_data()


## 重载：返回是否成功读到文件（失败时回退默认）
static func reload_data() -> bool:
	var raw := _read_json(PATH)
	if raw.is_empty():
		if FileAccess.file_exists(PATH):
			last_error = "balance.json 解析失败，已回退内置默认"
			push_warning("[BALANCE] " + last_error)
		else:
			last_error = ""
		data = defaults()
		_apply()
		return false
	data = _deep_merge(defaults(), raw)
	_normalize()
	_apply()
	loaded_ok = true
	last_error = ""
	return true


static func _apply() -> void:
	CHARS = data.get("chars", {})
	ENEMIES = data.get("enemies", {})
	BOSS = data.get("boss", {})
	ITEMS = data.get("items", {})
	APC_UNITS = data.get("apc_units", {})
	BAG_CAP = int(data.get("bag_cap", 20))
	MAX_FLOOR = int(data.get("max_floor", 5))
	TRAP_CHANCE = float(data.get("trap_chance", 0.45))
	ELITE_CHANCE = float(data.get("elite_chance", 0.12))
	DEATH_LOSS = float(data.get("death_loss", 0.5))
	var et: Array = data.get("elite_tint", [1.3, 1.15, 0.5])
	ELITE_TINT = Color(et[0], et[1], et[2])


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


## 深合并：JSON 缺的键用内置默认补齐（支持只写想改的字段）
static func _deep_merge(base: Dictionary, over: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k in over:
		if out.has(k) and out[k] is Dictionary and over[k] is Dictionary:
			out[k] = _deep_merge(out[k], over[k])
		else:
			out[k] = over[k]
	return out


## JSON 数字全是 float：按表归一化整型字段 + 颜色数组转 Color
static func _normalize() -> void:
	var int3 := ["hp", "sp", "atk", "value", "heal", "xp"]
	for table_key in ["chars", "enemies", "items"]:
		var t: Dictionary = data.get(table_key, {})
		for id in t:
			for f in int3:
				if t[id].has(f):
					t[id][f] = int(t[id][f])
	var b: Dictionary = data.get("boss", {})
	b["hp"] = int(b.get("hp", 280))
	b["atk"] = int(b.get("atk", 15))
	b["xp"] = int(b.get("xp", 90))
	data["boss"] = b
	var it: Dictionary = data.get("items", {})
	for id in it:
		if it[id].has("tint") and it[id]["tint"] is Array:
			var c: Array = it[id]["tint"]
			it[id]["tint"] = Color(c[0], c[1], c[2])
	var eq: Dictionary = data.get("equipment", {})
	for id in eq:
		for f in ["atk", "def", "hp", "price", "tier", "sp"]:
			if eq[id].has(f):
				eq[id][f] = int(eq[id][f])
	var sk: Dictionary = data.get("skills", {})
	for id in sk:
		for f in ["sp", "cd", "unlock_level", "dmg_mult", "heal"]:
			if sk[id].has(f):
				sk[id][f] = sk[id][f]
		sk[id]["sp"] = int(sk[id].get("sp", 18))
		sk[id]["cd"] = float(sk[id].get("cd", 3.0))
		sk[id]["unlock_level"] = int(sk[id].get("unlock_level", 1))
	var q: Dictionary = data.get("quests", {})
	for id in q:
		q[id]["count"] = int(q[id].get("count", 1))
		var rw: Dictionary = q[id].get("rewards", {})
		if rw.has("gold"):
			rw["gold"] = int(rw["gold"])
		if rw.has("xp"):
			rw["xp"] = int(rw["xp"])
	var et: Array = data.get("elite_tint", [1.3, 1.15, 0.5])
	data["elite_tint"] = [et[0], et[1], et[2]]
	_apply()


# ———————— 派生查询（带默认兜底） ————————

static func xp_need(level: int) -> int:
	return int(data.get("xp_base", 18) + level * data.get("xp_per_level", 14))


static func floor_pool(floor: int) -> Array:
	var pools: Dictionary = data.get("floor_pools", {})
	var key := str(clampi(floor, 1, MAX_FLOOR))
	return pools.get(key, [["imp", 5]])


static func floor_enemy_count(floor: int) -> int:
	return int(data.get("floor_enemy_count_base", 5)) + floor * int(data.get("floor_enemy_count_per", 2))


static func loot_weight(floor: int) -> Array:
	var out: Array = data.get("loot_base", []).duplicate()
	if floor >= 2:
		out += data.get("loot_f2_add", [])
	if floor >= 3:
		out += data.get("loot_f3_add", [])
	return out


static func drop_weight(floor: int) -> Array:
	var out: Array = data.get("drop_base", []).duplicate()
	if floor >= 2:
		out += data.get("drop_f2_add", [])
	if floor >= 4:
		out += data.get("drop_f4_add", [])
	return out


## 按权重随机取一个 id
static func weighted_pick(table: Array, rng: RandomNumberGenerator) -> String:
	var total := 0
	for e in table:
		total += int(e[1])
	var roll := rng.randi_range(1, total)
	for e in table:
		roll -= int(e[1])
		if roll <= 0:
			return str(e[0])
	return str(table[0][0])


## 内置默认（= balance.json 的初始内容；JSON 缺失/坏键时兜底）
static func defaults() -> Dictionary:
	return {
		"max_floor": 5, "bag_cap": 20, "trap_chance": 0.45,
		"elite_chance": 0.12, "death_loss": 0.5,
		"elite_tint": [1.3, 1.15, 0.5],
		"xp_base": 18, "xp_per_level": 14,
		"floor_enemy_count_base": 5, "floor_enemy_count_per": 2,
		"chars": {
			"fencer": {"name": "剑士·凛", "title": "稳健型 · 近战连段", "sprite": ["res://assets/chars/Actor1.png", 288, 0],
				"hp": 120, "sp": 50, "atk": 12, "spd": 155, "atk_cd": 0.34, "atk_range": 38.0,
				"weapon": "melee",
				"skill": {"name": "冲斩", "sp": 18, "cd": 2.2, "desc": "向前突进，斩击路径上的敌人"},
				"growth": {"hp": 14, "atk": 2}},
			"archer": {"name": "弓手·凯", "title": "操作型 · 远程风筝", "sprite": ["res://assets/chars/Actor1.png", 432, 0],
				"hp": 92, "sp": 60, "atk": 10, "spd": 178, "atk_cd": 0.40, "atk_range": 0.0,
				"weapon": "ranged", "proj_spd": 430.0,
				"skill": {"name": "迅捷连射", "sp": 20, "cd": 2.8, "desc": "向前方扇形射出 5 支箭"},
				"growth": {"hp": 10, "atk": 2}},
			"witch": {"name": "魔女·伊伊", "title": "爆发型 · 范围法术", "sprite": ["res://assets/chars/Actor1.png", 144, 192],
				"hp": 80, "sp": 95, "atk": 14, "spd": 142, "atk_cd": 0.5, "atk_range": 0.0,
				"weapon": "magic", "proj_spd": 300.0,
				"skill": {"name": "烈焰环", "sp": 26, "cd": 3.5, "desc": "爆发火焰环，环射 12 枚火球并震退近身敌人"},
				"growth": {"hp": 8, "atk": 2}},
		},
		"enemies": {
			"imp": {"name": "魔物幼体", "sprite": ["res://assets/chars/Monster.png", 144, 192], "hp": 22, "atk": 6, "spd": 95,
				"xp": 4, "behavior": "melee", "scale": 0.9, "atk_range": 26.0, "windup": 0.35, "cool": 0.9},
			"harpy": {"name": "鹰身女妖", "sprite": ["res://assets/chars/Monster.png", 0, 0], "hp": 26, "atk": 8, "spd": 115,
				"xp": 6, "behavior": "melee", "scale": 1.0, "atk_range": 28.0, "windup": 0.4, "cool": 1.0},
			"orc": {"name": "兽人", "sprite": ["res://assets/chars/Monster.png", 144, 0], "hp": 44, "atk": 11, "spd": 72,
				"xp": 9, "behavior": "melee", "scale": 1.05, "atk_range": 30.0, "windup": 0.5, "cool": 1.2},
			"wolf": {"name": "座狼", "sprite": ["res://assets/chars/Monster.png", 288, 0], "hp": 30, "atk": 9, "spd": 140,
				"xp": 8, "behavior": "melee", "scale": 1.0, "atk_range": 28.0, "windup": 0.3, "cool": 0.8},
			"fox": {"name": "妖狐法师", "sprite": ["res://assets/chars/Monster.png", 0, 192], "hp": 26, "atk": 9, "spd": 68,
				"xp": 10, "behavior": "ranged", "scale": 1.0, "atk_range": 230.0, "keep": 150.0,
				"windup": 0.6, "cool": 1.8, "proj_spd": 260.0},
			"knight": {"name": "黑铁骑士", "sprite": ["res://assets/chars/Monster.png", 432, 0], "hp": 70, "atk": 13, "spd": 62,
				"xp": 14, "behavior": "melee", "scale": 1.1, "atk_range": 32.0, "windup": 0.55, "cool": 1.4},
		},
		"boss": {"name": "魔王·巴洛尔", "sprite": ["res://assets/chars/Monster.png", 288, 192], "hp": 280, "atk": 15,
			"spd": 70, "xp": 90, "behavior": "boss", "scale": 1.5, "atk_range": 42.0, "windup": 0.5, "cool": 1.1},
		"items": {
			"herb": {"name": "药草", "kind": "goods", "value": 8, "tint": [0.45, 0.9, 0.55]},
			"ore": {"name": "铁矿", "kind": "goods", "value": 22, "tint": [0.68, 0.72, 0.82]},
			"gems": {"name": "魔石", "kind": "goods", "value": 60, "tint": [0.45, 0.6, 1.0]},
			"orb": {"name": "宝玉", "kind": "goods", "value": 120, "tint": [1.0, 0.75, 0.3]},
			"potion": {"name": "回复药水", "kind": "use", "heal": 50, "value": 25, "tint": [1.0, 0.42, 0.48]},
		},
		"apc_units": {
			"mercenary": {"name": "佣兵·铁岩", "sprite": ["res://assets/chars/Actor1.png", 0, 0], "hp": 90, "sp": 40,
				"atk": 9, "spd": 145, "atk_range": 38.0, "weapon": "melee"},
		},
		"loot_base": [["herb", 5], ["ore", 4], ["gems", 2], ["potion", 3]],
		"loot_f2_add": [["gems", 2]], "loot_f3_add": [["orb", 1]],
		"drop_base": [["herb", 5], ["ore", 3], ["potion", 2]],
		"drop_f2_add": [["gems", 1]], "drop_f4_add": [["orb", 1]],
		"floor_pools": {
			"1": [["imp", 5], ["harpy", 3]],
			"2": [["imp", 3], ["harpy", 3], ["orc", 3], ["wolf", 2]],
			"3": [["orc", 4], ["wolf", 3], ["fox", 2], ["imp", 2]],
			"4": [["orc", 3], ["wolf", 3], ["fox", 3], ["knight", 2]],
			"5": [["knight", 3], ["fox", 3], ["orc", 2], ["wolf", 2]],
		},
		"sell_ratio": 0.6,
		"gold_drop_min": 2, "gold_drop_max": 6,
		"equip_slots": ["weapon", "armor", "trinket"],
		"skills": {
			"slash_dash": {"name": "冲斩", "kind": "dash", "unlock_level": 1, "sp": 18, "cd": 2.2, "dmg_mult": 1.7, "desc": "向前突进，斩击路径上的敌人"},
			"arrow_volley": {"name": "迅捷连射", "kind": "volley", "unlock_level": 1, "sp": 20, "cd": 2.8, "dmg_mult": 1.0, "desc": "向前方扇形射出 5 支箭"},
			"flame_nova": {"name": "烈焰环", "kind": "nova", "unlock_level": 1, "sp": 26, "cd": 3.5, "dmg_mult": 1.4, "desc": "爆发火焰环，环射 12 枚火球"},
			"holy_light": {"name": "圣光术", "kind": "heal", "unlock_level": 3, "sp": 20, "cd": 5.0, "heal": 0.35, "desc": "回复 35% 最大生命"},
			"piercing_shot": {"name": "穿透箭", "kind": "volley", "unlock_level": 5, "sp": 24, "cd": 3.0, "dmg_mult": 1.5, "desc": "五连矢，更快更痛"},
			"meteor": {"name": "陨星术", "kind": "nova", "unlock_level": 6, "sp": 32, "cd": 4.5, "dmg_mult": 1.8, "desc": "更强的爆炎与冲击"},
		},
		"char_skills": {"fencer": ["slash_dash", "piercing_shot"], "archer": ["arrow_volley", "holy_light"], "witch": ["flame_nova", "meteor"]},
		"equipment": {
			"sword_iron": {"name": "铁剑", "slot": "weapon", "atk": 3, "price": 60, "tier": 1},
			"sword_flame": {"name": "焰纹剑", "slot": "weapon", "atk": 7, "price": 220, "tier": 2},
			"armor_leather": {"name": "皮甲", "slot": "armor", "def": 2, "hp": 10, "price": 50, "tier": 1},
			"armor_plate": {"name": "板甲", "slot": "armor", "def": 5, "hp": 25, "price": 200, "tier": 2},
			"trinket_ring": {"name": "回响指环", "slot": "trinket", "sp": 20, "price": 120, "tier": 1},
		},
		"shop_stock": {"always": ["potion", "herb"], "tier2": ["sword_iron", "armor_leather", "trinket_ring"], "tier3": ["sword_flame", "armor_plate"]},
		"quests": {
			"q_hunt": {"name": "讨伐魔物", "desc": "击败 8 只任意魔物", "type": "kill", "target": "any", "count": 8, "rewards": {"gold": 40, "xp": 20}},
			"q_boss": {"name": "魔王讨伐", "desc": "击败魔王巴洛尔", "type": "kill", "target": "boss", "count": 1, "rewards": {"gold": 200}},
			"q_ore": {"name": "铁矿收集", "desc": "拾取 5 个铁矿", "type": "collect", "target": "ore", "count": 5, "rewards": {"gold": 30, "item": {"potion": 2}}},
			"q_depth": {"name": "深入地牢", "desc": "到达地下 3 层", "type": "reach_floor", "count": 3, "rewards": {"gold": 60}},
		},
		"party": {
			"max_party_size": 8, "start_friends": 2,
			"command": {
				"active": {"search_radius": 340.0, "leash_radius": 320.0, "pickup": true,
					"protect_player": true, "low_hp_retreat": 0.25, "no_enemy": "follow"},
				"follow": {"follow_distance": 110.0, "spread": 52.0, "pickup": true,
					"engage_with_player": true, "engage_radius": 300.0},
				"hold": {"self_defense": true, "defense_radius": 70.0, "pickup": false},
			},
			"possession_cooldown": 1.5, "friend_potion_use": false, "friend_sp_regen": 3.0,
			"xp_share_ratio": 1.0, "revive_on_floor_change": true, "revive_ratio": 0.5,
			"low_hp_retreat_ratio": 0.25, "stuck_teleport_after": 6.0,
			"think_interval": 0.15, "nav_repath_interval": 0.8,
			"far_unit_distance": 1200.0, "far_think_multiplier": 3.0,
			"apc_tags": {"mercenary": {"can_command": true, "can_possess": false, "counts_to_cap": false, "temporary": true}},
		},
	}
