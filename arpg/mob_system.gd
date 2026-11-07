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
var tpl_pounce := PackedByteArray()        # 1 = 会扑击（狼类：追击带内蓄力突进）
var tpl_pounce_range := []                 # [近限, 远限]（格内距离 px）
var tpl_pounce_speed := PackedFloat32Array()
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
var affix := PackedByteArray()          # 0=无 1=迅捷 2=坚韧 3=嗜血 4=临终爆炸（精英专属词缀）
var affix_seen := PackedByteArray()     # 遭遇播报去重（LOS 首次发现时弹词缀名）
const AFFIX_IDS := {"swift": 1, "tough": 2, "vampiric": 3, "burst": 4, "frost": 5, "brittle": 6, "burning": 7}
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
# —— Boss 招式池（威胁值驱动，threat_system 供值）——
var hold_t := PackedFloat32Array()         # 站定计时（观察招 / 弹反硬直共用）
var pool_t := PackedFloat32Array()         # 招式池闸门（nova 保底节奏之外的插招冷却）
var ult_streak := PackedInt32Array()       # 连续大招数（charge/slam；达上限强制恢复招）
# —— 局部避让 / 防卡死（AI 优化批）——
var sep := PackedVector2Array()            # 分离推力（每拍重建，进 _try_move 步长）
var stuck_t := PackedFloat32Array()        # 贴墙/被堵累计时长
var nudge_t := PackedFloat32Array()        # 切向脱困剩余时长
var nudge_dir := PackedVector2Array()      # 脱困方向

# —— 流程场 / AI 参数（balance.json「ai」段热调）——
var flow := ArpgFlowField.new()
var _flow_cell := Vector2i(-99, -99)
var _flow_t := 0.0
var _ai_sep_pad := 6.0
var _ai_sep_strength := 3.0
var _ai_sep_max := 6
var _ai_stuck_after := 0.8
var _ai_nudge_time := 0.45
var _ai_nudge_speed := 0.6
var _ai_arc_blend := 0.22
var _ai_strafe := 0.5
# —— 威胁值快照（主线程每帧拷一次，worker 只读快照——线程纪律）——
var _threat_snap := 25.0
var _tempo := 1.0                  # 凶暴档攻击节奏（windup ×tempo）
var _enrage_at := 0.4              # 狂暴血线（boss.enrage_at）
# —— 质量指标（压测/调试面板）——
var stuck_ratio := 0.0
var stack_ratio := 0.0
var _metrics_t := 1.0
var _metrics_print_t := 5.0

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
const EV_AFFIX := 3
const EV_ENRAGE := 4
const EV_BOSS_MOVE := 5    # Boss 招式池/扑击的视觉与伤害（payload: [EV, i, 招式名]）


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
	affix.resize(cap)
	affix_seen.resize(cap)
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
	sep.resize(cap)
	stuck_t.resize(cap)
	nudge_t.resize(cap)
	nudge_dir.resize(cap)
	hold_t.resize(cap)
	pool_t.resize(cap)
	ult_streak.resize(cap)
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
	tpl_pounce.append(1 if bool(t.get("pounce", false)) else 0)
	tpl_pounce_range.append(PackedInt32Array([
		int(t.get("pounce_range", [90, 280])[0]), int(t.get("pounce_range", [90, 280])[1])]))
	tpl_pounce_speed.append(float(t.get("pounce_speed", 620.0)))


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
	affix[i] = 0
	affix_seen[i] = 0
	boss[i] = 1 if boss_f else 0
	# 精英词缀（balance.affixes 数据驱动）：roll 命中后一次性把倍率算进面板，热路径零分支
	if elite_f and not boss_f:
		var aff_tbl: Dictionary = ArpgBalance.data.get("affixes", {})
		if not aff_tbl.is_empty() and randf() < float(ArpgBalance.data.get("affix_chance", 0.7)):
			var keys := aff_tbl.keys()
			var akey: String = str(keys[randi() % keys.size()])
			affix[i] = int(AFFIX_IDS.get(akey, 0))
			var adef: Dictionary = aff_tbl[akey]
			if float(adef.get("hp_mult", 1.0)) != 1.0:
				max_hp[i] = int(max_hp[i] * float(adef["hp_mult"]))
				hp[i] = max_hp[i]
			if float(adef.get("spd_mult", 1.0)) != 1.0:
				spd[i] *= float(adef["spd_mult"])
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
	sep[i] = Vector2.ZERO
	stuck_t[i] = 0.0
	nudge_t[i] = 0.0
	nudge_dir[i] = Vector2.ZERO
	hold_t[i] = 0.0
	pool_t[i] = 1.5       # 招式池闸门：开局错开 nova 保底（3.0s），插招稍后入场
	ult_streak[i] = 0
	return i


func is_alive(i: int) -> bool:
	return i >= 0 and i < count and alive[i] == 1 and hp[i] > 0


