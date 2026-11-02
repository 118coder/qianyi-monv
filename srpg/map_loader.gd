class_name SrpgMapLoader
extends RefCounted
## 地图 JSON 的编码 / 解码。地图文件：res://data/maps/map001.json
## rows 每行一个字符串，单字符表示地形：G草原 D荒地 F森林 M山 W深水
## placements: [{uid, tpl, cell:[x,y]}]   events: 触发器+命令列表（见 SrpgEventSystem）

const CHARS := {
	"G": SrpgData.Terrain.GRASS,
	"D": SrpgData.Terrain.DIRT,
	"F": SrpgData.Terrain.FOREST,
	"M": SrpgData.Terrain.MOUNTAIN,
	"W": SrpgData.Terrain.WATER,
}
const PATH := "res://data/maps/map001.json"


static func terrain_char(t: int) -> String:
	for c in CHARS:
		if CHARS[c] == t:
			return c
	return "G"


## 从 terrain 网格推导 2x2 山块的左上角锚点（用于渲染整块山）
static func mountain_anchors_from(terra: Array, w: int, h: int) -> Array:
	var out := []
	for x in w:
		for y in h:
			if terra[x][y] != SrpgData.Terrain.MOUNTAIN:
				continue
			var left: bool = x == 0 or terra[x - 1][y] != SrpgData.Terrain.MOUNTAIN
			var up: bool = y == 0 or terra[x][y - 1] != SrpgData.Terrain.MOUNTAIN
			if left and up:
				out.append(Vector2i(x, y))
	return out


static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


static func save_file(path: String, dict: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(dict, "  "))
	f.close()
	return true


## 内置演示图（没有地图文件时的兜底，也是编辑器首次打开的内容）
static func default_map_dict() -> Dictionary:
	var rows := []
	for y in SrpgData.MAP_H:
		rows.append("G".repeat(SrpgData.MAP_W))
	for y in range(2, 13):
		rows[y] = _set_rows_char(rows, 9, y, "D")
	for x in range(2, 18):
		rows[7] = _set_rows_char(rows, x, 7, "D")
	for c in SrpgData.FORESTS:
		rows[c.y] = _set_rows_char(rows, c.x, c.y, "F")
	for c in SrpgData.WATERS:
		rows[c.y] = _set_rows_char(rows, c.x, c.y, "W")
	for m in SrpgData.MOUNTAINS:
		for dx in 2:
			for dy in 2:
				rows[m.y + dy] = _set_rows_char(rows, m.x + dx, m.y + dy, "M")

	var placements := []
	for p in SrpgData.PLACEMENTS:
		placements.append({
			"uid": "%s_%d" % [p["id"], placements.size()],
			"tpl": p["id"],
			"cell": [p["cell"].x, p["cell"].y],
		})

	return {
		"name": "草原遭遇战",
		"width": SrpgData.MAP_W,
		"height": SrpgData.MAP_H,
		"rows": rows,
		"win": {"type": "rout", "uid": ""},
		"placements": placements,
		"events": [
			{
				"name": "开场对话",
				"trigger": {"type": "turn_start", "turn": 1, "phase": "player"},
				"once": true, "condition": {},
				"commands": [
					{"cmd": "dialogue", "speaker": "witch",
						"lines": ["糟了，兽人比情报里的多……", "不过没关系，伊伊大人的魔法可不是摆设！"]},
					{"cmd": "dialogue", "speaker": "sword",
						"lines": ["打头阵的活儿永远归我。……上吧！"]},
				],
			},
			{
				"name": "第3回合敌方增援",
				"trigger": {"type": "turn_start", "turn": 3, "phase": "enemy"},
				"once": true, "condition": {},
				"commands": [
					{"cmd": "dialogue", "speaker": "narrator",
						"lines": ["远处传来了号角声——敌方增援到了！"]},
					{"cmd": "spawn", "tpl": "orc", "cells": [[9, 2], [10, 2]]},
					{"cmd": "spawn", "tpl": "wolf", "cells": [[9, 11]]},
				],
			},
		],
	}


static func _set_rows_char(rows: Array, x: int, y: int, ch: String) -> String:
	var row: String = rows[y]
	return row.substr(0, x) + ch + row.substr(x + 1)
