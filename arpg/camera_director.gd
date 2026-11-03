class_name ArpgCameraDirector
extends Node
## 镜头调度器（可复用）：决定「这一帧谁在说话、怎么过渡」，取景算法交给 CameraRig。
##
## 借鉴 Cinemachine 的两层结构（Brain + 虚拟相机优先级）但没有 Unity 那套运行时：
##  · 只有一台真实相机（rig），调度器维护一个「镜头栈」，栈顶生效；
##  · 基础镜头 FOLLOW 永远在栈底；过场/定点/外部接管都是"压栈 + 到期自动弹栈"；
##  · **每个临时镜头都有硬超时**（`camera.max_shot_time`），任何忘了 pop 的路径都不会
##    把镜头永久锁死——这正是"镜头调度失效"这类 bug 的根治手段（状态不会泄漏）；
##  · 焦点失效时用 provider 兜底，再不行就停在最后有效位置：换层/换场景/单位被释放
##    都不会让调度停摆。
##
## 复用到别的场景只需要：`setup(host, dungeon)` → 每帧 `bind(focus, tracked)` + `update(dt)`，
## 过场时 `play_focus_point/play_focus_node`，需要自己写 position 时 `begin_external/end_external`。

enum Shot { FOLLOW = 0, FOCUS_POINT = 1, FOCUS_NODE = 2, EXTERNAL = 3 }

const SHOT_NAME := {
	Shot.FOLLOW: "跟随",
	Shot.FOCUS_POINT: "定点",
	Shot.FOCUS_NODE: "跟踪目标",
	Shot.EXTERNAL: "外部接管",
}

const TRAUMA_DECAY := 1.7

# 取景算法脚本（preload 常量：新脚本未进 class cache 时也能引用，见 HANDOFF §6 坑 9）
const Rig := preload("res://arpg/camera_rig.gd")

var rig: Rig
var focus: Node2D = null
var tracked: Array = []
var focus_fallback := Callable()      # 焦点失效时的兜底（通常返回当前主控单位）
var trauma := 0.0

var _shots: Array = []
var _look := Vector2.ZERO
var _shake_t := 0.0
var _last_pos := Vector2.ZERO
var _max_shot_time := 6.0
var _focus_rate := 9.0
var _look_ahead := 34.0


func setup(host: Node, d: ArpgDungeon) -> void:
	var c: Dictionary = ArpgBalance.data.get("camera", {})
	_max_shot_time = float(c.get("max_shot_time", _max_shot_time))
	_focus_rate = float(c.get("focus_rate", _focus_rate))
	_look_ahead = float(c.get("look_ahead", _look_ahead))
	if rig == null:
		rig = Rig.new()
		add_child(rig)
	rig.setup(host, d)
	revoke_all()


## 每层/每场景重设边界并回到基础镜头
func set_stage(host: Node, d: ArpgDungeon) -> void:
	setup(host, d)


func reset(pos: Vector2) -> void:
	if rig == null:
		return
	rig.reset(pos)
	_last_pos = pos
	revoke_all()


func bind(focus_node: Node2D, friends: Array = []) -> void:
	focus = focus_node
	tracked = friends


func add_shake(v: float) -> void:
	trauma = clampf(trauma + v, 0.0, 1.0)


# ———————— 镜头栈 ————————

## 定点过场：把镜头推到某处，dur 秒后自动回到跟随
func play_focus_point(pos: Vector2, dur: float = 1.5) -> void:
	_drop_top_of_kind(Shot.FOCUS_POINT)
	_shots.append(_make(Shot.FOCUS_POINT, maxf(0.2, dur), pos))


## 跟拍某个单位（Boss 登场 / 事件角色），dur 秒后自动回到跟随
func play_focus_node(node: Node2D, dur: float = 2.0) -> void:
	_drop_top_of_kind(Shot.FOCUS_NODE)
	_shots.append(_make(Shot.FOCUS_NODE, maxf(0.2, dur), Vector2.ZERO, node))


## 外部接管（自己在别处 tween position）。必须给时长：到期自动还给跟随，避免状态泄漏
func begin_external(dur: float = -1.0) -> void:
	_drop_top_of_kind(Shot.EXTERNAL)
	_shots.append(_make(Shot.EXTERNAL, dur))


func end_external() -> void:
	_drop_top_of_kind(Shot.EXTERNAL)