## 弹反硬直：击退并短暂压制最近敌人（hold_t 站定，Boss 同样吃硬直）。
## 主线程调用（player._resolve_parry）；找不到范围内敌人返回 false。
## 线性扫而非空间哈希：弹反发生在帧中段，本帧新生的怪（Boss 召唤等）不在帧首哈希里。
func stagger_nearest(from_pos: Vector2, dur: float, knock_amt: float) -> bool:
	var best := -1
	var bd := 90.0 * 90.0
	for j in count:
		if alive[j] == 0 or hp[j] <= 0:
			continue
		var dsp := pos[j].distance_squared_to(from_pos)
		if dsp < bd:
			bd = dsp
			best = j
	if best < 0:
		return false
	hold_t[best] = maxf(hold_t[best], dur)
	knock[best] += (pos[best] - from_pos).normalized() * knock_amt
	flash_t[best] = 0.15
	aggro[best] = 1
	return true


## 词缀中文名（affixes 表 key 顺序约定见 AFFIX_IDS）；无词缀返回 ""
func affix_name(i: int) -> String:
	if i < 0 or i >= count or affix[i] == 0:
		return ""
	var want := int(affix[i])
	for k in AFFIX_IDS:
		if int(AFFIX_IDS[k]) == want:
			var nm: String = str(ArpgBalance.data.get("affixes", {}).get(str(k), {}).get("name", str(k)))
			return nm
	return ""


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


## 占几格：由碰撞直径向上取整。不是手填属性，是派生量 ——
## 用于寻路时膨胀障碍，以及生成器校验走廊宽度（见 docs/网格与图块方案.md）。
func footprint_of(i: int) -> int:
	if i < 0 or i >= count:
		return 1
	return maxi(1, int(ceil(radius[i] * 2.0 / float(ArpgData.GRID))))


## 本帧所有存活实体里的最大 footprint（生成器/调试面板用）
func max_footprint() -> int:
	var m := 1
	for i in count:
		if hp[i] > 0:
			m = maxi(m, footprint_of(i))
	return m


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
	# 威胁值快照（threat_system 供值；worker 只读 _threat_snap/_tempo，不碰 main.threat）
	if main.threat != null:
		_threat_snap = main.threat.value
		_tempo = 1.0
		if bool(ArpgBalance.data.get("threat", {}).get("enabled", true)) and main.threat.band() == 2:
			_tempo = float(ArpgBalance.data.get("threat", {}).get("tempo_aggressive", 0.85))
	# 分离视野：相机可见矩形（主线程算一次，worker 只读）
	var inv := get_viewport().get_canvas_transform().affine_inverse()
	_sep_view = inv * Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	_sep_view = _sep_view.grow(SEP_VIEW_PAD)
	# 分离/LOS 是「品质增强」：只在正常规模的战斗（<500 怪）里开启。
	# 万敌压测（1 万）属于性能极限场景，自动降级为原行为——帧率优先，且观感无差。
	_sep_quality = count < 500
	# 正常战斗规模（<500 只）：全体参与分离（开销 <0.3ms），无需视野裁剪
	_sep_all = _sep_quality
	if _sep_quality and not _sep_all:
		_pick_sep_targets()
	# 空间哈希（每帧主线程重建，供攻击/弹幕查询 + 分离避让只读）
	_build_hash()
	_update_flow(delta)
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
	_metrics_t -= delta
	if _metrics_t <= 0.0:
		_metrics_t = 1.0
		_sample_metrics()
		if main._stress_n > 0:
			_metrics_print_t -= 1.0
			if _metrics_print_t <= 0.0:
				_metrics_print_t = 5.0
				print("[AI] 卡住率 %.0f%% · 堆叠率 %.0f%% · sim %.2fms" % [
					stuck_ratio * 100.0, stack_ratio * 100.0, sim_ms])
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
	_enrage_at = float(ArpgBalance.data.get("boss", {}).get("enrage_at", 0.4))
	# AI 参数（balance.json「ai」段，保存即热重载）
	var ai_cfg: Dictionary = ArpgBalance.data.get("ai", {})
	var sep_cfg: Dictionary = ai_cfg.get("separation", {})
	var stuck_cfg: Dictionary = ai_cfg.get("stuck", {})
	_ai_sep_pad = float(sep_cfg.get("radius_pad", 6.0))
	_ai_sep_strength = float(sep_cfg.get("strength", 3.0))
	_ai_sep_max = int(sep_cfg.get("max_neighbors", 6))
	_ai_stuck_after = float(stuck_cfg.get("after", 0.8))
	_ai_nudge_time = float(stuck_cfg.get("nudge_time", 0.45))
	_ai_nudge_speed = float(stuck_cfg.get("nudge_speed", 0.6))
	_ai_arc_blend = float(ai_cfg.get("arc_blend", 0.22))
	_ai_strafe = float(ai_cfg.get("strafe_ratio", 0.5))
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


## 包抄方位槽偏移（按怪下标恒定，结果缓存在 _slot_cache）
var _slot_cache := {}
var _slot_open_cache := {}
var _los_cache := {}
var _sep_view := Rect2()   # 相机视野（分离只在屏内生效）
var _sep_quality := true   # 品质模式：怪数 <500 时开启分离/LOS/包抄
var _sep_all := true       # 品质模式下全体参与（规模可控，无需视野裁剪）
var _sep_set := {}         # 本帧参与分离的怪下标（主线程按距离选，worker 只读）
const SEP_BUDGET := 48     # 每帧最多算 48 只（≈0.6ms），万敌与小队场景都够用
const SEP_VIEW_PAD := 48.0


