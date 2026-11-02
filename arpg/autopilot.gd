class_name ArpgAutopilot
extends Node
## 全自动测试驾驶：接管输入，把「选人 → 战斗 → 开箱 → 药水 → 下楼 → 结算」整条链路打完。
## 用法：godot --path . -- --autoplay           （客户端模式：带窗口实时跑）
##      godot --headless --path . -- --autoplay（无头模式：CI 回归用）
## 结果用进程退出码汇报：0 = PASS，1 = FAIL；日志带 [AUTOPLAY] 前缀。
## 策略：药水保命 → 近身平A + 定期技能 → 清完怪找宝箱/楼梯 → 传送门凯旋。
## 稳妥性设计：卡墙自动绕行、看门狗超时、100 秒未收敛主动撤退（保证测试必有终点）。

var main: Node
var _think := 0.6        # 首拍稍微等场景就绪
var _elapsed := 0.0
var _stuck := 0.0
var _last_pos := Vector2.ZERO
var _skill_t := 5.0
var _potion_tested := false
var _pressed := {}       # 本拍按住的方向键
var _taps := []          # 本拍的一次性键（下一拍释放）
var _astar := AStarGrid2D.new()
var _astar_ready := false
var _astar_floor := -1
var done := false

const THINK := 0.3
const WATCHDOG := 240.0
var retreat_at := 100.0
var _status_t := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--retreat="):
			retreat_at = float(a.split("=")[1])
	print("[AUTOPLAY] 驾驶已挂载，目标：打通整局流程（撤退时限 %.0fs）" % retreat_at)


func _process(delta: float) -> void:
	if done:
		return
	_elapsed += delta
	if _elapsed > WATCHDOG:
		_fail("看门狗超时（%.0fs）" % WATCHDOG)
		return
	_think -= delta
	if _think > 0.0:
		return
	_think = THINK
	# 释放上一拍的按键
	for a in _taps:
		Input.action_release(a)
	_taps.clear()
	for a in _pressed:
		Input.action_release(a)
	_pressed.clear()
	# 周期状态日志（诊断用）
	_status_t += THINK
	if _status_t >= 5.0:
		_status_t = 0.0
		if main.state == 1 and is_instance_valid(main.player):
			var mi: int = main.world.mobs.nearest(main.player.position)
			var dist_txt := "无" if mi < 0 else "%.1f" % main.player.position.distance_to(main.world.mobs.pos[mi])
			print("[AUTOPLAY] t=%.0fs pos=(%.0f,%.0f) hp=%d/%d 最近敌人=%s 击杀=%d" % [
				_elapsed, main.player.position.x, main.player.position.y,
				main.player.hp, main.player.max_hp, dist_txt, main.kills])

	match int(main.state):
		0:   # SELECT
			print("[AUTOPLAY] 选择剑士开局")
			main.hud.start_selected.emit("fencer")
		1:   # PLAY
			_play_tick()
		2:   # SETTLE
			_finish()
		_:
			pass


func _play_tick() -> void:
	var p: ArpgPlayer = main.player
	if p == null or not is_instance_valid(p) or p.dead:
		return
	# 100 秒没打完就主动撤退，保证测试收敛到结算
	if _elapsed > retreat_at:
		print("[AUTOPLAY] 达到时限，主动撤退结算")
		main.hud.retreat_requested.emit()
		return
	# 重伤必喝药；开局 25s 强制喝一瓶覆盖药水路径
	var potions := _potion_count()
	if p.hp < p.max_hp * 0.35 and potions > 0:
		_tap("potion")
		print("[AUTOPLAY] 重伤喝药（HP %d/%d，剩 %d 瓶）" % [p.hp, p.max_hp, potions])
		return
	if _elapsed > 25.0 and not _potion_tested:
		_potion_tested = true
		if potions > 0:
			_tap("potion")
			print("[AUTOPLAY] 定期喝药覆盖路径（剩 %d 瓶）" % (potions - 1))
			return

	# 交互优先：贴身宝箱 / 传送门 / 楼梯
	var chest: ArpgChest = _nearest_chest(p)
	if chest != null and p.position.distance_to(chest.position) < 44.0:
		_stop()
		_tap("interact")
		print("[AUTOPLAY] 开箱")
		return
	if main.world.portal_cell.x >= 0 and main.world.portal_dist(p.position) < 46.0:
		_stop()
		_tap("interact")
		print("[AUTOPLAY] 进入传送门凯旋")
		return
	if main.world.stairs_cell.x >= 0 and _stairs_dist(p) < 40.0:
		_stop()
		_tap("interact")
		print("[AUTOPLAY] 下楼（当前第 %d 层）" % main.floor_no)
		return

	# 战斗：进入真实攻击距离才平A（阈值=攻击距离+敌人半径，防止站着打空），技能好了就放
	var mi := _nearest_mob(p)
	if mi >= 0:
		var d: float = p.position.distance_to(main.world.mobs.pos[mi])
		if d <= p.atk_range + main.world.mobs.radius[mi] + 2.0:
			_stop()
			_tap("attack")
			_skill_t -= THINK
			if _skill_t <= 0.0 and p.skill_cd <= 0.0 and p.sp >= int(p.tpl["skill"]["sp"]):
				_skill_t = 6.0
				_tap("skill")
				print("[AUTOPLAY] 放技能「%s」" % p.tpl["skill"]["name"])
			return
		_move_towards(p, main.world.mobs.pos[mi])
		return

	# 场上无敌人：走向宝箱 / 传送门 / 楼梯
	var goal := Vector2.ZERO
	if chest != null:
		goal = chest.position
	elif main.world.portal_cell.x >= 0:
		goal = ArpgDungeon.cell_to_pos(main.world.portal_cell)
	elif main.world.stairs_cell.x >= 0:
		goal = ArpgDungeon.cell_to_pos(main.world.stairs_cell)
	else:
		_stop()
		return
	_move_towards(p, goal)


