class_name ArpgMobSystem
extends Node2D
## 数据导向敌群系统（支撑上万敌人）：
##  · SoA 定容数组（无节点、无逐实体 _process）
##  · 空间哈希：O(1) 邻域查询（攻击/弹幕命中不再全表扫描）
##  · WorkerThreadPool 多线程模拟（分块并行，仅写各自下标，主线程合流）
##  · LOD 分层：近处每帧 / 中距每 3 帧 / 远处每 8 帧（×步长补偿）
##  · 单批次渲染：视野裁剪 + y 排序 + 玩家也画进同一批（一个画布项）
##  · 事件缓冲：线程内只标记（咬人/射击/特殊技），主线程执行（生成节点/特效）

const MAX_MOBS := 12000
const HASH_CELL := 64.0
const THREAD_THRESHOLD := 300
var _aggro := 185.0
const TILE := ArpgData.TILE

var main: Node
var world: Node
var dungeon: ArpgDungeon

# —— 模板表（ArpgBalance.ENEMIES 顺序 + BOSS 末尾）——
var tpl_name: PackedStringArray = []
var tpl_hp := PackedInt32Array()
var tpl_atk := PackedInt32Array()
var tpl_spd := PackedFloat32Array()
var tpl_xp := PackedInt32Array()
var tpl_radius := PackedFloat32Array()
var tpl_atk_range := PackedFloat32Array()
var tpl_keep := PackedFloat32Array()
var tpl_windup := PackedFloat32Array()
var tpl_cool := PackedFloat32Array()
var tpl_behavior := PackedByteArray()      # 0 melee 1 ranged 2 boss
var tpl_block := PackedVector2Array()      # 角色块左上角
var tpl_scale := PackedFloat32Array()
var tpl_count := 0

# —— 实体 SoA ——
var count := 0
var pos := PackedVector2Array()
var vel := PackedVector2Array()
var knock := PackedVector2Array()
var lunge := PackedVector2Array()
var hp := PackedInt32Array()
var max_hp := PackedInt32Array()
var atk := PackedInt32Array()
var spd := PackedFloat32Array()
var xp := PackedInt32Array()
var radius := PackedFloat32Array()
var atk_range := PackedFloat32Array()
var tpl := PackedInt32Array()
var elite := PackedByteArray()
var boss := PackedByteArray()
var aggro := PackedByteArray()
var alive := PackedByteArray()
var state := PackedByteArray()             # 0 wander 1 chase 2 windup
var windup_t := PackedFloat32Array()
var cool_t := PackedFloat32Array()
var special_t := PackedFloat32Array()
var flash_t := PackedFloat32Array()
var facing := PackedByteArray()            # 0下 1左 2右 3上
var anim_t := PackedFloat32Array()
var wander_dir := PackedVector2Array()
var wander_t := PackedFloat32Array()
var enraged := PackedByteArray()

# —— 空间哈希 ——
var _hash := {}
var _used_keys := []

# —— 多线程 / 事件 ——
# 多目标：targets[0]=玩家，[1..]=队友（主线程每帧刷新）；每只敌人记忆目标下标（仇恨）
var targets := PackedVector2Array()
var target_alive := PackedByteArray()
var tgt := PackedByteArray()
var _cur_delta := 0.016
var _chunk_n := 0
var _chunk_events := []
var frame_no := 0
var sim_ms := 0.0
var _vis: Array = []          # [y, kind, idx] 复用列表
var _sheet: Texture2D

# 事件类型
const EV_BITE := 0
const EV_SHOOT := 1
const EV_SPECIAL := 2


func setup(m: Node, w: Node, d: ArpgDungeon) -> void:
	main = m
	world = w
	dungeon = d
	var cap := MAX_MOBS
	pos.resize(cap)
	vel.resize(cap)
	knock.resize(cap)
	lunge.resize(cap)
	hp.resize(cap)
	max_hp.resize(cap)
	atk.resize(cap)
	spd.resize(cap)
	xp.resize(cap)
	radius.resize(cap)
	atk_range.resize(cap)
	tpl.resize(cap)
	elite.resize(cap)
	boss.resize(cap)
	aggro.resize(cap)
	alive.resize(cap)
	state.resize(cap)
	windup_t.resize(cap)
	cool_t.resize(cap)
	special_t.resize(cap)
	flash_t.resize(cap)
	facing.resize(cap)
	anim_t.resize(cap)
	wander_dir.resize(cap)
	wander_t.resize(cap)
	enraged.resize(cap)
	for tpl_id in ArpgBalance.ENEMIES:
		_push_tpl(tpl_id, ArpgBalance.ENEMIES[tpl_id], false)
	_push_tpl("boss", ArpgBalance.BOSS, true)
	tpl_count = tpl_name.size()
	_sheet = ArpgTex.tex(ArpgData.MONSTER)


