class_name ArpgDropSystem
extends Node2D
## 击杀掉落（金币/宝石）表现层 + 吸附手感：
##
##  散开(SCATTER) → 静置(IDLE) → 吸附(ATTRACT) → 结算
##
## 设计要点（都是"爽快收集"的常见做法）：
##  · 爆量：一只怪掉 5~9 颗，精英/Boss 成倍；用 SoA + 单次 _draw 批量画，几百颗也不掉帧；
##  · 散开：随机方向 + 随机初速 + 指数阻尼，撞墙按轴反弹（不会弹进墙里消失）；
##  · 待吸：短暂静置/上下浮动，进入吸附半径且过了 `attract_delay` 才启动 —— 先看见再被吸走；
##  · 吸附：锁定主控单位，速度按 `attract_time` 做 ease-in 曲线加速，同时缩小 + 拖尾；
##    目标点取角色上半身（`unit.position + (0, -8)`），读起来是"向上飞进角色"；
##  · 结算：到达 `arrive_dist` 才加钱（`settle_mode=arrive`），也可配置成一开始吸就结算。
##
## 参数全在 balance.json 的 `drops` 段（common 通用 / gold / gem 覆盖），保存即热重载。

const MAX := 400

const S_SCATTER := 0
const S_IDLE := 1
const S_ATTRACT := 2

const K_COIN := 0
const K_GEM := 1

const COIN_TINT := Color(1.0, 0.84, 0.32)
const GEM_TINT := Color(0.55, 0.82, 1.0)

var world: Node

var count := 0
var pos := PackedVector2Array()
var prev := PackedVector2Array()
var vel := PackedVector2Array()
var phase := PackedByteArray()
var t := PackedFloat32Array()        # 当前阶段计时
var at := PackedFloat32Array()       # 吸附计时（算速度曲线）
var value := PackedInt32Array()
var kind := PackedByteArray()
var scl := PackedFloat32Array()
var alive := PackedByteArray()

var _sfx_cd := 0.0
var _burst_n := 0                    # 本帧结算颗数（用于 HUD 合成一次提示）


func setup(w: Node) -> void:
	world = w
	pos.resize(MAX)
	prev.resize(MAX)
	vel.resize(MAX)
	phase.resize(MAX)
	t.resize(MAX)
	at.resize(MAX)
	value.resize(MAX)
	kind.resize(MAX)
	scl.resize(MAX)
	alive.resize(MAX)
	z_index = 24                      # 地板/角色之间：捡的时候从脚下飞起来


# ———————— 生成 ————————

## 一只怪死亡时的爆量掉落。total_gold 是"这一只怪总共值多少"，会按颗数均分。
func spawn_burst(p: Vector2, total_gold: int, elite: bool = false, boss: bool = false) -> void:
	var main = world.main
	if main == null or total_gold <= 0:
		return
	var cfg: Dictionary = ArpgBalance.data.get("drops", {})
	if not bool(cfg.get("enabled", true)):
		return
	var rng: RandomNumberGenerator = main.rng
	var n: int = rng.randi_range(int(_f("gold", "count_min", 5.0)), int(_f("gold", "count_max", 9.0)))
	var mult := 1.0
	if boss:
		mult = float(cfg.get("boss_mult", 6.0))
	elif elite:
		mult = float(cfg.get("elite_mult", 2.0))
	n = clampi(int(round(float(n) * mult)), 1, 28)
	var total: int = int(round(float(total_gold) * mult))
	# 爆点粒子：一次性金尘（走 world 的特效池，池满自动回收最旧的，不会爆内存）
	if world.has_method("burst"):
		world.burst(p, ArpgTex.tex(ArpgWorld.FX_PARTICLE_PATH), COIN_TINT, 9, 230.0, 0.42, 0.09)

	# 宝石：Boss 必出多颗、精英必出 1 颗、普通怪按概率
	var gems := 0
	var gem_value: int = int(_f("gem", "value", 8.0))
	if boss:
		gems = 4
	elif elite:
		gems = 1
	elif rng.randf() < float(_f("gem", "chance", 0.18)):
		gems = 1
	for gi in gems:
		var gv: int = mini(gem_value, total)
		if gv <= 0:
			break
		total -= gv
		_spawn(p, gv, K_GEM, rng)
	# 剩下的按金币均分（余数给前几颗，避免总价对不上）
	if total > 0:
		var coins: int = mini(n, total)
		var each: int = total / maxi(coins, 1)
		var rest: int = total - each * coins
		for ci in coins:
			var v: int = each + (1 if ci < rest else 0)
			if v > 0:
				_spawn(p, v, K_COIN, rng)