## 主线程：屏内怪按「屏幕网格分桶」抽样选 SEP_BUDGET 只做分离。
## 不用排序（1 万只排序本身就要 5ms+）：每格只取一只，保证覆盖均匀、不扎堆。
func _pick_sep_targets() -> void:
	_sep_set.clear()
	if count == 0:
		return
	var vp := _sep_view
	var buckets := {}     # 屏幕 64px 格 → 第一个命中怪
	for i in count:
		if hp[i] <= 0:
			continue
		var p := pos[i]
		if p.x < vp.position.x or p.y < vp.position.y or p.x > vp.end.x or p.y > vp.end.y:
			continue
		var key := (int(p.x / 64.0) * 100000) + int(p.y / 64.0)
		if not buckets.has(key):
			buckets[key] = i
			if buckets.size() >= SEP_BUDGET:
				break
	for k in buckets:
		_sep_set[buckets[k]] = true

func _slot_offset(i: int) -> Vector2:
	var v = _slot_cache.get(i)
	if v == null:
		var slot := float(i % 8) * (TAU / 8.0) + float((i / 8) % 2) * (TAU / 16.0)
		v = Vector2.RIGHT.rotated(slot) * 26.0
		_slot_cache[i] = v
	return v


## 方位槽落点是否可走：按「目标格 + 槽」缓存（目标跨格才重算）
func _slot_open(i: int, tpos: Vector2) -> bool:
	var key := i * 1000003 + int(tpos.x) * 7919 + int(tpos.y)
	var v = _slot_open_cache.get(key)
	if v == null:
		var cell := Vector2i(((tpos + _slot_offset(i)) / float(TILE)).floor())
		v = dungeon.is_floor(cell)
		if _slot_open_cache.size() > 20000:
			_slot_open_cache.clear()
		_slot_open_cache[key] = v
	return v


## 流程场维护：锚点 = 当前主控单位（玩家/被切队友）；跨格或到时重建（<2ms）
func _update_flow(delta: float) -> void:
	_flow_t -= delta
	# 大图（压测斗兽场 170×120=20400 格）BFS 要 70ms+，远超一帧预算。
	# 斗兽场本身是开阔地无墙可绕，流程场毫无收益 → 直接跳过（怪走直线）。
	if dungeon.w * dungeon.h > 6000:
		flow.valid = false
		return
	var anchor := Vector2(-9999, -9999)
	var cu = main.possession.current_unit if main.possession != null else null
	if cu != null and is_instance_valid(cu) and not cu.dead:
		anchor = cu.position
	elif world.player != null and is_instance_valid(world.player) and not world.player.dead:
		anchor = world.player.position
	if anchor.x < -9000:
		flow.valid = false
		return
	var acell := Vector2i((anchor / float(TILE)).floor())
	if not dungeon.is_floor(acell):
		flow.valid = false
		return
	# 只按时间节流重建（0.25s 一次 ≈ 4Hz）。锚点每帧都在动，
	# 若「跨格即重建」会在移动中每帧触发 5ms 重建，直接拖垮帧率。
	if _flow_t <= 0.0:
		_flow_cell = acell
		_flow_t = _flow_recalc_interval()
		flow.build(dungeon, acell)


func _flow_recalc_interval() -> float:
	return float(ArpgBalance.data.get("ai", {}).get("flow_recalc_interval", 0.25))


## 网格直线视野（DDA 12px 采样）：aggro 获取时一次性判定，不进热循环
func _los_clear(a: Vector2, b: Vector2) -> bool:
	var dv := b - a
	var steps := int(dv.length() / 12.0) + 1
	var step := dv / float(steps)
	var p := a
	for s in steps:
		p += step
		if not dungeon.is_floor(Vector2i((p / float(TILE)).floor())):
			return false
	return true