func _push_tpl(id: String, t: Dictionary, is_boss: bool) -> void:
	tpl_name.append(id)
	tpl_hp.append(t["hp"])
	tpl_atk.append(t["atk"])
	tpl_spd.append(float(t["spd"]))
	tpl_xp.append(t["xp"])
	tpl_radius.append(9.0 * float(t.get("scale", 1.0)))
	tpl_atk_range.append(float(t["atk_range"]))
	tpl_keep.append(float(t.get("keep", 0.0)))
	tpl_windup.append(float(t["windup"]))
	tpl_cool.append(float(t["cool"]))
	tpl_behavior.append(2 if is_boss else (1 if t["behavior"] == "ranged" else 0))
	tpl_block.append(Vector2(t["sprite"][1], t["sprite"][2]))
	tpl_scale.append(float(t.get("scale", 1.0)))


# ———————— 生成 / 查询（主线程） ————————

func spawn(tpl_id: String, cell: Vector2i, elite_f: bool = false, boss_f: bool = false) -> int:
	if count >= MAX_MOBS:
		return -1
	var ti := tpl_count - 1 if boss_f else tpl_name.find(tpl_id)
	if ti < 0:
		return -1
	var i := count
	count += 1
	var mult := 1.3 if elite_f else 1.0
	pos[i] = ArpgDungeon.cell_to_pos(cell)
	vel[i] = Vector2.ZERO
	knock[i] = Vector2.ZERO
	lunge[i] = Vector2.ZERO
	max_hp[i] = int(tpl_hp[ti] * mult)
	hp[i] = max_hp[i]
	atk[i] = int(tpl_atk[ti] * mult)
	spd[i] = tpl_spd[ti]
	xp[i] = int(tpl_xp[ti] * (2.0 if elite_f else 1.0))
	radius[i] = tpl_radius[ti]
	atk_range[i] = tpl_atk_range[ti]
	tpl[i] = ti
	elite[i] = 1 if elite_f else 0
	boss[i] = 1 if boss_f else 0
	aggro[i] = 0
	alive[i] = 1
	state[i] = 0
	windup_t[i] = 0.0
	cool_t[i] = 0.0
	special_t[i] = 3.0
	flash_t[i] = 0.0
	facing[i] = 0
	anim_t[i] = randf() * 0.5
	wander_dir[i] = Vector2.ZERO
	wander_t[i] = randf() * 2.0
	enraged[i] = 0
	return i


func is_alive(i: int) -> bool:
	return i >= 0 and i < count and alive[i] == 1 and hp[i] > 0


func damage(i: int, dmg: int, from: Vector2, knock_amt: float = 150.0) -> void:
	if not is_alive(i):
		return
	hp[i] = maxi(0, hp[i] - dmg)
	flash_t[i] = 0.15
	aggro[i] = 1
	knock[i] += (pos[i] - from).normalized() * knock_amt
	# 仇恨：被谁打就大概率转头打谁（含队友）——拉怪/围殴/救场都成立
	if tgt.size() > i and targets.size() > 0:
		var best_t := int(tgt[i])
		if best_t >= targets.size():
			best_t = 0
		var bd := 1e9
		for t in targets.size():
			if target_alive[t] == 0:
				continue
			var dd: float = targets[t].distance_to(from)
			if dd < bd:
				bd = dd
				best_t = t
		if bd < 320.0 and randf() < 0.65:
			tgt[i] = best_t
	if boss[i] == 1:
		main.hud.show_boss_bar(true, float(hp[i]) / max_hp[i], tpl_name[tpl[i]])


func nearest(from: Vector2, max_d: float = 1e12) -> int:
	var best := -1
	var bd := max_d
	for c in _query_cells(from, minf(max_d, 1400.0)):
		for i in c:
			if hp[i] <= 0:
				continue
			var d: float = pos[i].distance_to(from)
			if d < bd:
				bd = d
				best = i
	if best == -1 and max_d > 1400.0:
		for i in count:   # 兜底全表
			if hp[i] > 0:
				var d: float = pos[i].distance_to(from)
				if d < bd:
					bd = d
					best = i
	return best


