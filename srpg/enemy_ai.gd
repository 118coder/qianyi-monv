class_name SrpgEnemyAI
extends RefCounted
## 敌方 AI：枚举「可停留格 x 射程内玩家」打分选最优；无可打目标则向最近玩家逼近。
## boss 为守望型：玩家不进入其 移动+射程 半径就不动。
## 评分思路（斩杀 > 高伤 > 低反击 > 好地形）参考 ramaureirac/godot-tactical-rpg（MIT）。


static func plan(unit: SrpgUnit, map: SrpgBattleMap, all_units: Array) -> Dictionary:
	var players := []
	var occupied := {}
	for u in all_units:
		if u == null or not is_instance_valid(u):
			continue
		if u.faction == "player":
			players.append(u)
		if u != unit:
			occupied[u.cell] = true

	var reach := map.reachable(unit.cell, unit.mov, occupied)
	var candidates: Array = reach.keys()
	candidates.append(unit.cell)   # 原地不动也是一个选项

	var best_score := -INF
	var best_cell := Vector2i(-999, -999)
	var best_target: SrpgUnit = null
	for c in candidates:
		var cost: int = reach[c]["cost"] if reach.has(c) else 0
		for p in players:
			var d := map.manhattan(c, p.cell)
			if d < unit.rmin or d > unit.rmax:
				continue
			var dmg := map.calc_damage(unit, p)
			var counter := 0
			if d >= p.rmin and d <= p.rmax:
				counter = map.calc_damage(p, unit)
			var score := dmg * 10.0 - counter * 8.0 + map.terrain_def(c) * 3.0 - cost * 2.0
			if dmg >= p.hp:
				score += 1000.0   # 能斩杀就优先斩杀
			if score > best_score:
				best_score = score
				best_cell = c
				best_target = p

	if unit.is_boss and best_target == null:
		var provoked := false
		for p in players:
			if map.manhattan(unit.cell, p.cell) <= unit.mov + unit.rmax:
				provoked = true
				break
		if not provoked:
			return {"wait": true, "path": [], "cell": unit.cell, "target": null}

	if best_target != null:
		var path: Array[Vector2i] = []
		if best_cell != unit.cell:
			path = map.path_from(reach, best_cell)
		return {"wait": false, "path": path, "cell": best_cell, "target": best_target}

	# 追击：可达格里挑离最近玩家曼哈顿距离最小的，顺带偏好好地形
	var chase_score := INF
	var chase_cell := Vector2i(-999, -999)
	for c in candidates:
		var dmin := INF
		for p in players:
			dmin = minf(dmin, float(map.manhattan(c, p.cell)))
		var score := dmin - map.terrain_def(c) * 0.4
		if score < chase_score:
			chase_score = score
			chase_cell = c
	if chase_cell == Vector2i(-999, -999) or chase_cell == unit.cell:
		return {"wait": true, "path": [], "cell": unit.cell, "target": null}
	return {"wait": false, "path": map.path_from(reach, chase_cell), "cell": chase_cell, "target": null}