## 追击方向：直线与流程场同向（开阔地）→ 直线（零开销 + 天然直线捷径）；
## 明显分歧（说明隔着墙）→ 沿流程场绕行走廊。场缺失/不可达回退直线。
func _chase_dir(i: int, to_p: Vector2) -> Vector2:
	var dl := to_p.length()
	var direct := to_p / maxf(dl, 0.01)
	if not flow.valid:
		return direct
	# 队友目标离主控太远时流程场（建自主控）不适用 → 直线
	if tgt[i] != 0 and targets[tgt[i]].distance_to(targets[0]) > 500.0:
		return direct
	var fd := flow.dir_at(pos[i], TILE)
	if fd == Vector2.ZERO:
		return direct
	# 点积代替 angle_to（免三角函数）：dot > cos(0.45rad≈0.9) 视为同向 → 走直线
	return direct if fd.dot(direct) > 0.9 else fd


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
		# 分离避让：全局预算 + 轮转（不是按视野，压测场屏内可能有上千只）。
		# 实测 1 万只全量 = 1.2s/次（GDScript 字典 + Vector2 分配是主要开销），
		# 因此每帧只处理 _sep_budget 只屏内怪，用游标轮转保证长期覆盖所有怪。
		if _sep_quality and (_sep_all or _sep_set.has(i)):
			_accumulate_separation(i)
		# 弹反硬直 / Boss 观察招：站定（全行为通用；硬直期间 windup/闸门全部冻结）
		if hold_t[i] > 0.0:
			hold_t[i] -= d
			vel[i] = Vector2.ZERO
			_try_move(i, d)
			continue
		if not aggro[i]:
			# LOS 仇恨：不隔墙索敌。DDA 只在这个怪「没 aggro 且进了半径」时才需要，
			# 且结果按「怪所在格 + 目标格」缓存（任一跨格才重算）→ 静止时零成本
			var d2 := dist * dist
			# 远处怪（LOD>1）不做 LOS：它们本来就不在玩家视野里，隔墙索敌与否不可见
			if d2 < _aggro * _aggro and target_alive[tgt[i]] == 1 and (not _sep_quality or lod == 1):
				# 只按「怪所在格 + 目标格」做键（同格怪共享结果 → 命中率极高）
				var los_key := int(p.x / 64.0) * 7919 + int(p.y / 64.0) \
					+ int(targets[tgt[i]].x / 64.0) * 104729 + int(targets[tgt[i]].y / 64.0) * 1299709
				var seen = _los_cache.get(los_key)
				if seen == null:
					seen = _los_clear(p, targets[tgt[i]])
					if _los_cache.size() > 60000:
						_los_cache.clear()
					_los_cache[los_key] = seen
				if seen:
					aggro[i] = 1
					# 精英词缀遭遇播报：LOS 首次发现时头顶弹词缀名（去重）
					if affix[i] != 0 and affix_seen[i] == 0:
						affix_seen[i] = 1
						ev.append([EV_AFFIX, i])
				else:
					_wander(i, d)
					_try_move(i, d)
					continue
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
			pool_t[i] = maxf(0.0, pool_t[i] - d)
			if enraged[i] == 0 and hp[i] < max_hp[i] * _enrage_at:
				enraged[i] = 1
				spd[i] = tpl_spd[tpl[i]] * 1.35
				# 二阶段开场：横幅警告 + 召唤护主小鬼（一次性，走主线程事件队列）
				ev.append([EV_ENRAGE, i])
			if special_t[i] <= 0.0:
				special_t[i] = 2.6 if enraged[i] == 1 else 3.4
				ev.append([EV_SPECIAL, i])
			if pool_t[i] <= 0.0:
				_boss_pick_move(i, to_p, dist, ev)
			_melee_move(i, to_p, dist, ev)
		elif beh == 1:
			_ranged_move(i, to_p, dist)
		else:
			_melee_move(i, to_p, dist, ev)
		_try_move(i, d)


func _melee_move(i: int, to_p: Vector2, dist: float, ev: Array) -> void:
	# 扑击（狼/骑士/imp 等 melee 怪通用）：追击带内且冷却好 → 蓄势突进（贴脸后走正常咬人判定）
	var ti := tpl[i]
	if tpl_pounce[ti] == 1 and special_t[i] <= 0.0 and dist > atk_range[i]:
		var pr: PackedInt32Array = tpl_pounce_range[ti]
		if dist >= pr[0] and dist <= pr[1]:
			# cd 从该怪自身模板读（此前写死 wolf 的，骑士/imp 配了也会用错值）
			special_t[i] = float(ArpgBalance.ENEMIES.get(str(tpl_name[ti]), {}).get("pounce_cd", 3.5))
			lunge[i] = to_p.normalized() * tpl_pounce_speed[ti]
			# 线程纪律：popup/音效走事件（压测 >300 怪时 _sim_range 会进 worker 线程）
			ev.append([EV_BOSS_MOVE, i, "pounce"])
	if dist > atk_range[i]:
		# 包抄弧：近距时每怪认领一个方位槽绕到侧翼，怪群成弧围攻而不是叠柱
		# （方位槽每怪恒定 → 几何量按 i 预算缓存，热循环里不再 is_floor/rotate）
		var goal := to_p
		if _sep_quality and dist < atk_range[i] * 3.0:
			var slot_off := _slot_offset(i)
			var approach: Vector2 = targets[tgt[i]] + slot_off
			if _slot_open(i, targets[tgt[i]]):
				var to_a := approach - pos[i]
				if to_a.length_squared() > 64.0:
					goal = to_a.lerp(to_p, _ai_arc_blend)
		vel[i] = _chase_dir(i, goal) * spd[i]
	elif cool_t[i] <= 0.0:
		state[i] = 2
		windup_t[i] = tpl_windup[tpl[i]] * _tempo   # 凶暴档节奏：起手更快（threat.tempo_aggressive）
		vel[i] = Vector2.ZERO
	else:
		vel[i] = Vector2.ZERO


