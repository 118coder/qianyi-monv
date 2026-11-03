extends RefCounted
## 场景数据模型：多图层的格子画布 + JSON 序列化。
##
## 为什么不复用游戏的 `ArpgDungeon`：那是**程序化生成**的地牢（BSP + A* 走廊），
## 数据是「格子是墙还是地板」的二值网格；这里要的是**手工摆放图块**的场景，
## 每格存的是"图块集里的第几号图块"，还要分图层。两者结构不同，硬合并只会互相拖累。
##
## 存储格式刻意做成最朴素的形态（宽、高、图块尺寸、图层数组），
## 这样将来要在游戏里加载手搭场景时，读起来没有任何额外成本。

const EMPTY := -1

var scene_name := "新场景"
var tile_size := 32
var cols := 40
var rows := 24
var tileset_path := ""
var tileset_cols := 16          # 图块集横向图块数（由 PNG 宽 / tile_size 推出）
var tileset_rows := 12
var layers: Array = []          # [{name: String, visible: bool, data: PackedInt32Array}]
var cur_layer := 0


func setup_default() -> void:
	layers = [
		{"name": "地面", "visible": true, "data": _blank()},
		{"name": "装饰", "visible": true, "data": _blank()},
	]
	cur_layer = 0


func _blank() -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(cols * rows)
	a.fill(EMPTY)
	return a


## 改尺寸：保留重叠区域的内容，多出来的格子补空
func resize(nc: int, nr: int) -> void:
	nc = clampi(nc, 4, 512)
	nr = clampi(nr, 4, 512)
	if nc == cols and nr == rows:
		return
	for L in layers:
		var old: PackedInt32Array = L["data"]
		var fresh := PackedInt32Array()
		fresh.resize(nc * nr)
		fresh.fill(EMPTY)
		for y in mini(nr, rows):
			for x in mini(nc, cols):
				fresh[y * nc + x] = old[y * cols + x]
		L["data"] = fresh
	cols = nc
	rows = nr


func add_layer(lname: String) -> void:
	layers.append({"name": lname, "visible": true, "data": _blank()})
	cur_layer = layers.size() - 1


func remove_layer(i: int) -> void:
	if layers.size() <= 1 or i < 0 or i >= layers.size():
		return
	layers.remove_at(i)
	cur_layer = clampi(cur_layer, 0, layers.size() - 1)


func move_layer(from: int, to: int) -> void:
	if from == to or from < 0 or to < 0 or from >= layers.size() or to >= layers.size():
		return
	var L = layers[from]
	layers.remove_at(from)
	layers.insert(to, L)
	cur_layer = to


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < cols and y < rows


func get_cell(layer: int, x: int, y: int) -> int:
	if layer < 0 or layer >= layers.size() or not in_bounds(x, y):
		return EMPTY
	return int((layers[layer]["data"] as PackedInt32Array)[y * cols + x])


func set_cell(layer: int, x: int, y: int, v: int) -> void:
	if layer < 0 or layer >= layers.size() or not in_bounds(x, y):
		return
	var d: PackedInt32Array = layers[layer]["data"]
	d[y * cols + x] = v


## 整层填充（工具：油漆桶）
func fill_layer(layer: int, v: int) -> void:
	if layer < 0 or layer >= layers.size():
		return
	var d: PackedInt32Array = layers[layer]["data"]
	d.fill(v)


## 快照：撤销栈存的就是这个
func snapshot() -> Array:
	var out: Array = []
	for L in layers:
		out.append({
			"name": L["name"], "visible": L["visible"],
			"data": (L["data"] as PackedInt32Array).duplicate(),
		})
	return out


func restore(snap: Array) -> void:
	if snap == null or snap.is_empty():
		return
	layers = []
	for L in snap:
		layers.append({
			"name": L["name"], "visible": L["visible"],
			"data": (L["data"] as PackedInt32Array).duplicate(),
		})
	cur_layer = clampi(cur_layer, 0, layers.size() - 1)


func to_dict() -> Dictionary:
	var ls: Array = []
	for L in layers:
		ls.append({
			"name": L["name"],
			"visible": L["visible"],
			"data": Array(L["data"]),      # PackedInt32Array → 普通数组才能进 JSON
		})
	return {
		"version": 1,
		"name": scene_name,
		"tile_size": tile_size,
		"width": cols,
		"height": rows,
		"tileset": tileset_path,
		"tileset_cols": tileset_cols,
		"tileset_rows": tileset_rows,
		"layers": ls,
	}


static func from_dict(d: Dictionary) -> RefCounted:
	var s = (load("res://creator/core/tile_scene.gd") as GDScript).new()
	s.scene_name = str(d.get("name", "未命名"))
	s.tile_size = int(d.get("tile_size", 32))
	s.cols = int(d.get("width", 40))
	s.rows = int(d.get("height", 24))
	s.tileset_path = str(d.get("tileset", ""))
	s.tileset_cols = int(d.get("tileset_cols", 16))
	s.tileset_rows = int(d.get("tileset_rows", 12))
	s.layers = []
	for L in d.get("layers", []):
		var a := PackedInt32Array()
		for v in L.get("data", []):
			a.append(int(v))
		a.resize(s.cols * s.rows)
		s.layers.append({
			"name": str(L.get("name", "图层")),
			"visible": bool(L.get("visible", true)),
			"data": a,
		})
	if s.layers.is_empty():
		s.setup_default()
	return s
