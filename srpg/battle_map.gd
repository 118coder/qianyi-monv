class_name SrpgBattleMap
extends Node2D
## 战棋地图：地形网格、Dijkstra 可达范围、路径还原、伤害公式，以及全部格子级绘制。
## 地图数据由 SrpgMapLoader 的 JSON 字典构建（编辑器产出）。
## 「占用字典 cell->unit + 范围高亮」的模式参考自 GDQuest 2D tactical movement demo（MIT）。

const TEX_GROUND := preload("res://assets/tiles/TileA2.png")
const TEX_WATER := preload("res://assets/tiles/TileA1.png")
const TEX_OVERWORLD := preload("res://assets/tiles/Overworld_TileA2.png")

# 图块源区域（VX Ace 32px 规格，坐标均已逐块裁剪核对）
const SRC_GRASS := Rect2(32, 32, 32, 32)        # A2 (0,0) 草块右下象限 = 无边缘纯草
const SRC_DIRT := Rect2(32, 96, 32, 32)         # A2 (0,64) 土块右下象限
const SRC_WATER := Rect2(32, 128, 32, 32)       # A1 深水内部
const SRC_FOREST := [
	Rect2(128, 0, 32, 32), Rect2(160, 0, 32, 32),
	Rect2(128, 32, 32, 32), Rect2(160, 32, 32, 32),
]
const SRC_MOUNTAIN := Rect2(448, 0, 64, 64)     # Overworld A2 灰色山峰整块

const DIRS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

var w := 0
var h := 0
var terrain := []                # terrain[x][y] -> SrpgData.Terrain
var mountain_anchors := []       # 2x2 山块左上角锚点（渲染用）

# —— 绘制状态：由 main 在状态变化时写入，然后调用 queue_redraw() ——
var move_cells := []
var attack_cells := []
var danger_cells := []
var path_cells := []
var target_cells := []
var target_is_heal := false
var hover_cell := Vector2i(-1, -1)


## 从 JSON 地图字典构建（SrpgMapLoader 的格式）
func build_from(mdict: Dictionary) -> void:
	w = int(mdict.get("width", 20))
	h = int(mdict.get("height", 14))
	terrain = []
	for x in w:
		var col := []
		col.resize(h)
		col.fill(SrpgData.Terrain.GRASS)
		terrain.append(col)
	var rows: Array = mdict.get("rows", [])
	for y in h:
		if y >= rows.size():
			break
		var row: String = rows[y]
		for x in w:
			if x >= row.length():
				break
			terrain[x][y] = SrpgMapLoader.CHARS.get(row[x], SrpgData.Terrain.GRASS)
	mountain_anchors = SrpgMapLoader.mountain_anchors_from(terrain, w, h)


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < w and c.y < h


func terrain_at(c: Vector2i) -> int:
	if in_bounds(c):
		return terrain[c.x][c.y]
	return SrpgData.Terrain.MOUNTAIN


func move_cost(c: Vector2i) -> int:
	return SrpgData.TERRAIN[terrain_at(c)]["cost"]


func terrain_def(c: Vector2i) -> int:
	return SrpgData.TERRAIN[terrain_at(c)]["def"]


func terrain_name(c: Vector2i) -> String:
	return SrpgData.TERRAIN[terrain_at(c)]["name"]


static func cell_to_pos(c: Vector2i) -> Vector2:
	return Vector2(c) * float(SrpgData.TILE) + Vector2.ONE * (SrpgData.TILE * 0.5)


static func pos_to_cell(p: Vector2) -> Vector2i:
	return Vector2i((p / float(SrpgData.TILE)).floor())


func manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


## 伤害 = 攻 - 防；法术无视地形防御；保底 1 点
func calc_damage(att: SrpgUnit, dfn: SrpgUnit) -> int:
	var def_eff := dfn.def + (0 if att.is_magic else terrain_def(dfn.cell))
	return maxi(1, att.atk - def_eff)