func _spawn(p: Vector2, v: int, k: int, rng: RandomNumberGenerator) -> void:
	var i := _alloc(rng)
	if i < 0:
		return
	alive[i] = 1
	pos[i] = p + Vector2(rng.randf_range(-6.0, 6.0), rng.randf_range(-6.0, 6.0))
	prev[i] = pos[i]
	var spd_min: float = _f("gold" if k == K_COIN else "gem", "scatter_speed_min", 70.0)
	var spd_max: float = _f("gold" if k == K_COIN else "gem", "scatter_speed_max", 215.0)
	var ang: float = rng.randf() * TAU
	var spd: float = rng.randf_range(spd_min, spd_max)
	# 略微向上抛：看起来是"从尸体里崩出来"，不是平地散开
	vel[i] = Vector2.RIGHT.rotated(ang) * spd + Vector2(0, -spd * 0.22)
	phase[i] = S_SCATTER
	t[i] = 0.0
	at[i] = 0.0
	value[i] = v
	kind[i] = k
	scl[i] = _f("gold" if k == K_COIN else "gem", "scale_start", 1.0)


func _alloc(rng: RandomNumberGenerator) -> int:
	if count < MAX:
		var i := count
		count += 1
		return i
	# 池满：把最老的待吸颗直接结算掉（不吞收益），腾出槽位
	var best := -1
	var bt := -1.0
	for j in count:
		if alive[j] == 0:
			continue
		var pt := t[j] if phase[j] != S_ATTRACT else 99.0
		if pt > bt:
			bt = pt
			best = j
	if best >= 0:
		_collect(best)
		return best
	return -1


# ———————— 每帧 ————————

func _physics_process(delta: float) -> void:
	if world == null or world.main == null or world.main.state != world.main.State.PLAY:
		return
	_sfx_cd = maxf(0.0, _sfx_cd - delta)
	var focus = _focus()
	var scatter_time: float = _f("gold", "scatter_time", 0.45)
	var friction: float = _f("gold", "friction", 3.4)
	var bounce: float = _f("gold", "bounce", 0.35)
	var radius: float = _f("gold", "attract_radius", 165.0)
	var delay: float = _f("gold", "attract_delay", 0.28)
	var life: float = _f("gold", "lifetime", 14.0)
	var v0: float = _f("gold", "attract_speed_start", 140.0)
	var v1: float = _f("gold", "attract_speed_end", 800.0)
	var dur: float = maxf(_f("gold", "attract_time", 0.42), 0.05)
	var arrive: float = _f("gold", "arrive_dist", 12.0)
	var s_end: float = _f("gold", "scale_end", 0.35)
	var settle_on_start: bool = str(_cfg_str("settle_mode", "arrive")) == "attract_start"
	var target: Vector2 = focus.position + Vector2(0, -8) if focus != null else Vector2.ZERO
	var has_focus: bool = focus != null and is_instance_valid(focus)

	for i in count:
		if alive[i] == 0:
			continue
		prev[i] = pos[i]
		match phase[i]:
			S_SCATTER:
				vel[i] = vel[i] * exp(-friction * delta)
				pos[i] += vel[i] * delta
				_slide_on_wall(i, bounce)
				t[i] += delta
				if t[i] >= scatter_time:
					phase[i] = S_IDLE
					t[i] = 0.0
					vel[i] = Vector2.ZERO
			S_IDLE:
				t[i] += delta
				if has_focus and pos[i].distance_to(focus.position) <= radius \
						and t[i] >= delay:
					phase[i] = S_ATTRACT
					at[i] = 0.0
					if settle_on_start:
						_collect(i)
						continue
				elif t[i] >= life:
					# 超时：还在"大概附近"就强制吸回来（不吞收益），远到看不见就直接消失
					if has_focus and pos[i].distance_to(focus.position) <= radius * 3.0:
						phase[i] = S_ATTRACT
						at[i] = 0.0
					else:
						alive[i] = 0
						continue
			S_ATTRACT:
				at[i] += delta
				var prog: float = clampf(at[i] / dur, 0.0, 1.0)
				# ease-in：刚起步慢、越飞越快（"嗖一下被吸走"的加速感）
				var spd: float = lerpf(v0, v1, prog * prog)
				var d: Vector2 = target - pos[i]
				var dl: float = d.length()
				if dl <= arrive:
					_collect(i)
					continue
				pos[i] += d / maxf(dl, 0.01) * spd * delta
				scl[i] = lerpf(scl[i], s_end, clampf(delta * 8.0, 0.0, 1.0))
	queue_redraw()
	_compact()
	if _burst_n > 0:
		# 一帧内捡到多颗只弹一次 UI（9 颗各弹一次 = 9 个补间，纯浪费）
		if world.main.hud != null:
			world.main.hud.pop_gold(world.main.rpg.gold)
		if _sfx_cd <= 0.0:
			world.main.play_sfx("cursor", -16.0)
			_sfx_cd = 0.10
		_burst_n = 0


