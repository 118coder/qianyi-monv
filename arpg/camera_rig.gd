class_name ArpgCameraRig
extends Camera2D
## 取景算法层（只负责"把画面摆好看"，不负责"什么时候运镜"）。
##
## 合作类 ARPG 的通用做法（pan-first + zoom-to-fit + 迟滞 + 临界阻尼）：
##  1. 跟踪集合：焦点 + 值得关注的队友；进入/退出两套半径做迟滞，边缘不抽搐。
##  2. 先平移：中心朝包围盒拉 `pan_weight`，但硬约束焦点留在「中心 ±safe_frac×半屏」内。
##  3. 再缩放：平移压不住才缩，`zoom = 视口/需要尺寸 × fit_bias`，夹 [min_zoom, base_zoom]。
##  4. 稳定：缩放死区 + 反向冷却 + 非对称速率；中心用临界阻尼弹簧 + 限速 + 死区。
##  5. 与 Camera2D.limit 同口径二次夹持，避免"引擎夹 position / 自身中心外走"互相拉扯。
##
## 调度（跟随/过场/外部接管/中断回落）不在这里，见 `arpg/camera_director.gd`。
## 换场景时只换调度器，取景算法原样复用；反之换取景算法也不影响调度。

var main: Node                   # 仅用于取网格视野（可空）

var base_zoom := 1.7          # 基准缩放（1.7 ≈ 贴身；数值越大越近）
var min_zoom := 1.12          # 最远拉出（多目标取景的下限）
var pan_weight := 0.42        # 包围盒中心对取景中心的拉力（0=只看主控）
var safe_frac := 0.34         # 主控必须落在「中心 ± safe_frac × 半屏」内
var fit_bias := 0.90          # 取景留白系数（<1 = 多留边）
var track_ratio := 1.30       # 进入跟踪的距离 = 半屏对角线 × 该系数
var track_release := 1.30     # 退出跟踪 = 进入距离 × 该系数（迟滞）
var margin := 30.0            # 包围盒外扩（世界像素）
var smooth_time := 0.16       # 追焦时间常数（越小越跟手）
var max_speed := 2400.0       # 追焦最大速度（px/s）
var zoom_out_rate := 3.0      # 拉远速度（快：队友要出画时及时让位）
var zoom_in_rate := 1.5       # 拉近速度（慢：战斗结束回位更稳）
var zoom_deadband := 0.06     # 缩放死区（小于该差值不动作）

const _MIN_NEED := Vector2(150.0, 120.0)

var _center := Vector2.ZERO
var _vel := Vector2.ZERO
var _zoom := 1.7
var _zoom_target := 1.7
var _zoom_hold := 0.0
var _tracked := {}            # instance_id → true（迟滞跟踪集合）
var _los_cache := {}
var _vp := Vector2(1152, 648)
var _primed := false
var _tracked_n := 0
var _last_written := Vector2.INF   # 上一次由本装置写入的 position（用于识别外部接管）


## 每层/每张地图调用一次：读配置 + 重设边界（相机节点复用，不新建）
func setup(host: Node, d: ArpgDungeon) -> void:
	main = host
	var c: Dictionary = ArpgBalance.data.get("camera", {})
	base_zoom = float(c.get("base_zoom", base_zoom))
	min_zoom = float(c.get("min_zoom", min_zoom))
	pan_weight = float(c.get("pan_weight", pan_weight))
	safe_frac = float(c.get("safe_frac", safe_frac))
	fit_bias = float(c.get("fit_bias", fit_bias))
	track_ratio = float(c.get("track_ratio", track_ratio))
	track_release = float(c.get("track_release", track_release))
	margin = float(c.get("margin", margin))
	smooth_time = float(c.get("smooth_time", smooth_time))
	max_speed = float(c.get("max_speed", max_speed))
	zoom_out_rate = float(c.get("zoom_out_rate", zoom_out_rate))
	zoom_in_rate = float(c.get("zoom_in_rate", zoom_in_rate))
	zoom_deadband = float(c.get("zoom_deadband", zoom_deadband))
	min_zoom = minf(min_zoom, base_zoom)
	# 自己做平滑（内置平滑会把算好的目标再拖一次 → 双重延迟 + 超调）
	position_smoothing_enabled = false
	rotation = 0.0
	offset = Vector2.ZERO
	limit_left = 0
	limit_top = 0
	limit_right = d.w * ArpgData.TILE
	limit_bottom = d.h * ArpgData.TILE
	_tracked.clear()
	_los_cache.clear()
	_zoom = base_zoom
	_zoom_target = base_zoom
	zoom = Vector2.ONE * base_zoom