## Dijkstra：从 origin 出发、总消耗 ≤ mov 的可达格。
## occupied: {cell: true} 占用表（不能停留、也不能穿过）。
## 返回 {cell: {"cost": int, "parent": Vector2i}}，不含 origin。
func reachable(origin: Vector2i, mov: int, occupied: Dictionary) -> Dictionary:
	var dist := {origin: 0}
	var parent := {}
	var open := [origin]
	while not open.is_empty():
		var bi := 0
		for i in open.size():
			if dist[open[i]] < dist[open[bi]]:
				bi = i
		var cur: Vector2i = open[bi]
		open.remove_at(bi)
		var cur_cost: int = dist[cur]
		if cur_cost >= mov:
			continue
		for d in DIRS:
			var nxt: Vector2i = cur + d
			if not in_bounds(nxt) or occupied.get(nxt, false):
				continue
			var nc := cur_cost + move_cost(nxt)
			if nc > mov:
				continue
			if not dist.has(nxt) or nc < dist[nxt]:
				dist[nxt] = nc
				parent[nxt] = cur
				if not open.has(nxt):
					open.append(nxt)
	var out := {}
	for c in dist:
		if c == origin:
			continue
		out[c] = {"cost": dist[c], "parent": parent.get(c, origin)}
	return out


## 曼哈顿距离在 [rmin, rmax] 内、且在图内的格子
func cells_in_range(origin: Vector2i, rmin: int, rmax: int) -> Array:
	var out := []
	for dx in range(-rmax, rmax + 1):
		for dy in range(-rmax, rmax + 1):
			var md := absi(dx) + absi(dy)
			if md < rmin or md > rmax:
				continue
			var c := origin + Vector2i(dx, dy)
			if in_bounds(c):
				out.append(c)
	return out


## 从 reachable() 的结果还原路径（不含起点，含终点）
func path_from(reach: Dictionary, dest: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var cur := dest
	while reach.has(cur):
		path.push_front(cur)
		var par: Vector2i = reach[cur]["parent"]
		if not reach.has(par):
			break
		cur = par
	return path


func _rect(c: Vector2i) -> Rect2:
	return Rect2(c.x * 32, c.y * 32, 32, 32)


func _draw() -> void:
	# 地面
	for x in w:
		for y in h:
			var c := Vector2i(x, y)
			var r := _rect(c)
			var t := terrain_at(c)
			if t == SrpgData.Terrain.WATER:
				draw_texture_rect_region(TEX_WATER, r, SRC_WATER)
			else:
				draw_texture_rect_region(TEX_GROUND, r, SRC_GRASS)
			if t == SrpgData.Terrain.DIRT:
				draw_texture_rect_region(TEX_GROUND, r, SRC_DIRT)
			elif t == SrpgData.Terrain.FOREST:
				var fi := (c.x % 2) + (c.y % 2) * 2
				draw_texture_rect_region(TEX_GROUND, r, SRC_FOREST[fi])
	for m in mountain_anchors:
		draw_texture_rect_region(TEX_OVERWORLD, Rect2(m.x * 32, m.y * 32, 64, 64), SRC_MOUNTAIN)

	# 高亮叠加：危险区 < 攻击边缘 < 移动范围 < 目标格
	for c in danger_cells:
		draw_rect(_rect(c), Color(1.0, 0.22, 0.15, 0.16), true)
	for c in attack_cells:
		draw_rect(_rect(c), Color(1.0, 0.32, 0.22, 0.38), true)
	for c in move_cells:
		draw_rect(_rect(c), Color(0.36, 0.6, 1.0, 0.42), true)
	var tcol := Color(0.35, 1.0, 0.45, 0.5) if target_is_heal else Color(1.0, 0.28, 0.2, 0.5)
	for c in target_cells:
		draw_rect(_rect(c), tcol, true)
		draw_rect(_rect(c), Color(1, 0.95, 0.4, 0.9), false, 2.0)
	for c in path_cells:
		draw_circle(cell_to_pos(c), 4.0, Color(1, 1, 1, 0.85))
	if hover_cell.x >= 0:
		draw_rect(_rect(hover_cell), Color(1, 1, 1, 0.8), false, 2.0)