## 清空所有临时镜头，回到基础跟随（换场景/重开/读档时调用）
func revoke_all() -> void:
	_shots.clear()
	_shots.append(_make(Shot.FOLLOW))


func shot_kind() -> int:
	return int(_shots[_shots.size() - 1].kind) if not _shots.is_empty() else Shot.FOLLOW


func is_cinematic() -> bool:
	return shot_kind() != Shot.FOLLOW


func _make(kind: int, dur: float = -1.0, pos: Vector2 = Vector2.ZERO, node: Node2D = null) -> Dictionary:
	var s := {"kind": kind, "t": 0.0, "dur": dur, "pos": pos, "node": node}
	if kind != Shot.FOLLOW and float(s["dur"]) <= 0.0:
		s["dur"] = _max_shot_time      # 兜底：临时镜头必须能自己结束
	return s


func _drop_top_of_kind(kind: int) -> void:
	while _shots.size() > 1 and int(_shots[_shots.size() - 1]["kind"]) == kind:
		_shots.pop_back()


# ———————— 每帧 ————————

func update(delta: float) -> void:
	if rig == null:
		return
	if _shots.is_empty():
		revoke_all()
	# 1) 过期弹栈（含硬超时兜底）：一次最多弹 8 层，防止异常数据把帧卡住
	var guard := 0
	while _shots.size() > 1 and guard < 8:
		guard += 1
		var top: Dictionary = _shots[_shots.size() - 1]
		if float(top["dur"]) > 0.0 and float(top["t"]) >= float(top["dur"]):
			_shots.pop_back()
		else:
			break
	var shot: Dictionary = _shots[_shots.size() - 1]
	shot["t"] = float(shot["t"]) + delta
	# 2) 栈顶驱动
	match int(shot["kind"]):
		Shot.FOLLOW:
			_step_follow(delta)
		Shot.FOCUS_POINT:
			rig.drive_to(delta, shot["pos"], _focus_rate)
		Shot.FOCUS_NODE:
			_step_focus_node(delta, shot)
		_:
			# 外部接管：只同步内部状态，画面由外部代码写
			rig.adopt_external()
	# 3) 后处理：震屏 / 前视（外部接管时不插手）
	var k := int(shot["kind"])
	if k != Shot.EXTERNAL:
		_apply_post(delta, k == Shot.FOLLOW or k == Shot.FOCUS_NODE)


func _step_follow(delta: float) -> void:
	if not _valid(focus):
		focus = _resolve_focus()
	if not _valid(focus):
		# 焦点彻底没了（换层瞬间/切回标题）：停在最后有效位置，不崩不跳
		rig.drive_to(delta, _last_pos, 3.0)
		return
	_last_pos = focus.position
	rig.follow(delta, focus, tracked)


func _step_focus_node(delta: float, shot: Dictionary) -> void:
	var n: Node2D = shot.get("node")
	if not _valid(n):
		rig.drive_to(delta, _last_pos, 3.0)
		return
	_last_pos = n.position
	rig.follow(delta, n, [])


func _apply_post(delta: float, allow_look: bool) -> void:
	trauma = maxf(0.0, trauma - TRAUMA_DECAY * delta)
	_shake_t += delta * 34.0
	var amt := trauma * trauma
	rig.rotation = 0.045 * amt * sin(_shake_t * 1.1)
	var want := Vector2.ZERO
	if allow_look and _valid(focus) and not bool(focus.get("dead")):
		want = rig.focus_look_dir(focus) * _look_ahead
	_look = _look.lerp(want, 1.0 - pow(0.002, delta))
	rig.offset = _look + Vector2(
		14.0 * amt * sin(_shake_t * 1.7),
		10.0 * amt * sin(_shake_t * 2.3))


func _resolve_focus():
	if focus_fallback.is_valid():
		var f = focus_fallback.call()
		if f != null and is_instance_valid(f):
			return f
	# 退一步：如果 rig 的宿主有 player，就用它
	if rig != null and rig.main != null:
		var p = rig.main.get("player")
		if p != null and is_instance_valid(p):
			return p
	return null


static func _valid(n) -> bool:
	return n != null and is_instance_valid(n)


func debug_info() -> String:
	if rig == null:
		return "镜头未初始化"
	return "%s · %s" % [rig.debug_info(), SHOT_NAME.get(shot_kind(), "?")]