## 换层/重开/传送：直接落位（不做平滑，避免从上一张图的位置飘过来）
func reset(p: Vector2) -> void:
	_center = p
	_vel = Vector2.ZERO
	_zoom = base_zoom
	_zoom_target = base_zoom
	_zoom_hold = 0.0
	zoom = Vector2.ONE * base_zoom
	_tracked.clear()
	offset = Vector2.ZERO
	rotation = 0.0
	position = p
	_last_written = p
	_primed = true


## 朝向向量（给调度的"前视"用；玩家/队友/APC 都能取）
func focus_look_dir(focus: Node2D) -> Vector2:
	if focus == null or not is_instance_valid(focus):
		return Vector2.ZERO
	if focus is ArpgPlayer:
		return focus.facing
	if focus is ArpgFriendUnit:
		return focus.face_dir()
	if focus.has_method("face_dir"):
		return focus.call("face_dir")
	return Vector2.ZERO


## 跟随取景：焦点 + 队友集合，允许缩放让位
func follow(delta: float, focus: Node2D, friends: Array) -> void:
	if focus == null or not is_instance_valid(focus):
		return
	var vp := get_viewport_rect().size
	if vp.x >= 64.0 and vp.y >= 64.0:
		_vp = vp
	var focus_pos: Vector2 = focus.position
	var half_diag := (_vp * 0.5 / maxf(_zoom, 0.1)).length()
	var enter := half_diag * track_ratio
	var leave := enter * track_release
	var extra := _collect(friends, focus, enter, leave)
	_tracked_n = extra.size()

	var minp := focus_pos
	var maxp := focus_pos
	for p in extra:
		minp = Vector2(minf(minp.x, p.x), minf(minp.y, p.y))
		maxp = Vector2(maxf(maxp.x, p.x), maxf(maxp.y, p.y))
	var bb := Rect2(minp, maxp - minp).grow(margin)
	var w := pan_weight
	if extra.size() > 0:
		w = minf(pan_weight + 0.07 * float(extra.size()), 0.72)
	var target_center: Vector2 = focus_pos.lerp(bb.get_center(), w)

	# 平移 + 缩放交替求解两轮：先按当前缩放夹住焦点，再按包围盒求缩放，再回夹
	var zt := _zoom_target
	for _it in 2:
		var half := _vp * 0.5 / maxf(zt, 0.1)
		target_center.x = clampf(target_center.x, focus_pos.x - half.x * safe_frac, focus_pos.x + half.x * safe_frac)
		target_center.y = clampf(target_center.y, focus_pos.y - half.y * safe_frac, focus_pos.y + half.y * safe_frac)
		var need := Vector2(
			maxf(target_center.x - bb.position.x, bb.end.x - target_center.x) * 2.0,
			maxf(target_center.y - bb.position.y, bb.end.y - target_center.y) * 2.0)
		need.x = maxf(need.x, _MIN_NEED.x)
		need.y = maxf(need.y, _MIN_NEED.y)
		var fit := minf(_vp.x / need.x, _vp.y / need.y) * fit_bias
		zt = clampf(minf(base_zoom, fit), min_zoom, base_zoom)

	_zoom_hold = maxf(0.0, _zoom_hold - delta)
	if absf(zt - _zoom_target) > zoom_deadband:
		var flip: bool = (_zoom_target - _zoom) * (zt - _zoom) < 0.0
		if not (flip and _zoom_hold > 0.0):
			_zoom_target = zt
			_zoom_hold = 0.35
	var rate: float = zoom_out_rate if _zoom_target < _zoom else zoom_in_rate
	_zoom = lerpf(_zoom, _zoom_target, 1.0 - exp(-rate * delta))
	if absf(_zoom - _zoom_target) < 0.002:
		_zoom = _zoom_target
	zoom = Vector2.ONE * _zoom

	_commit(delta, target_center)


## 定点/过场：把取景中心快速推到某点（保留弹簧状态，镜头结束后回落无跳变）
func drive_to(delta: float, pos: Vector2, rate: float = 9.0) -> void:
	_zoom_target = base_zoom
	_zoom = lerpf(_zoom, base_zoom, 1.0 - exp(-zoom_in_rate * delta))
	zoom = Vector2.ONE * _zoom
	_commit(delta, pos, maxf(rate, 0.5))