## Boss 招式池（威胁值驱动）：nova 是保底节奏（special_t 闸门不变），本池在保底之间
## 按威胁权重插招——蓄力突进/范围震地/后撤/观察。worker 上下文安全：只写 SoA + 发事件，
## 视觉/音效/伤害全部由主线程 _drain_events 的 EV_BOSS_MOVE 分支执行（仿 EV_ENRAGE 纪律）。
## 权重来自 threat_system.move_weights 的同款插值（低/高威胁两列 → 按威胁值线性插值）。
func _boss_pick_move(i: int, to_p: Vector2, dist: float, ev: Array) -> void:
	var tcfg: Dictionary = ArpgBalance.data.get("threat", {})
	if not bool(tcfg.get("enabled", true)):
		return
	var moves: Dictionary = tcfg.get("moves", {})
	var t := clampf(_threat_snap, 0.0, 100.0) / 100.0
	var w := {}
	for mid in moves:
		var mv: Dictionary = moves[mid]
		w[mid] = maxf(0.0, lerpf(float(mv.get("low", 0.0)), float(mv.get("high", 0.0)), t))
	# 可用性过滤：突进要距离带内（贴脸/太远都不突）
	if dist < float(moves.get("charge", {}).get("range_min", 110.0)) \
			or dist > float(moves.get("charge", {}).get("range_max", 340.0)):
		w["charge"] = 0.0
	# 连续大招上限：charge/slam 算大招，连续 ult_cap 次后强制恢复招（观察/后撤）
	var cap := int(tcfg.get("ult_cap", 2))
	if ult_streak[i] >= cap:
		w["charge"] = 0.0
		w["slam"] = 0.0
	var total := 0.0
	for mid in w:
		total += w[mid]
	if total <= 0.0:
		return
	# 确定性伪随机（worker 禁 randf，黄金角散列混入 frame_no 保证逐次变化）
	var roll := ((i * 2654435761 + frame_no * 40503) & 0xFFFF) / 65536.0 * total
	var pick := ""
	for mid in w:
		roll -= w[mid]
		if roll <= 0.0:
			pick = mid
			break
	if pick == "":
		return
	var pmv: Dictionary = moves[pick]
	match pick:
		"charge":
			lunge[i] = to_p.normalized() * float(pmv.get("speed", 620.0))
			pool_t[i] = float(pmv.get("cd", 6.0))
			ult_streak[i] += 1
			ev.append([EV_BOSS_MOVE, i, "charge"])
		"slam":
			pool_t[i] = float(pmv.get("cd", 7.5))
			ult_streak[i] += 1
			ev.append([EV_BOSS_MOVE, i, "slam"])
		"backstep":
			lunge[i] = -to_p.normalized() * float(pmv.get("speed", 560.0))
			pool_t[i] = float(pmv.get("cd", 2.5))
			ult_streak[i] = 0
			ev.append([EV_BOSS_MOVE, i, "backstep"])
		"observe":
			hold_t[i] = float(pmv.get("dur", 1.1))
			pool_t[i] = float(pmv.get("dur", 1.1))
			ult_streak[i] = 0
			ev.append([EV_BOSS_MOVE, i, "observe"])


func _ranged_move(i: int, to_p: Vector2, dist: float) -> void:
	var keep := tpl_keep[tpl[i]]
	if cool_t[i] <= 0.0 and dist < tpl_atk_range[tpl[i]]:
		state[i] = 2
		windup_t[i] = tpl_windup[tpl[i]]
		vel[i] = Vector2.ZERO
	elif dist > keep + 36.0:
		vel[i] = _chase_dir(i, to_p) * spd[i]
	elif dist < keep - 36.0:
		# 后退混入横向分量：贴墙被挡时也能沿墙滑出死区，不再原地抖动
		var back := -to_p / maxf(dist, 0.01)
		var side := back.orthogonal() * (1.0 if i % 2 == 0 else -1.0)
		vel[i] = (back + side * _ai_strafe).normalized() * spd[i]
	else:
		# 死区慢速横移（风筝走位感），比站桩自然
		var fwd := to_p / maxf(dist, 0.01)
		vel[i] = fwd.orthogonal() * (1.0 if i % 2 == 0 else -1.0) * spd[i] * _ai_strafe


func _wander(i: int, d: float) -> void:
	wander_t[i] -= d
	if wander_t[i] <= 0.0:
		wander_t[i] = 2.0 + float(i % 7) * 0.4
		# 确定性伪随机（线程内禁用全局 randf）：黄金角散列
		var ang := (float(i % 512) / 512.0 + float(wander_t[i]) * 0.37) * TAU
		wander_dir[i] = Vector2.RIGHT.rotated(ang) if (i + frame_no) % 3 != 0 else Vector2.ZERO
	vel[i] = wander_dir[i] * spd[i] * 0.45


