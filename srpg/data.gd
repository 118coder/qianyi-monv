class_name SrpgData
## 静态数据：地形、单位模板、关卡布置。
## 想调平衡 / 加单位 / 改地图，只需要改这个文件。

const TILE := 32

enum Terrain { GRASS, DIRT, FOREST, MOUNTAIN, WATER }

## cost: 移动消耗（≥90 视为不可通行）   def: 站在上面获得的防御加成
const TERRAIN := {
	Terrain.GRASS: {"cost": 1, "def": 0, "name": "草原"},
	Terrain.DIRT: {"cost": 1, "def": 0, "name": "荒地"},
	Terrain.FOREST: {"cost": 2, "def": 1, "name": "森林"},
	Terrain.MOUNTAIN: {"cost": 99, "def": 0, "name": "山地"},
	Terrain.WATER: {"cost": 99, "def": 0, "name": "深水"},
}

const ACTOR1 := "res://assets/chars/Actor1.png"
const MONSTER := "res://assets/chars/Monster.png"

## 单位模板。sprite: [贴图路径, 角色块左上角x, y]（MZ 规格：每块 144x192，单帧 48x48）
## magic: 法术攻击，无视地形防御    heal: 可治疗射程内队友，数值为治疗量
## boss: 守望型 AI，玩家不靠近就不主动
const UNITS := {
	"sword": {"name": "剑士·凛", "faction": "player", "hp": 26, "atk": 8, "def": 5,
		"mov": 5, "rmin": 1, "rmax": 1, "sprite": [ACTOR1, 288, 0]},
	"witch": {"name": "魔女·伊伊", "faction": "player", "hp": 18, "atk": 10, "def": 2,
		"mov": 4, "rmin": 1, "rmax": 2, "magic": true, "sprite": [ACTOR1, 144, 192]},
	"sister": {"name": "修女·哈娜", "faction": "player", "hp": 16, "atk": 4, "def": 3,
		"mov": 4, "rmin": 1, "rmax": 1, "heal": 9, "sprite": [ACTOR1, 432, 192]},
	"orc": {"name": "兽人兵", "faction": "enemy", "hp": 22, "atk": 7, "def": 4,
		"mov": 4, "rmin": 1, "rmax": 1, "sprite": [MONSTER, 144, 0]},
	"wolf": {"name": "狼人刺客", "faction": "enemy", "hp": 18, "atk": 9, "def": 2,
		"mov": 6, "rmin": 1, "rmax": 1, "sprite": [MONSTER, 288, 0]},
	"boss": {"name": "魔王·巴洛尔", "faction": "enemy", "hp": 32, "atk": 11, "def": 6,
		"mov": 3, "rmin": 1, "rmax": 2, "magic": true, "boss": true, "sprite": [MONSTER, 288, 192]},
}

const MAP_W := 20
const MAP_H := 14

## 山块：以左上角为基准，每个占 2x2 格
const MOUNTAINS := [
	Vector2i(0, 0), Vector2i(16, 0), Vector2i(0, 12), Vector2i(18, 11), Vector2i(12, 2),
]

const WATERS := [
	Vector2i(15, 9), Vector2i(16, 9), Vector2i(17, 9),
	Vector2i(14, 10), Vector2i(15, 10), Vector2i(16, 10), Vector2i(17, 10),
	Vector2i(15, 11), Vector2i(16, 11), Vector2i(17, 11),
]

const FORESTS := [
	Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2), Vector2i(2, 3), Vector2i(3, 3),
	Vector2i(11, 5), Vector2i(12, 5), Vector2i(13, 5), Vector2i(12, 6), Vector2i(13, 6),
	Vector2i(4, 9), Vector2i(5, 9), Vector2i(6, 10), Vector2i(4, 10), Vector2i(5, 10),
	Vector2i(15, 3), Vector2i(16, 3), Vector2i(17, 3), Vector2i(16, 4),
	Vector2i(7, 11), Vector2i(8, 11), Vector2i(8, 12),
	Vector2i(1, 5), Vector2i(1, 6),
	Vector2i(6, 4), Vector2i(10, 4), Vector2i(13, 9), Vector2i(19, 7),
]

## 出场单位：id 对应 UNITS 的键，可重复使用
const PLACEMENTS := [
	{"id": "sword", "cell": Vector2i(2, 7)},
	{"id": "witch", "cell": Vector2i(2, 8)},
	{"id": "sister", "cell": Vector2i(1, 8)},
	{"id": "orc", "cell": Vector2i(13, 6)},
	{"id": "wolf", "cell": Vector2i(15, 5)},
	{"id": "orc", "cell": Vector2i(14, 9)},
	{"id": "boss", "cell": Vector2i(17, 7)},
]
