class_name ArpgFlowField
extends RefCounted
## 流程场（SupCom2「Crowd Pathing & Steering Using Flow Field Tiles」式共享寻路层）：
## 从锚点格（主控单位）做全图 BFS，导出每格「指向锚点的行进方向」。
## 一次计算全场怪共享（44×32=1408 格，GDScript 也 <2ms）；
## 墙体阻挡自动绕行走廊——根治「墙另一侧的怪贴墙硬推」。

const W_INF := 1 << 28

var w := 0
var h := 0
var dist := PackedInt32Array()      # BFS 波前距离（墙 = W_INF）
var dir := PackedVector2Array()     # 每格行进方向（单位向量；锚点/不可达 = ZERO）
var valid := false

const _N4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const _N8 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]


func build(d: ArpgDungeon, anchor: Vector2i) -> void:
	w = d.w
	h = d.h
	var n := maxi(1, w * h)
	dist.resize(n)
	dir.resize(n)
	# 热路径：直接把 dungeon.grid 取成本地引用（d.is_floor 每格函数调用是主要开销）
	var g: Array = d.grid
	if anchor.x < 0 or anchor.y < 0 or anchor.x >= w or anchor.y >= h or g[anchor.x][anchor.y] != ArpgDungeon.FLOOR:
		valid = false
		return
	valid = true
	# —— BFS：等权网格上队列展开即最短路 ——
	dist.fill(W_INF)
	var q := PackedInt32Array()
	q.resize(n)
	var qh := 0
	var qt := 0
	var ai := anchor.y * w + anchor.x
	dist[ai] = 0
	q[qt] = ai
	qt += 1
	while qh < qt:
		var c: int = q[qh]
		qh += 1
		var nd: int = dist[c] + 1
		var cx: int = c % w
		var cy: int = c / w
		# 四邻展开（内联，省 Vector2i 分配）
		if cx + 1 < w and g[cx + 1][cy] == ArpgDungeon.FLOOR:
			var ni1: int = cy * w + cx + 1
			if dist[ni1] > nd:
				dist[ni1] = nd
				q[qt] = ni1
				qt += 1
		if cx > 0 and g[cx - 1][cy] == ArpgDungeon.FLOOR:
			var ni2: int = cy * w + cx - 1
			if dist[ni2] > nd:
				dist[ni2] = nd
				q[qt] = ni2
				qt += 1
		if cy + 1 < h and g[cx][cy + 1] == ArpgDungeon.FLOOR:
			var ni3: int = (cy + 1) * w + cx
			if dist[ni3] > nd:
				dist[ni3] = nd
				q[qt] = ni3
				qt += 1
		if cy > 0 and g[cx][cy - 1] == ArpgDungeon.FLOOR:
			var ni4: int = (cy - 1) * w + cx
			if dist[ni4] > nd:
				dist[ni4] = nd
				q[qt] = ni4
				qt += 1
	# —— 方向场：指向 dist 更低的邻格 ——
	# 斜向需要两个正交邻格都可走（防切墙角）；无更优邻格（锚点/死路）= ZERO
	# 八向偏移表内联成常量数组，避免 Vector2i 构造
	var dxs := [1, -1, 0, 0, 1, 1, -1, -1]
	var dys := [0, 0, 1, -1, 1, -1, 1, -1]
	for y in h:
		for x in w:
			var idx: int = y * w + x
			if g[x][y] != ArpgDungeon.FLOOR or dist[idx] >= W_INF:
				dir[idx] = Vector2.ZERO
				continue
			var best: int = dist[idx]
			var bx := 0
			var by := 0
			for k in 8:
				var ox: int = dxs[k]
				var oy: int = dys[k]
				var nx: int = x + ox
				var ny: int = y + oy
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				if g[nx][ny] != ArpgDungeon.FLOOR:
					continue
				if ox != 0 and oy != 0:
					# 斜向防穿角：两个正交邻格必须都可走
					if g[x + ox][y] != ArpgDungeon.FLOOR or g[x][y + oy] != ArpgDungeon.FLOOR:
						continue
				var nd2: int = dist[ny * w + nx]
				if nd2 < best:
					best = nd2
					bx = ox
					by = oy
			if bx == 0 and by == 0:
				dir[idx] = Vector2.ZERO
			elif bx == 0:
				dir[idx] = Vector2(0, by)
			elif by == 0:
				dir[idx] = Vector2(bx, 0)
			else:
				dir[idx] = Vector2(bx, by).normalized()


## 查询某世界坐标处的行进方向；无效/不可达返回 ZERO（调用方回退直线追）
func dir_at(p: Vector2, tile: int) -> Vector2:
	if not valid:
		return Vector2.ZERO
	var cx := int(p.x / tile)
	var cy := int(p.y / tile)
	if cx < 0 or cy < 0 or cx >= w or cy >= h:
		return Vector2.ZERO
	return dir[cy * w + cx]