## 网格碰撞移动：先 x 后 y 分轴滑动（探针 = 前进方向半径点）
## 附带：切向脱困覆盖 / 分离力并入步长 / 卡死计量（贴墙硬推的兜底）
func _try_move(i: int, d: float) -> void:
	var p := pos[i]
	# 切向脱困：贴墙/堵门累计超阈值 → 沿切向强制走一小段（非蓄力态才覆盖）
	if nudge_t[i] > 0.0 and state[i] != 2:
		# 脱困期间不再叠加分离（否则两股力互相抵消，反而卡死）
		nudge_t[i] -= d
		vel[i] = nudge_dir[i] * spd[i] * _ai_nudge_speed
	var step := (vel[i] + knock[i] + lunge[i] + sep[i]) * d
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
	# 卡死计量：想走而几乎没挪（期望 vs 实际）→ 累计；正常移动则回退
	var want := vel[i].length()
	if aggro[i] == 1 and state[i] != 2 and want > spd[i] * 0.35:
		var moved := (pos[i] - p).length()
		if moved < maxf(want, 1.0) * d * 0.25:
			stuck_t[i] += d
			if stuck_t[i] > _ai_stuck_after:
				stuck_t[i] = 0.0
				nudge_t[i] = _ai_nudge_time
				var side := vel[i].orthogonal().normalized()
				nudge_dir[i] = side * (1.0 if (i + frame_no) % 2 == 0 else -1.0)
		else:
			stuck_t[i] = maxf(0.0, stuck_t[i] - d * 2.0)
	else:
		stuck_t[i] = maxf(0.0, stuck_t[i] - d * 2.0)
	var v := vel[i]
	if v.length_squared() > 4.0:
		if absf(v.x) > absf(v.y):
			facing[i] = 2 if v.x > 0 else 1
		else:
			facing[i] = 0 if v.y > 0 else 3
		anim_t[i] += d
	knock[i] = knock[i].move_toward(Vector2.ZERO, 1000.0 * d)
	lunge[i] = lunge[i].move_toward(Vector2.ZERO, 1300.0 * d)
	sep[i] = Vector2.ZERO


## 分离避让（worker 安全：只读空间哈希）：重叠邻居互相推开，上限控预算。
## 用平方距离弹簧（免 sqrt，万敌热循环的关键）：
##   push = dvec * (1 - ds/want²)  —— 方向对、强度随重叠加深而增大
func _accumulate_separation(i: int) -> void:
	var p := pos[i]
	var ri := radius[i]
	var cx := int(p.x / HASH_CELL)
	var cy := int(p.y / HASH_CELL)
	var acc := Vector2.ZERO
	var n := 0
	for gx in range(cx - 1, cx + 2):
		var arrx = _hash.get(gx * 100000 + cy)
		if arrx != null:
			for j in arrx:
				if j == i:
					continue
				var dvec: Vector2 = p - pos[j]
				var ds := dvec.length_squared()
				var want := ri + radius[j] + _ai_sep_pad
				var w2 := want * want
				if ds >= w2:
					continue
				if ds < 0.01:
					# 完全重叠：零向量没有方向 → 用「i 相对 j 的序号差」定角度，
					# 保证 i、j 两方取到的是相反方向（互相背离），不会同向漂移
					# 方向取「从 i 指向 j」的序号差符号：i<j 时 +θ，i>j 时 −θ → 必然背离
					var sign_ij := 1.0 if j > i else -1.0
					var base_ang := float(abs(j - i) % 16) * (TAU / 16.0)
					acc += Vector2.RIGHT.rotated(base_ang) * sign_ij
				else:
					# 归一化方向 × 重叠程度（0~1）：重叠越深推力越大，与距离无关地保持量纲
					acc += dvec / sqrt(ds) * (1.0 - ds / w2)
				n += 1
				if n >= _ai_sep_max:
					break
		if n >= _ai_sep_max:
			break
	if n < _ai_sep_max:
		for gy in [cy - 1, cy + 1]:
			for gx in range(cx - 1, cx + 2):
				var arr = _hash.get(gx * 100000 + gy)
				if arr == null:
					continue
				for j in arr:
					if j == i:
						continue
					var dvec2: Vector2 = p - pos[j]
					var ds2 := dvec2.length_squared()
					var want2 := ri + radius[j] + _ai_sep_pad
					var w22 := want2 * want2
					if ds2 >= w22:
						continue
					if ds2 < 0.01:
						var sign_ij2 := 1.0 if j > i else -1.0
						var base_ang2 := float(abs(j - i) % 16) * (TAU / 16.0)
						acc += Vector2.RIGHT.rotated(base_ang2) * sign_ij2
					else:
						acc += dvec2 / sqrt(ds2) * (1.0 - ds2 / w22)
					n += 1
					if n >= _ai_sep_max:
						break
				if n >= _ai_sep_max:
					break
			if n >= _ai_sep_max:
				break
	# 分离按「速度」量纲给（约为怪速的 1.2 倍上限），保证重叠时真的推得开；
	# strength 是 balance 里的可调倍率
	sep[i] = (acc * _ai_sep_strength).limit_length(spd[i] * 2.5)