## 外部接管时（自己 tween 了 position）让内部状态跟上，避免接管结束的一瞬间回弹。
## 判据是「当前 position 与上次写入值不一致」——不能拿 position 和 _center 比：
## 正常跟随里 position 本来就落后于 _center 一帧的位移，那样会把自己的推进判成"外部接管"。
func adopt_external() -> void:
	if _last_written == Vector2.INF:
		return
	if position.distance_to(_last_written) > 1.0:
		_center = position
		_vel = Vector2.ZERO
		_last_written = position


## 中心平滑 + 限位 + 落地
func _commit(delta: float, target_center: Vector2, omega: float = -1.0) -> void:
	target_center = target_center.round()
	if not _primed:
		_center = target_center
		_vel = Vector2.ZERO
		_primed = true
	else:
		adopt_external()
		if omega < 0.0 and (target_center - _center).length() < 4.0:
			target_center = _center
		var w: float = omega if omega > 0.0 else 2.0 / maxf(smooth_time, 0.04)
		_center = _smooth_damp(_center, target_center, delta, w)
	_clamp_limits()
	position = _center
	_last_written = position


## 临界阻尼弹簧（Unity SmoothDamp 同式）：无过冲、帧率无关
func _smooth_damp(cur: Vector2, goal: Vector2, dt: float, omega: float) -> Vector2:
	var x := omega * dt
	var e := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change := cur - goal
	var temp := (_vel + change * omega) * dt
	_vel = (_vel - temp * omega) * e
	var out := goal + (change + temp) * e
	# 限速：传送/主控切换时不要"瞬移式甩镜头"
	var step := out - cur
	var max_step := max_speed * dt
	if step.length() > max_step and max_step > 0.0:
		out = cur + step.normalized() * max_step
		_vel = Vector2.ZERO
	return out


## 与 Camera2D 的 limit 同口径再夹一次：否则引擎夹住 position 而 _center 继续外走 → 画面细碎抖动
func _clamp_limits() -> void:
	var half := _vp * 0.5 / maxf(_zoom, 0.01)
	var lx: float = float(limit_left) + half.x
	var rx: float = float(limit_right) - half.x
	if lx <= rx:
		_center.x = clampf(_center.x, lx, rx)
	else:
		_center.x = (float(limit_left) + float(limit_right)) * 0.5
	var ty: float = float(limit_top) + half.y
	var by: float = float(limit_bottom) - half.y
	if ty <= by:
		_center.y = clampf(_center.y, ty, by)
	else:
		_center.y = (float(limit_top) + float(limit_bottom)) * 0.5


## 收集需要入画的队友（迟滞 + 隔墙剔除）
func _collect(friends: Array, focus: Node2D, enter: float, leave: float) -> Array:
	var out: Array = []
	if friends.is_empty():
		_tracked.clear()
		return out
	var alive := {}
	var fp: Vector2 = focus.position
	for f in friends:
		if f == null or not is_instance_valid(f) or f == focus or f.dead:
			continue
		var id: int = f.get_instance_id()
		alive[id] = true
		var d: float = f.position.distance_to(fp)
		if _tracked.has(id):
			if d > leave:
				_tracked.erase(id)
		elif d <= enter and _framing_visible(f.position, fp, d):
			_tracked[id] = true
		if _tracked.has(id):
			out.append(f.position)
	for id in _tracked.keys():
		if not alive.has(id):
			_tracked.erase(id)
	return out


## 远处队友若隔着墙（在别的房间）不参与取景：否则镜头会被"墙后的队友"拽走。
## 近处（<300px）无条件参与，避免绕柱时队友忽然被剔除造成缩放抽搐。
func _framing_visible(a: Vector2, b: Vector2, d: float) -> bool:
	if d < 300.0:
		return true
	if main == null or main.party == null:
		return true
	var key := int(a.x / 64.0) * 100003 + int(a.y / 64.0) * 7919 \
		+ int(b.x / 64.0) * 104729 + int(b.y / 64.0) * 1299709
	var v = _los_cache.get(key)
	if v == null:
		v = main.party.line_clear(a, b)
		if _los_cache.size() > 4000:
			_los_cache.clear()
		_los_cache[key] = v
	return bool(v)


func debug_info() -> String:
	return "取景 %.2fx · 入画队友 %d" % [_zoom, _tracked_n]