# ———————— 移动 / 按键 ————————

## A* 寻路：地牢每层重建一次；目标格在墙里时自动找最近的可走格
func _ensure_astar() -> void:
	if _astar_ready and _astar_floor == main.floor_no:
		return
	var d: ArpgDungeon = main.dungeon
	_astar.size = Vector2i(d.w, d.h)
	_astar.cell_size = Vector2(ArpgData.TILE, ArpgData.TILE)
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.update()
	for x in d.w:
		for y in d.h:
			if d.grid[x][y] != ArpgDungeon.FLOOR:
				_astar.set_point_solid(Vector2i(x, y))
	_astar_ready = true
	_astar_floor = main.floor_no


func _nearest_open(c: Vector2i) -> Vector2i:
	if not _astar.is_point_solid(c):
		return c
	for r in range(1, 7):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var n := c + Vector2i(dx, dy)
				if n.x >= 0 and n.y >= 0 and n.x < main.dungeon.w and n.y < main.dungeon.h \
						and not _astar.is_point_solid(n):
					return n
	return c


func _move_towards(p: ArpgPlayer, goal: Vector2) -> void:
	_ensure_astar()
	var a := _nearest_open(Vector2i((p.position / float(ArpgData.TILE)).floor()))
	var b := _nearest_open(Vector2i((goal / float(ArpgData.TILE)).floor()))
	var pts := _astar.get_id_path(a, b)
	# 取第一个离玩家 >26px 的路点（跳过脚下格）
	var waypoint := goal
	for i in pts.size():
		var wp := ArpgDungeon.cell_to_pos(pts[i])
		if p.position.distance_to(wp) > 26.0:
			waypoint = wp
			break
	# 目标就在眼前【且直线无墙】→ 直接朝它走（隔墙时必须老老实实绕路）
	if p.position.distance_to(goal) < 90.0 and _line_clear(p.position, goal):
		waypoint = goal
	var dir := waypoint - p.position
	if dir.length() < 10.0:
		_stop()
		_last_pos = p.position
		return
	_press_dir(dir.normalized())
	# 卡墙兜底：想动但没挪 → 垂直绕一拍
	if p.position.distance_to(_last_pos) < 3.0:
		_stuck += THINK
		if _stuck > 0.9:
			_press_dir(dir.normalized().rotated(PI / 2.0))
			_stuck = 0.6
	else:
		_stuck = 0.0
	_last_pos = p.position


## 直线视野检测：每 8px 采样一次，全部落在地板上才算无遮挡
func _line_clear(a: Vector2, b: Vector2) -> bool:
	var d := b - a
	var steps := int(d.length() / 8.0) + 1
	for i in steps + 1:
		var q := a + d * (float(i) / steps)
		if not main.dungeon.is_floor(Vector2i((q / float(ArpgData.TILE)).floor())):
			return false
	return true


func _press_dir(dir: Vector2) -> void:
	for a in ["move_left", "move_right", "move_up", "move_down"]:
		if _pressed.has(a):
			Input.action_release(a)
			_pressed.erase(a)
	if dir.x < -0.3:
		_pressed["move_left"] = true
	elif dir.x > 0.3:
		_pressed["move_right"] = true
	if dir.y < -0.3:
		_pressed["move_up"] = true
	elif dir.y > 0.3:
		_pressed["move_down"] = true
	for a in _pressed:
		Input.action_press(a)


func _stop() -> void:
	for a in _pressed:
		Input.action_release(a)
	_pressed.clear()


func _tap(action: String) -> void:
	Input.action_press(action)
	_taps.append(action)


# ———————— 查询 ————————

func _nearest_mob(p: ArpgPlayer) -> int:
	return main.world.mobs.nearest(p.position)


func _nearest_chest(p: ArpgPlayer) -> ArpgChest:
	var best: ArpgChest = null
	var bd := INF
	for c in main.world.chests:
		if not is_instance_valid(c) or c.opened:
			continue
		var d: float = c.position.distance_to(p.position)
		if d < bd:
			bd = d
			best = c
	return best


func _stairs_dist(p: ArpgPlayer) -> float:
	if main.world.stairs_cell.x < 0:
		return INF
	return ArpgDungeon.cell_to_pos(main.world.stairs_cell).distance_to(p.position)


func _potion_count() -> int:
	return main.rpg.inventory.count("potion")


# ———————— 收官 ————————

func _finish() -> void:
	done = true
	_stop()
	var lv := 1
	if is_instance_valid(main.player):
		lv = main.player.level
	print("[AUTOPLAY] 结算：击杀 %d · 到达地下 %d 层 · Lv %d · 背包 %d 格" % [
		main.kills, main.floor_no, lv, main.rpg.inventory.used()])
	if main.kills >= 2 or main.floor_no >= 2:
		print("[AUTOPLAY] PASS")
		get_tree().quit(0)
	else:
		_fail("击杀数与楼层均不达标（疑似手感/数值回归）")


func _fail(reason: String) -> void:
	done = true
	print("[AUTOPLAY] FAIL：%s" % reason)
	get_tree().quit(1)