## 质量指标（1s 采样一次）：卡住率 = 想走但被堵的 aggro 怪占比；堆叠率 = 半径内挤压邻居的占比
func _sample_metrics() -> void:
	if count == 0:
		stuck_ratio = 0.0
		stack_ratio = 0.0
		return
	var stuck_n := 0
	var stack_n := 0
	var aggro_n := 0
	var sampled := 0
	# 只抽 120 只（GDScript 里 500 只 × 9 格哈希实测 72ms，会明显卡顿）
	var stride := maxi(1, count / 120)
	var r0 := (frame_no * 37) % stride   # 每拍错开抽样，覆盖更广
	for i in range(r0, count, stride):
		if hp[i] <= 0:
			continue
		sampled += 1
		# 只看「aggro + 非蓄力 + 有移动意图」的怪：攻击站定不算卡住
		if aggro[i] == 1 and state[i] != 2 and vel[i].length() > spd[i] * 0.3:
			aggro_n += 1
			if stuck_t[i] > 0.35:
				stuck_n += 1
		var hit := false
		var cx := int(pos[i].x / HASH_CELL)
		var cy := int(pos[i].y / HASH_CELL)
		var ri := radius[i]
		for gx in range(cx - 1, cx + 2):
			if hit:
				break
			for gy in range(cy - 1, cy + 2):
				if hit:
					break
				var arr = _hash.get(gx * 100000 + gy)
				if arr == null:
					continue
				for j in arr:
					if j == i:
						continue
					var thr := (ri + radius[j]) * 0.8
					var dvx: float = pos[i].x - pos[j].x
					var dvy: float = pos[i].y - pos[j].y
					if dvx * dvx + dvy * dvy < thr * thr:
						hit = true
						break
		if hit:
			stack_n += 1
	# 样本太少时比率无统计意义（1/1=100% 会误导）→ 视为 0
	stuck_ratio = float(stuck_n) / float(aggro_n) if aggro_n >= 5 else 0.0
	stack_ratio = float(stack_n) / float(sampled) if sampled >= 5 else 0.0


func _build_hash() -> void:
	# 清空上一帧所有 bucket 的数组（保留字典结构，避免反复分配）。
	# 注意：必须遍历 _hash 里所有 key，不能只遍历 _used_keys——
	# 否则上一帧未被登记的 bucket 会残留旧数据（曾导致分离查询到幽灵邻居）。
	for k in _hash:
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
						# 嗜血词缀：命中按伤害比例回血（只吸真实命中的这一口）
						if affix[i] == int(AFFIX_IDS.get("vampiric", 3)):
							var ls: float = float(ArpgBalance.data.get("affixes", {}).get("vampiric", {}).get("lifesteal", 0.5))
							hp[i] = mini(max_hp[i], hp[i] + int(atk[i] * ls))
						# 冰霜词缀：命中冻结玩家（移速 ×0.6，1.5s）+ 蓝字反馈
						elif affix[i] == int(AFFIX_IDS.get("frost", 5)) and t_i == 0 and world.player != null:
							world.player.slow_t = float(ArpgBalance.data.get("affixes", {}).get("frost", {}).get("slow", 1.5))
							world.spawn_popup("冻结！", world.player.position + Vector2(0, -40), Color(0.55, 0.8, 1.0), 18)
						# 易伤词缀：命中后玩家受伤 +30%（3s）
						elif affix[i] == int(AFFIX_IDS.get("brittle", 6)) and t_i == 0 and world.player != null:
							world.player.hurt_amp_t = float(ArpgBalance.data.get("affixes", {}).get("brittle", {}).get("amp", 3.0))
							world.spawn_popup("易伤！", world.player.position + Vector2(0, -40), Color(1.0, 0.6, 0.3), 18)
						# 燃烧词缀：命中点燃玩家（DoT 每秒灼烧，3s）
						elif affix[i] == int(AFFIX_IDS.get("burning", 7)) and t_i == 0 and world.player != null:
							var bcfg: Dictionary = ArpgBalance.data.get("affixes", {}).get("burning", {})
							world.player.burn_t = float(bcfg.get("dur", 3.0))
							world.player.burn_dps = float(bcfg.get("dot", 2.0))
							world.spawn_popup("燃烧！", world.player.position + Vector2(0, -40), Color(1.0, 0.45, 0.15), 18)
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
					# 二阶段弹幕增强：向数/弹速按 balance.boss.phase2 配置（狂暴读感质变）
					var bcfg: Dictionary = ArpgBalance.data.get("boss", {})
					var n_ray: int = int(bcfg.get("phase2_nova", 16)) if enraged[i3] == 1 else 10
					var ray_spd: float = float(bcfg.get("phase2_bullet_spd", 275.0)) if enraged[i3] == 1 else 215.0
					for k in n_ray:
						var ang := TAU * k / float(n_ray) + float(k % 3) * 0.2
						world.spawn_projectile(pos[i3], Vector2.RIGHT.rotated(ang), ray_spd,
							atk[i3] - 4, "enemy", Color(1.0, 0.45, 0.2) if enraged[i3] == 0 else Color(1.0, 0.3, 0.15), "bullet")
					world.spawn_nova(pos[i3], Color(1.0, 0.4, 0.2) if enraged[i3] == 0 else Color(1.0, 0.25, 0.1))
					main.add_shake(0.28)
					main.rumble(0.25, 0.5, 0.2)
				EV_ENRAGE:
					# 二阶段开场：横幅 + 召唤护主小鬼（数量/模板走 balance，Demo 默认 imp×2）
					var i5: int = e[1]
					if not is_alive(i5):
						break
					var ecfg: Dictionary = ArpgBalance.data.get("boss", {})
					main.hud.show_banner(str(ecfg.get("phase2_banner", "魔王狂暴了！")), Color(0.75, 0.15, 0.15))
					var n_sum: int = int(ecfg.get("phase2_summon", 2))
					var anchor: Vector2 = pos[i5]
					for s in n_sum:
						var cell: Vector2i = Vector2i((anchor / float(ArpgData.TILE)).floor()) + Vector2i(1 + s, (1 if s % 2 == 0 else -1))
						if not main.dungeon.is_floor(cell):
							cell = main.dungeon.random_cell_in(main.dungeon.rooms[0])
						world.spawn_mob(str(ecfg.get("phase2_summon_tpl", "imp")), cell, false, false)
						world.spawn_nova(ArpgDungeon.cell_to_pos(cell), Color(1.0, 0.35, 0.2))
					main.add_shake(0.4)
					main.hit_stop(0.12, 0.1)
				EV_AFFIX:
					var i4: int = e[1]
					if not is_alive(i4):
						break
					var aname: String = affix_name(i4)
					if aname != "":
						world.spawn_popup("%s！" % aname, pos[i4] + Vector2(0, -30), Color(1.0, 0.55, 0.35), 19)
						main.hud.log("%s的%s出现了！" % [aname, tpl_name[tpl[i4]]])
				EV_BOSS_MOVE:
					# Boss 招式池/扑击的主线程执行段：视觉/音效/伤害全在这里（worker 只发事件）
					var i6: int = e[1]
					if not is_alive(i6):
						break
					var mv_kind: String = str(e[2])
					match mv_kind:
						"charge", "pounce":
							world.spawn_popup("!", pos[i6] + Vector2(0, -34 if mv_kind == "charge" else -26),
								Color(1.0, 0.4, 0.3), 26 if mv_kind == "charge" else 22)
							main.play_sfx("attack", -8.0 if mv_kind == "pounce" else -6.0)
						"slam":
							# 范围震地：惩罚贴脸——半径内玩家与队友受伤（可闪避躲开 / 可弹反抵消）
							var scfg: Dictionary = ArpgBalance.data.get("threat", {}).get("moves", {}).get("slam", {})
							var srad := float(scfg.get("radius", 115.0))
							var sdmg := int(atk[i6] * float(scfg.get("dmg_mult", 1.4)))
							world.spawn_nova(pos[i6], Color(0.62, 0.55, 0.4))
							world.spawn_pxfx("burst", pos[i6], {"scale": 1.3})
							main.add_shake(0.45)
							main.rumble(0.5, 0.9, 0.3)
							main.hit_stop(0.06, 0.1)
							main.play_sfx("fire", -4.0)
							var pl = world.player
							if pl != null and is_instance_valid(pl) and not pl.dead \
									and pl.position.distance_to(pos[i6]) <= srad:
								pl.take_damage(sdmg, pos[i6])
							if main.party != null:
								for f in main.party.friends:
									if is_instance_valid(f) and not f.dead \
											and f.position.distance_to(pos[i6]) <= srad:
										f.take_damage(sdmg, pos[i6])
						"backstep":
							world.spawn_pxfx("burst", pos[i6], {"scale": 0.6, "tint": Color(0.7, 0.7, 0.75)})
						"observe":
							world.spawn_popup("?", pos[i6] + Vector2(0, -34), Color(0.8, 0.85, 0.95), 24)