func in_radius(from: Vector2, r: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	for c in _query_cells(from, r):
		for i in c:
			if hp[i] > 0 and pos[i].distance_to(from) <= r + radius[i]:
				out.append(i)
	return out


func find_boss() -> int:
	for i in count:
		if boss[i] == 1 and hp[i] > 0:
			return i
	return -1


func tpl_of(i: int) -> String:
	return tpl_name[tpl[i]]


func _query_cells(from: Vector2, r: float) -> Array:
	var out := []
	var cx := int(from.x / HASH_CELL)
	var cy := int(from.y / HASH_CELL)
	var cr := int(r / HASH_CELL) + 1
	for gx in range(cx - cr, cx + cr + 1):
		for gy in range(cy - cr, cy + cr + 1):
			var arr = _hash.get(gx * 100000 + gy)
			if arr != null and not arr.is_empty():
				out.append(arr)
	return out


# ———————— 主循环 ————————

func _physics_process(delta: float) -> void:
	if main == null or main.state != main.State.PLAY:
		return
	frame_no += 1
	var t0 := Time.get_ticks_usec()
	refresh_targets()
	# 空间哈希（每帧主线程重建，供攻击/弹幕查询）
	_build_hash()
	# 模拟（多线程分块 / 小规模直跑）
	var chunks := 1
	if count > THREAD_THRESHOLD:
		chunks = clampi(int(count / 400.0), 2, 8)
	_ensure_chunks(chunks)
	_cur_delta = delta
	_chunk_n = ceili(count / float(chunks))
	if chunks > 1:
		var gid := WorkerThreadPool.add_group_task(Callable(self, "_sim_chunk"), chunks, chunks, true)
		WorkerThreadPool.wait_for_group_task_completion(gid)
	else:
		_sim_chunk(0)
	sim_ms = (Time.get_ticks_usec() - t0) / 1000.0
	_drain_events()
	_handle_deaths()
	queue_redraw()


func _ensure_chunks(n: int) -> void:
	if _chunk_events.size() == n:
		for b in _chunk_events:
			b.clear()
		return
	_chunk_events.clear()
	for i in n:
		_chunk_events.append([])


func _sim_chunk(ci: int) -> void:
	var ev: Array = _chunk_events[ci]
	var a := ci * _chunk_n
	var b := mini(count, a + _chunk_n)
	_sim_range(a, b, _cur_delta, ev)


## 主线程每帧刷新目标表：[玩家, 队友...]。谁在场谁可能被围殴
func refresh_targets() -> void:
	targets.clear()
	var al := PackedByteArray()
	var pl = world.player
	if pl != null and is_instance_valid(pl) and not pl.dead:
		targets.append(pl.position)
		al.append(1)
	else:
		targets.append(pl.position if pl != null and is_instance_valid(pl) else Vector2(-9999, -9999))
		al.append(0)
	if main.party != null:
		for f in main.party.friends:
			if is_instance_valid(f) and not f.dead:
				targets.append(f.position)
				al.append(1)
			else:
				targets.append(f.position if is_instance_valid(f) else Vector2(-9999, -9999))
				al.append(0)
	target_alive = al
	_aggro = float(ArpgBalance.data.get("aggro_range", 185.0))
	while tgt.size() < count:
		tgt.append(0)
	for i in count:
		if tgt[i] >= targets.size():
			tgt[i] = 0


## 线程内安全：只读 targets/target_alive
func _nearest_target(p: Vector2) -> int:
	var best := 0
	var bd := 1e12
	for t in targets.size():
		if target_alive[t] == 0:
			continue
		var dd: float = targets[t].distance_squared_to(p)
		if dd < bd:
			bd = dd
			best = t
	return best


func _sim_range(a: int, b: int, dt: float, ev: Array) -> void:
	for i in range(a, b):
		if alive[i] == 0 or hp[i] <= 0:
			continue
		var p := pos[i]
		# 当前目标失效（死亡/离场）→ 换最近存活目标
		if target_alive[tgt[i]] == 0:
			tgt[i] = _nearest_target(p)
		var to_p := targets[tgt[i]] - p
		var dist := to_p.length()
		# LOD：近处每帧，中距每 3 帧，远处每 8 帧（步长补偿）
		var lod := 1
		if dist > 900.0:
			lod = 8
		elif dist > 420.0:
			lod = 3
		if lod > 1 and (frame_no + i) % lod != 0:
			continue
		var d := dt * lod
		cool_t[i] = maxf(0.0, cool_t[i] - d)
		if flash_t[i] > 0.0:
			flash_t[i] -= d
		if not aggro[i]:
			if dist < _aggro and target_alive[tgt[i]] == 1:
				aggro[i] = 1
			else:
				_wander(i, d)
				_try_move(i, d)
				continue
		if target_alive[tgt[i]] == 0:
			_wander(i, d)
			_try_move(i, d)
			continue
		var beh := tpl_behavior[tpl[i]]
		if windup_t[i] > 0.0:
			# 蓄力：站定，结束时发事件（主线程执行咬人/射击，事件带目标下标）
			windup_t[i] -= d
			vel[i] = Vector2.ZERO
			if windup_t[i] <= 0.0:
				if beh == 1:
					ev.append([EV_SHOOT, i, to_p.normalized(), tgt[i]])
				else:
					ev.append([EV_BITE, i, tgt[i]])
				cool_t[i] = tpl_cool[tpl[i]]
		elif beh == 2:
			special_t[i] -= d
			if enraged[i] == 0 and hp[i] < max_hp[i] * 0.4:
				enraged[i] = 1
				spd[i] = tpl_spd[tpl[i]] * 1.35
			if special_t[i] <= 0.0:
				special_t[i] = 2.6 if enraged[i] == 1 else 3.4
				ev.append([EV_SPECIAL, i])
			_melee_move(i, to_p, dist)
		elif beh == 1:
			_ranged_move(i, to_p, dist)
		else:
			_melee_move(i, to_p, dist)
		_try_move(i, d)


func _melee_move(i: int, to_p: Vector2, dist: float) -> void:
	if dist > atk_range[i]:
		vel[i] = to_p / maxf(dist, 0.01) * spd[i]
	elif cool_t[i] <= 0.0:
		state[i] = 2
		windup_t[i] = tpl_windup[tpl[i]]
		vel[i] = Vector2.ZERO
	else:
		vel[i] = Vector2.ZERO


func _ranged_move(i: int, to_p: Vector2, dist: float) -> void:
	var keep := tpl_keep[tpl[i]]
	if cool_t[i] <= 0.0 and dist < tpl_atk_range[tpl[i]]:
		state[i] = 2
		windup_t[i] = tpl_windup[tpl[i]]
		vel[i] = Vector2.ZERO
	elif dist > keep + 36.0:
		vel[i] = to_p / maxf(dist, 0.01) * spd[i]
	elif dist < keep - 36.0:
		vel[i] = -to_p / maxf(dist, 0.01) * spd[i]
	else:
		vel[i] = Vector2.ZERO


func _wander(i: int, d: float) -> void:
	wander_t[i] -= d
	if wander_t[i] <= 0.0:
		wander_t[i] = 2.0 + float(i % 7) * 0.4
		# 确定性伪随机（线程内禁用全局 randf）：黄金角散列
		var ang := (float(i % 512) / 512.0 + float(wander_t[i]) * 0.37) * TAU
		wander_dir[i] = Vector2.RIGHT.rotated(ang) if (i + frame_no) % 3 != 0 else Vector2.ZERO
	vel[i] = wander_dir[i] * spd[i] * 0.45


## 网格碰撞移动：先 x 后 y 分轴滑动（探针 = 前进方向半径点）
func _try_move(i: int, d: float) -> void:
	var p := pos[i]
	var step := (vel[i] + knock[i] + lunge[i]) * d
	var r := radius[i] * 0.7
	if step.x != 0.0:
		var nx := p.x + step.x
		var probe := Vector2(nx + signf(step.x) * r, p.y)
		if dungeon.is_floor(Vector2i((probe / float(TILE)).floor())):
			p.x = nx
	if step.y != 0.0:
		var ny := p.y + step.y
		var probe2 := Vector2(p.x, ny + signf(step.y) * r)
		if dungeon.is_floor(Vector2i((probe2 / float(TILE)).floor())):
			p.y = ny
	pos[i] = p
	var v := vel[i]
	if v.length_squared() > 4.0:
		if absf(v.x) > absf(v.y):
			facing[i] = 2 if v.x > 0 else 1
		else:
			facing[i] = 0 if v.y > 0 else 3
		anim_t[i] += d
	knock[i] = knock[i].move_toward(Vector2.ZERO, 1000.0 * d)
	lunge[i] = lunge[i].move_toward(Vector2.ZERO, 1300.0 * d)


func _build_hash() -> void:
	for k in _used_keys:
		_hash[k].clear()
	_used_keys.clear()
	for i in count:
		if hp[i] <= 0:
			continue
		var k := int(pos[i].x / HASH_CELL) * 100000 + int(pos[i].y / HASH_CELL)
		var arr = _hash.get(k)
		if arr == null:
			arr = []
			_hash[k] = arr
			_used_keys.append(k)
		arr.append(i)


## 主线程：执行线程阶段攒下的事件（咬人 / 射击 / 特殊技）
func _drain_events() -> void:
	for ev in _chunk_events:
		for e in ev:
			match int(e[0]):
				EV_BITE:
					var i: int = e[1]
					if not is_alive(i):
						break
					var t_i: int = int(e[2])
					if t_i >= targets.size() or target_alive[t_i] == 0:
						break
					var tp: Vector2 = targets[t_i]
					var to_t := tp - pos[i]
					if to_t.length() < atk_range[i] + 16.0:
						if t_i == 0:
							if world.player != null:
								world.player.take_damage(atk[i], pos[i])
						else:
							var f = main.party.friend_by_slot(t_i - 1)
							if f != null and not f.dead:
								f.take_damage(atk[i], pos[i])
						world.spawn_slash(pos[i] + to_t.normalized() * 14.0, to_t.angle(), Color(1, 0.45, 0.38))
				EV_SHOOT:
					var i2: int = e[1]
					if not is_alive(i2):
						break
					var dir: Vector2 = e[2]
					world.spawn_projectile(pos[i2] + dir * 12.0, dir, float(ArpgBalance.ENEMIES["fox"]["proj_spd"]),
						atk[i2], "enemy", Color(1.0, 0.45, 0.75), "orb")
				EV_SPECIAL:
					var i3: int = e[1]
					if not is_alive(i3):
						break
					for k in 10:
						var ang := TAU * k / 10.0 + float(k % 3) * 0.2
						world.spawn_projectile(pos[i3], Vector2.RIGHT.rotated(ang), 215.0,
							atk[i3] - 4, "enemy", Color(1.0, 0.45, 0.2), "bullet")
					world.spawn_nova(pos[i3], Color(1.0, 0.4, 0.2))
					main.add_shake(0.28)
					main.rumble(0.25, 0.5, 0.2)


func _handle_deaths() -> void:
	for i in count:
		if alive[i] == 1 and hp[i] <= 0:
			alive[i] = 0
			main.on_mob_dead(i)
	# 紧凑化（swap 移除，保持数组稠密）
	var j := 0
	for i in count:
		if alive[i] == 1:
			if j != i:
				_copy_slot(i, j)
			j += 1
	count = j


func _copy_slot(src: int, dst: int) -> void:
	pos[dst] = pos[src]
	vel[dst] = vel[src]
	knock[dst] = knock[src]
	lunge[dst] = lunge[src]
	hp[dst] = hp[src]
	max_hp[dst] = max_hp[src]
	atk[dst] = atk[src]
	spd[dst] = spd[src]
	xp[dst] = xp[src]
	radius[dst] = radius[src]
	atk_range[dst] = atk_range[src]
	tpl[dst] = tpl[src]
	elite[dst] = elite[src]
	boss[dst] = boss[src]
	aggro[dst] = aggro[src]
	alive[dst] = 1
	state[dst] = state[src]
	windup_t[dst] = windup_t[src]
	cool_t[dst] = cool_t[src]
	special_t[dst] = special_t[src]
	flash_t[dst] = flash_t[src]
	facing[dst] = facing[src]
	anim_t[dst] = anim_t[src]
	wander_dir[dst] = wander_dir[src]
	wander_t[dst] = wander_t[src]
	enraged[dst] = enraged[src]


## 平衡热重载：模板表按名重建；存活怪保持血量比例并刷新派生属性
func apply_balance() -> void:
	var old_names: Array = []
	var old_ratio: Array = []
	for i in count:
		old_names.append(tpl_name[tpl[i]])
		old_ratio.append(float(hp[i]) / maxf(1.0, float(max_hp[i])))
	tpl_name.clear()
	tpl_hp.clear()
	tpl_atk.clear()
	tpl_spd.clear()
	tpl_xp.clear()
	tpl_radius.clear()
	tpl_atk_range.clear()
	tpl_keep.clear()
	tpl_windup.clear()
	tpl_cool.clear()
	tpl_behavior.clear()
	tpl_block.clear()
	tpl_scale.clear()
	for tpl_id in ArpgBalance.ENEMIES:
		_push_tpl(tpl_id, ArpgBalance.ENEMIES[tpl_id], false)
	_push_tpl("boss", ArpgBalance.BOSS, true)
	tpl_count = tpl_name.size()
	_sheet = ArpgTex.tex(ArpgData.MONSTER)
	for i in count:
		var ni := tpl_name.find(old_names[i])
		if ni < 0:
			ni = 0
		tpl[i] = ni
		var mult := 1.3 if elite[i] == 1 else 1.0
		var old_max := max_hp[i]
		max_hp[i] = int(tpl_hp[ni] * mult)
		hp[i] = clampi(int(round(old_ratio[i] * max_hp[i])), 1, max_hp[i]) if old_max > 0 else max_hp[i]
		atk[i] = int(tpl_atk[ni] * mult)
		spd[i] = tpl_spd[ni]
		radius[i] = tpl_radius[ni]
		atk_range[i] = tpl_atk_range[ni]


# ———————— 单批次渲染 ————————

func _draw() -> void:
	if dungeon == null or count == 0:
		return
	var inv := get_viewport().get_canvas_transform().affine_inverse()
	var view := inv * Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var view_grown := view.grow(72.0)
	_vis.clear()
	for i in count:
		var p := pos[i]
		if p.x < view_grown.position.x or p.y < view_grown.position.y \
				or p.x > view_grown.end.x or p.y > view_grown.end.y:
			continue
		_vis.append([p.y, 0, i])
	# 玩家也画进同一批（由渲染器按 y 排序，省掉节点 y-sort）
	var pl = world.player
	if pl != null and is_instance_valid(pl) and view_grown.has_point(pl.position):
		_vis.append([pl.position.y, 1, -1])
	_vis.sort_custom(func(a, b): return a[0] < b[0])
	# 影子先铺一层
	for e in _vis:
		if e[1] == 0:
			var i: int = e[2]
			var s := tpl_scale[tpl[i]]
			draw_circle(pos[i] + Vector2(0, 13.0 * s), 8.0 * s, Color(0, 0, 0, 0.24))
		else:
			draw_circle(pl.position + Vector2(0, 13.0), 9.0, Color(0, 0, 0, 0.26))
	# 身体
	for e in _vis:
		if e[1] == 1:
			_draw_player()
			continue
		var i: int = e[2]
		var ti := tpl[i]
		var s := tpl_scale[ti]
		var f_seq := [0, 1, 2, 1]
		var f: int = f_seq[int(anim_t[i] / 0.13) % 4]
		var blk: Vector2 = tpl_block[ti]
		var col := Color.WHITE
		if flash_t[i] > 0.0:
			col = Color(1, 0.5, 0.45)
		elif state[i] == 2:
			col = Color(1, 0.55, 0.5) if elite[i] == 0 else Color(1.0, 0.85, 0.45)
		elif elite[i] == 1:
			col = ArpgBalance.ELITE_TINT
		var rect := Rect2(pos[i] + Vector2(-24.0, -29.0) * s, Vector2(48, 48) * s)
		draw_texture_rect_region(_sheet, rect,
			Rect2(blk.x + f * 48, blk.y + facing[i] * 48, 48, 48), col)
	# 血条（受伤且靠近玩家的，封顶 60 条）
	var drawn := 0
	if pl != null and is_instance_valid(pl):
		for e in _vis:
			if e[1] != 0 or drawn >= 60:
				continue
			var i: int = e[2]
			if hp[i] >= max_hp[i] or pos[i].distance_to(pl.position) > 600.0:
				continue
			var bw := 26.0 * tpl_scale[tpl[i]]
			var px: Vector2 = pos[i]
			var ratio := float(hp[i]) / max_hp[i]
			draw_rect(Rect2(px.x - bw / 2, px.y - 30.0 * tpl_scale[tpl[i]], bw, 4), Color(0.05, 0.05, 0.09, 0.9))
			draw_rect(Rect2(px.x - bw / 2, px.y - 30.0 * tpl_scale[tpl[i]], bw * ratio, 4), Color(0.85, 0.3, 0.25))
			drawn += 1


func _draw_player() -> void:
	var pl = world.player
	if pl == null or not is_instance_valid(pl):
		return
	var sp: Sprite2D = pl.sprite
	var s: Vector2 = sp.scale
	var rect := Rect2(
		pl.position + sp.offset * s - Vector2(24, 24) * s,
		Vector2(48, 48) * s)
	draw_texture_rect_region(sp.texture, rect, sp.region_rect, sp.modulate)
