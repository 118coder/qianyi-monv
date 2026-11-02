class_name ArpgData
## ARPG 数值表（对应策划案 §10 可调参数表）：
## 角色 / 敌人 / 物品 / 地牢结构 / 宝箱陷阱 / 成长曲线，全部集中在这一个文件里调平衡。

const TILE := 32
const ACTOR1 := "res://assets/chars/Actor1.png"
const MONSTER := "res://assets/chars/Monster.png"

const TEX_FLOOR := "res://assets/tiles/Dungeon_Cave_TileA2.png"
const TEX_WALL := "res://assets/tiles/Dungeon_TileA4.png"
const SRC_FLOOR := Rect2(32, 32, 32, 32)    # 洞穴泥地内部块
const SRC_WALL := Rect2(480, 32, 32, 32)    # 洞穴岩壁内部块

# ———— 地牢 / 风险 ————
const MAX_FLOOR := 5            # 每 5 层一个 Boss 阶段（MVP）
const BAG_CAP := 20             # 背包容量（携带+拾取共享）
const TRAP_CHANCE := 0.45       # 宝箱陷阱概率（策划案 40%~50%）
const ELITE_CHANCE := 0.12      # 精英怪概率
const DEATH_LOSS := 0.5         # 死亡时商品折损比例

## 冒险者（weapon: melee 近战弧 / ranged 射箭 / magic 法弹）
## skill: 专属技能；growth: 每级成长
const CHARS := {
	"fencer": {
		"name": "剑士·凛", "title": "稳健型 · 近战连段", "sprite": [ACTOR1, 288, 0],
		"hp": 120, "sp": 50, "atk": 12, "spd": 155, "atk_cd": 0.34, "atk_range": 38.0,
		"weapon": "melee",
		"skill": {"name": "冲斩", "sp": 18, "cd": 2.2, "desc": "向前突进，斩击路径上的敌人"},
		"growth": {"hp": 14, "atk": 2},
	},
	"archer": {
		"name": "弓手·凯", "title": "操作型 · 远程风筝", "sprite": [ACTOR1, 432, 0],
		"hp": 92, "sp": 60, "atk": 10, "spd": 178, "atk_cd": 0.40, "atk_range": 0.0,
		"weapon": "ranged", "proj_spd": 430.0,
		"skill": {"name": "迅捷连射", "sp": 20, "cd": 2.8, "desc": "向前方扇形射出 5 支箭"},
		"growth": {"hp": 10, "atk": 2},
	},
	"witch": {
		"name": "魔女·伊伊", "title": "爆发型 · 范围法术", "sprite": [ACTOR1, 144, 192],
		"hp": 80, "sp": 95, "atk": 14, "spd": 142, "atk_cd": 0.5, "atk_range": 0.0,
		"weapon": "magic", "proj_spd": 300.0,
		"skill": {"name": "烈焰环", "sp": 26, "cd": 3.5, "desc": "爆发火焰环，环射 12 枚火球并震退近身敌人"},
		"growth": {"hp": 8, "atk": 2},
	},
}

