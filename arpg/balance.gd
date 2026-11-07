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
static var last_errors: Array = []
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


## 全场最大实体占几格（含 Boss）。生成器拿它当走廊宽度下限，
## 避免"生成了一个 Boss 挤不进去的走廊"这种只能靠玩家撞墙才发现的问题。
static func max_footprint() -> int:
	var m := 1
	for k in ENEMIES:
		if ENEMIES[k] is Dictionary:
			m = maxi(m, _footprint_of_scale(float(ENEMIES[k].get("scale", 1.0))))
	if BOSS is Dictionary and not BOSS.is_empty():
		m = maxi(m, _footprint_of_scale(float(BOSS.get("scale", 1.0))))
	return m


## 与 ArpgMobSystem 同一口径：基础半径 9 × scale，直径 / 网格 向上取整
static func _footprint_of_scale(scale: float) -> int:
	var d := 9.0 * maxf(scale, 0.1) * 2.0
	return maxi(1, int(ceil(d / float(ArpgData.GRID))))


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
		last_errors = []
		return false
	data = _deep_merge(defaults(), raw)
	_normalize()
	_apply()
	loaded_ok = true
	last_error = ""
	last_errors = validate()
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
	b["enrage_at"] = float(b.get("enrage_at", 0.4))
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


## 内容校验（需求 §6：调参错误当场暴露，禁止静默回退）：返回错误清单
static func validate() -> Array:
	var errs := []
	var chars: Dictionary = data.get("chars", {})
	if chars.is_empty():
		errs.append("chars 为空")
	for id in chars:
		for f in ["name", "sprite", "hp", "atk", "spd", "weapon"]:
			if not chars[id].has(f):
				errs.append("chars.%s 缺 %s" % [id, f])
	for id in data.get("enemies", {}):
		for f in ["name", "sprite", "hp", "atk", "spd", "xp", "behavior"]:
			if not data["enemies"][id].has(f):
				errs.append("enemies.%s 缺 %s" % [id, f])
	if not data.has("boss"):
		errs.append("boss 缺失")
	if data.get("items", {}).is_empty():
		errs.append("items 为空")
	if not data.has("skills"):
		errs.append("skills 缺失")
	if not data.has("quests"):
		errs.append("quests 缺失")
	if not data.has("party"):
		errs.append("party 配置缺失")
	for fl in data.get("floor_pools", {}):
		for e in data["floor_pools"][fl]:
			if not data.get("enemies", {}).has(e[0]):
				errs.append("floor_pools.%s 引用未知敌人 %s" % [fl, e[0]])
	for c in data.get("char_skills", {}):
		for sid in data["char_skills"][c]:
			if not data.get("skills", {}).has(sid):
				errs.append("char_skills.%s 引用未知技能 %s" % [c, sid])
	var slots: Array = data.get("equip_slots", [])
	for id in data.get("equipment", {}):
		if not slots.has(data["equipment"][id].get("slot", "")):
			errs.append("equipment.%s 槽位非法" % id)
	return errs