func _handle_deaths() -> void:
	for i in count:
		if alive[i] == 1 and hp[i] <= 0:
			alive[i] = 0
			# 临终爆炸词缀：死后原地环射 6 弹 + 火环（逼玩家侧移收尾，别站桩捡尸）
			if affix[i] == int(AFFIX_IDS.get("burst", 4)) and world != null:
				for k in 6:
					world.spawn_projectile(pos[i], Vector2.RIGHT.rotated(TAU * k / 6.0), 205.0,
						maxi(1, atk[i] - 3), "enemy", Color(1.0, 0.55, 0.15), "bullet")
				world.spawn_nova(pos[i], Color(1.0, 0.5, 0.15))
				main.add_shake(0.22)
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
	affix[dst] = affix[src]
	affix_seen[dst] = affix_seen[src]
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
	sep[dst] = sep[src]
	stuck_t[dst] = stuck_t[src]
	nudge_t[dst] = nudge_t[src]
	nudge_dir[dst] = nudge_dir[src]
	hold_t[dst] = hold_t[src]
	pool_t[dst] = pool_t[src]
	ult_streak[dst] = ult_streak[src]


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
	tpl_pounce.clear()
	tpl_pounce_range.clear()
	tpl_pounce_speed.clear()
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
		# 受击挤压（squash & stretch）：flash 前半段横宽纵扁，命中瞬间的形体反馈
		# 扑击蓄力（狼/骑士/imp）：windup 期纵向拉长横向收窄——「蹲伏待扑」的形体语言
		var sq_x := 1.0
		var sq_y := 1.0
		if flash_t[i] > 0.075:
			sq_x = 1.18
			sq_y = 0.82
		elif state[i] == 2 and tpl_pounce[tpl[i]] == 1 and lunge[i] == Vector2.ZERO:
			sq_x = 0.82
			sq_y = 1.22
		var rect := Rect2(
			pos[i] + Vector2(-24.0 * s * sq_x, -29.0 * s * sq_y),
			Vector2(48.0 * s * sq_x, 48.0 * s * sq_y))
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