## 按轴分离的撞墙反弹：只翻转撞到的那一轴，避免弹进墙里消失
func _slide_on_wall(i: int, bounce: float) -> void:
	var d = world.dungeon
	if d == null:
		return
	var c := Vector2i((pos[i] / float(ArpgData.TILE)).floor())
	if d.is_floor(c):
		return
	var cx := Vector2i((Vector2(pos[i].x, prev[i].y) / float(ArpgData.TILE)).floor())
	var cy := Vector2i((Vector2(prev[i].x, pos[i].y) / float(ArpgData.TILE)).floor())
	if d.is_floor(cx):
		pos[i].y = prev[i].y
		vel[i].y = -vel[i].y * bounce
	elif d.is_floor(cy):
		pos[i].x = prev[i].x
		vel[i].x = -vel[i].x * bounce
	else:
		pos[i] = prev[i]
		vel[i] = -vel[i] * bounce * 0.6


func _collect(i: int) -> void:
	if alive[i] == 0:
		return
	alive[i] = 0
	var v: int = value[i]
	if v <= 0:
		return
	_burst_n += v
	# 拾取闪光：金币/宝石各用自己的序列帧。这里关掉加法混合——
	# 大量金币同时被吸走时会糊成一片白，普通混合下还能看清形体。
	if world.has_method("spawn_pxfx"):
		var fx_name := "gem" if int(kind[i]) == K_GEM else "coin"
		world.spawn_pxfx(fx_name, pos[i], {"scale": 0.55, "speed": 1.6, "once": true, "additive": false})
	if world.main != null:
		world.main.on_drop_collected(int(kind[i]), v)


func _compact() -> void:
	var j := 0
	for i in count:
		if alive[i] == 0:
			continue
		if j != i:
			pos[j] = pos[i]
			prev[j] = prev[i]
			vel[j] = vel[i]
			phase[j] = phase[i]
			t[j] = t[i]
			at[j] = at[i]
			value[j] = value[i]
			kind[j] = kind[i]
			scl[j] = scl[i]
			alive[j] = 1
		j += 1
	count = j


func _focus():
	var main = world.main
	if main == null:
		return null
	if main.possession != null and is_instance_valid(main.possession.current_unit):
		return main.possession.current_unit
	if main.player != null and is_instance_valid(main.player):
		return main.player
	return null


func _cfg_str(key: String, def: String) -> String:
	var d: Dictionary = ArpgBalance.data.get("drops", {})
	return str(d.get(key, def))


## 取值顺序：细分段（gold/gem）→ common → 默认值
func _f(section: String, key: String, def: float) -> float:
	var d: Dictionary = ArpgBalance.data.get("drops", {})
	var s: Dictionary = d.get(section, {})
	if s.has(key):
		return float(s[key])
	var c: Dictionary = d.get("common", {})
	if c.has(key):
		return float(c[key])
	return def


# ———————— 渲染（单批次） ————————

func _draw() -> void:
	for i in count:
		if alive[i] == 0:
			continue
		var c: Vector2 = pos[i]
		var tint: Color = COIN_TINT if kind[i] == K_COIN else GEM_TINT
		var r: float = (4.0 if kind[i] == K_COIN else 6.2) * scl[i]
		if phase[i] == S_ATTRACT:
			# 拖尾：从上一帧位置拉一条渐隐线，速度越快越长
			draw_line(prev[i], c, Color(tint.r, tint.g, tint.b, 0.30), r * 1.3)
			draw_circle(c, r * 2.6, Color(tint.r, tint.g, tint.b, 0.16))
		else:
			var bob: float = sin(t[i] * 6.0 + float(i)) * 1.5
			c += Vector2(0, bob)
			draw_circle(c, r * 2.0, Color(tint.r, tint.g, tint.b, 0.14))
		var pts := PackedVector2Array([
			c + Vector2(0, -r * 1.5), c + Vector2(r, 0),
			c + Vector2(0, r * 1.5), c + Vector2(-r, 0),
		])
		draw_colored_polygon(pts, tint)
		draw_colored_polygon(PackedVector2Array([
			c + Vector2(0, -r * 1.5), c + Vector2(0, r * 1.5), c + Vector2(-r, 0),
		]), tint.darkened(0.28))