## 写回 balance.json（编辑器-系统数值页使用；保存即热重载）
static func save_to_file() -> bool:
	DirAccess.make_dir_recursive_absolute(PATH.get_base_dir())
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return true


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
		"max_floor": 5, "bag_cap": 20, "trap_chance": 0.45, "aggro_range": 185.0,
		"elite_chance": 0.12, "death_loss": 0.5,
		"elite_tint": [1.3, 1.15, 0.5],
		"debt": {"initial": 300},
		"combo": {"window": 3.0},
		"ai": {
			"flow_recalc_interval": 0.25,
			"separation": {"radius_pad": 10.0, "strength": 16.0, "max_neighbors": 6},
			"stuck": {"after": 0.45, "nudge_time": 0.5, "nudge_speed": 0.6},
			"arc_blend": 0.22,
			"strafe_ratio": 0.5
		},
		"dodge": {
			"cost": 25.0,
			"forward": {"speed": 720.0, "time": 0.16, "iframes": 0.10},
			"back": {"speed": 560.0, "time": 0.26, "iframes": 0.20},
			"side": {"speed": 640.0, "time": 0.20, "iframes": 0.15},
		},
		"stamina": {"max": 100.0, "regen": 20.0, "regen_delay": 0.6},
		"parry": {
			"window": 0.24, "perfect_frac": 0.45,
			"mash_window": 0.4, "mash_shrink": 0.6, "min_window": 0.04,
			"whiff_cd": 0.6, "parry_cd": 0.3,
			"stamina_cost": 12.0, "sp_refund": 8,
			"stagger_t": 0.9, "stagger_knock": 260.0,
			"parry_stagger_t": 0.3, "parry_stagger_knock": 120.0,
		},
		"heavy": {
			"charge_time": 0.45, "mult": 1.4,
			"emp_mult": 1.3, "weak_mult": 0.77,
			"emp_sp_ratio": 0.35, "sp_cost": 12, "cd_mult": 1.2,
		},
		"threat": {
			"enabled": true, "start": 25.0, "max": 100.0,
			"gain": {
				"low_hp_ratio": 0.3, "low_hp_per_s": 1.5,
				"potion": 8.0, "potion_mash_window": 1.5,
				"potion_mash_per_input": 2.0, "potion_mash_cap": 8.0,
				"mash_window": 1.0, "mash_threshold": 5, "mash": 5.0,
				"hurt": 4.0, "skill": 2.0, "skill_rich_ratio": 0.8, "skill_rich": 2.0,
				"point_blank_per_s": 1.2, "point_blank_dist": 95.0,
			},
			"relief": {
				"calm_decay": 1.5, "idle_after": 2.0, "idle_extra": 3.0,
				"dodge": 4.0, "parry": 2.0, "perfect_parry": 6.0,
			},
			"bands": {"calm": 30.0, "aggressive": 85.0},
			"tempo_aggressive": 0.85, "pool_interval": 2.2, "ult_cap": 2,
			"moves": {
				"charge": {"low": 5.0, "high": 20.0, "cd": 6.0, "speed": 620.0,
					"range_min": 110.0, "range_max": 340.0},
				"slam": {"low": 10.0, "high": 25.0, "cd": 7.5, "radius": 115.0, "dmg_mult": 1.4},
				"backstep": {"low": 25.0, "high": 5.0, "cd": 2.5, "speed": 560.0},
				"observe": {"low": 20.0, "high": 0.0, "dur": 1.1},
			},
		},
		"minimap": {
			"enabled": true, "width": 184.0, "height": 132.0,
			"reveal_radius": 7, "reveal_interval": 0.12,
		},
		"drops": {
			"enabled": true, "settle_mode": "arrive", "elite_mult": 2.0, "boss_mult": 6.0,
			"common": {
				"scatter_time": 0.45, "friction": 3.4, "bounce": 0.35,
				"scatter_speed_min": 70.0, "scatter_speed_max": 215.0,
				"attract_radius": 165.0, "attract_delay": 0.28,
				"attract_speed_start": 140.0, "attract_speed_end": 820.0,
				"attract_time": 0.42, "arrive_dist": 12.0,
				"lifetime": 14.0, "scale_start": 1.0, "scale_end": 0.35,
			},
			"gold": {"count_min": 5, "count_max": 9},
			"gem": {"chance": 0.18, "value": 8, "scatter_speed_max": 250.0},
		},
		"camera": {
			"base_zoom": 1.7, "min_zoom": 1.12, "pan_weight": 0.42, "safe_frac": 0.34,
			"fit_bias": 0.9, "track_ratio": 1.3, "track_release": 1.3, "margin": 30.0,
			"smooth_time": 0.16, "max_speed": 2400.0,
			"zoom_out_rate": 3.0, "zoom_in_rate": 1.5, "zoom_deadband": 0.06,
			"max_shot_time": 6.0, "focus_rate": 12.0, "look_ahead": 34.0
		},
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
			"potion": {"name": "回复药水", "kind": "use", "heal": 50, "value": 25, "windup": 0.35, "tint": [1.0, 0.42, 0.48]},
			"purge": {"name": "净化卷轴", "kind": "use", "purge": true, "value": 18, "tint": [0.5, 0.8, 1.0]},
		},
		"apc_units": {
			"mercenary": {"name": "佣兵·铁岩", "sprite": ["res://assets/chars/Actor1.png", 0, 0], "hp": 90, "sp": 40,
				"atk": 9, "spd": 145, "atk_range": 38.0, "weapon": "melee"},
		},
		"loot_base": [["herb", 5], ["ore", 4], ["gems", 2], ["potion", 3]],
		"loot_f2_add": [["gems", 2]], "loot_f3_add": [["orb", 1]],
		"drop_base": [["herb", 5], ["ore", 3], ["potion", 2], ["purge", 1]],
		"drop_f2_add": [["gems", 1]], "drop_f4_add": [["orb", 1]],
		"floor_pools": {
			"1": [["imp", 5], ["harpy", 3]],
			"2": [["imp", 3], ["harpy", 3], ["orc", 3], ["wolf", 2]],
			"3": [["orc", 4], ["wolf", 3], ["fox", 2], ["imp", 2]],
			"4": [["orc", 3], ["wolf", 3], ["fox", 3], ["knight", 2]],
			"5": [["knight", 3], ["fox", 3], ["orc", 2], ["wolf", 2]],
		},
		"strings": {
			"ui.title": "千亿魔女 · 地牢试炼",
			"ui.start_game": "选择出击",
			"ui.shop": "店铺（试营业）",
			"ui.resume": "继续探索",
			"ui.retreat": "撤退结算（带走全部战利品）",
			"ui.save": "保存",
			"ui.load": "读取",
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
			"ai": {
				"self_defense_radius": 150.0, "assist_radius": 300.0, "assist_idle_radius": 200.0,
				"los_penalty": 0.9, "stick_bonus": 0.6, "switch_margin": 1.25,
				"reach_timeout": 6.0, "blacklist_time": 5.0,
				"ranged_engage": 265.0, "ranged_keep_min": 125.0, "ranged_keep_max": 225.0,
				"arrive_radius": 28.0, "resume_radius": 48.0,
				"pickup_threat_radius": 220.0, "skill_min_enemies": 2, "aim_max_lead": 0.55,
				"stuck_repath": 0.3, "stuck_sidestep": 0.75, "stuck_regroup": 1.5,
				"stuck_teleport": 2.5, "hold_leash": 1.6,
			},
			"possession_cooldown": 1.5, "friend_potion_use": false, "friend_sp_regen": 3.0,
			"xp_share_ratio": 1.0, "revive_on_floor_change": true, "revive_ratio": 0.5,
			"low_hp_retreat_ratio": 0.25,
			"think_interval": 0.15, "nav_repath_interval": 0.8,
			"far_unit_distance": 1200.0, "far_think_multiplier": 3.0,
			"apc_tags": {"mercenary": {"can_command": true, "can_possess": false, "counts_to_cap": false, "temporary": true}},
		},
	}