## 敌人（behavior: melee 追击近咬 / ranged 保持距离射击）
const ENEMIES := {
	"imp": {"name": "魔物幼体", "sprite": [MONSTER, 144, 192], "hp": 22, "atk": 6, "spd": 95,
		"xp": 4, "behavior": "melee", "scale": 0.9, "atk_range": 26.0, "windup": 0.35, "cool": 0.9},
	"harpy": {"name": "鹰身女妖", "sprite": [MONSTER, 0, 0], "hp": 26, "atk": 8, "spd": 115,
		"xp": 6, "behavior": "melee", "scale": 1.0, "atk_range": 28.0, "windup": 0.4, "cool": 1.0},
	"orc": {"name": "兽人", "sprite": [MONSTER, 144, 0], "hp": 44, "atk": 11, "spd": 72,
		"xp": 9, "behavior": "melee", "scale": 1.05, "atk_range": 30.0, "windup": 0.5, "cool": 1.2},
	"wolf": {"name": "座狼", "sprite": [MONSTER, 288, 0], "hp": 30, "atk": 9, "spd": 140,
		"xp": 8, "behavior": "melee", "scale": 1.0, "atk_range": 28.0, "windup": 0.3, "cool": 0.8},
	"fox": {"name": "妖狐法师", "sprite": [MONSTER, 0, 192], "hp": 26, "atk": 9, "spd": 68,
		"xp": 10, "behavior": "ranged", "scale": 1.0, "atk_range": 230.0, "keep": 150.0,
		"windup": 0.6, "cool": 1.8, "proj_spd": 260.0},
	"knight": {"name": "黑铁骑士", "sprite": [MONSTER, 432, 0], "hp": 70, "atk": 13, "spd": 62,
		"xp": 14, "behavior": "melee", "scale": 1.1, "atk_range": 32.0, "windup": 0.55, "cool": 1.4},
}

const ELITE_TINT := Color(1.3, 1.15, 0.5)

const BOSS := {"name": "魔王·巴洛尔", "sprite": [MONSTER, 288, 192], "hp": 280, "atk": 15,
	"spd": 70, "xp": 90, "behavior": "boss", "scale": 1.5, "atk_range": 42.0,
	"windup": 0.5, "cool": 1.1}

## 楼层敌人权重：层数越深怪越强
static func floor_pool(floor: int) -> Array:
	if floor <= 1:
		return [["imp", 5], ["harpy", 3]]
	if floor == 2:
		return [["imp", 3], ["harpy", 3], ["orc", 3], ["wolf", 2]]
	if floor == 3:
		return [["orc", 4], ["wolf", 3], ["fox", 2], ["imp", 2]]
	if floor == 4:
		return [["orc", 3], ["wolf", 3], ["fox", 3], ["knight", 2]]
	return [["knight", 3], ["fox", 3], ["orc", 2], ["wolf", 2]]


static func floor_enemy_count(floor: int) -> int:
	return 5 + floor * 2


## 物品：goods 商品（带回售卖）/ use 消耗品
const ITEMS := {
	"herb": {"name": "药草", "kind": "goods", "value": 8, "tint": Color(0.45, 0.9, 0.55)},
	"ore": {"name": "铁矿", "kind": "goods", "value": 22, "tint": Color(0.68, 0.72, 0.82)},
	"gems": {"name": "魔石", "kind": "goods", "value": 60, "tint": Color(0.45, 0.6, 1.0)},
	"orb": {"name": "宝玉", "kind": "goods", "value": 120, "tint": Color(1.0, 0.75, 0.3)},
	"potion": {"name": "回复药水", "kind": "use", "heal": 50, "tint": Color(1.0, 0.42, 0.48)},
}

## APC 友方单位模板（需求书 §5.6）：能力标签见 ArpgPartyConfig.CONFIG["apc_tags"]
const APC_UNITS := {
	"mercenary": {"name": "佣兵·铁岩", "sprite": [ACTOR1, 0, 0], "hp": 90, "sp": 40,
		"atk": 9, "spd": 145, "atk_range": 38.0, "weapon": "melee"},
}

## 开箱掉落权重（随层数加入高价值品）
static func loot_weight(floor: int) -> Array:
	var base := [["herb", 5], ["ore", 4], ["gems", 2], ["potion", 3]]
	if floor >= 2:
		base.append(["gems", 2])
	if floor >= 3:
		base.append(["orb", 1])
	return base


## 击败敌人掉落权重
static func drop_weight(floor: int) -> Array:
	var base := [["herb", 5], ["ore", 3], ["potion", 2]]
	if floor >= 2:
		base.append(["gems", 1])
	if floor >= 4:
		base.append(["orb", 1])
	return base


static func xp_need(level: int) -> int:
	return 18 + level * 14


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
