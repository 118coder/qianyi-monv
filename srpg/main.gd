extends Node2D
## 「千亿魔女」战旗主控：输入处理、回合流转、战斗结算、AI 调度、事件引擎调度。
## 地图 / 单位 / 事件全部来自 res://data/maps/map001.json（编辑器产出），无文件时用内置演示图。
## 架构借鉴：GDQuest 2D tactical movement（MIT）、ramaureirac godot-tactical-rpg（MIT）。

enum State { IDLE, SELECTED, MENU, TARGET, BUSY, ENEMY, OVER }

const SFX := {
	"cursor": preload("res://assets/se/Cursor1.ogg"),
	"attack": preload("res://assets/se/Attack2.ogg"),
	"damage": preload("res://assets/se/Damage1.ogg"),
	"die": preload("res://assets/se/Collapse3.ogg"),
	"heal": preload("res://assets/se/Heal1.ogg"),
}

var map: SrpgBattleMap
var units_root: Node2D
var cam: Camera2D
var ui: SrpgGameUI
var events: SrpgEventSystem
var units := []

var state := State.IDLE
var turn := 1
var map_name := ""
var map_events := []                 # 事件列表（来自地图 JSON）
var flags := {}                      # 事件旗标（本次对局内有效）
var win_cond := {"type": "rout"}     # rout=歼灭全敌 / boss=击败指定 uid
var dead_uids := {}
var over := false

var selected: SrpgUnit = null
var reach := {}                      # 选中单位的可达格（Dijkstra 结果）
var origin_cell := Vector2i.ZERO     # 移动前位置，用于「取消」回退
var target_mode := "attack"          # attack / heal
var targets := []                    # TARGET 状态下的合法目标
var hover_cell := Vector2i(-1, -1)
var _spawn_counter := 0


func _ready() -> void:
	var mdict: Dictionary = SrpgMapLoader.load_file(SrpgMapLoader.PATH)
	if mdict.is_empty():
		mdict = SrpgMapLoader.default_map_dict()
	map_name = str(mdict.get("name", ""))

	map = SrpgBattleMap.new()
	add_child(map)
	map.build_from(mdict)

	units_root = Node2D.new()
	units_root.y_sort_enabled = true
	add_child(units_root)
	for p in mdict.get("placements", []):
		var tpl_id: String = str(p.get("tpl", ""))
		if not SrpgData.UNITS.has(tpl_id):
			push_warning("未知单位模板: " + tpl_id)
			continue
		var cell := Vector2i(int(p["cell"][0]), int(p["cell"][1]))
		var u := SrpgUnit.new()
		u.setup(str(p.get("uid", tpl_id)), tpl_id, SrpgData.UNITS[tpl_id], cell)
		units_root.add_child(u)
		units.append(u)

	win_cond = mdict.get("win", {"type": "rout"})
	map_events = mdict.get("events", [])
	for i in map_events.size():
		map_events[i]["_idx"] = i
	events = SrpgEventSystem.new(self)

	cam = Camera2D.new()
	var map_px := Vector2(map.w, map.h) * SrpgData.TILE
	cam.position = map_px / 2.0
	var vp := get_viewport_rect().size
	var z := minf(vp.x / (map_px.x + 100), vp.y / (map_px.y + 100))
	cam.zoom = Vector2.ONE * clampf(z, 0.5, 4.0)
	add_child(cam)
	cam.make_current()

	ui = SrpgGameUI.new()
	add_child(ui)
	ui.action_chosen.connect(_on_action_chosen)
	ui.restart_requested.connect(_restart)
	ui.editor_requested.connect(_back_to_editor)
	ui.update_turn(turn, "玩家回合")
	_intro()


func _intro() -> void:
	await get_tree().create_timer(0.3).timeout
	await ui.show_banner("第 %d 回合 · 玩家行动" % turn, Color(0.16, 0.32, 0.65))
	await events.on_phase_start("player", turn)


func _process(_delta: float) -> void:
	var c := SrpgBattleMap.pos_to_cell(get_global_mouse_position())
	if c != hover_cell:
		hover_cell = c
		_on_hover(c)


func _on_hover(c: Vector2i) -> void:
	map.hover_cell = c
	var desc := _terrain_desc(c) if map.in_bounds(c) else ""
	match state:
		State.IDLE:
			var u := _unit_at(c)
			if u != null and u.faction == "enemy":
				_show_danger(u)
			else:
				map.danger_cells = []
			ui.update_info(u, desc)
			map.path_cells = []
		State.SELECTED:
			map.path_cells = map.path_from(reach, c) if reach.has(c) else []
			var u2 := _unit_at(c)
			if u2 != null:
				ui.update_info(u2, desc)
			else:
				ui.update_info(selected, desc)
		State.TARGET:
			var t := _unit_at(c)
			if t != null and t in targets:
				_show_forecast(selected, t)
			else:
				ui.hide_forecast()
	map.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if over or ui.dlg_active or state == State.ENEMY:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_click(SrpgBattleMap.pos_to_cell(get_global_mouse_position()))
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_cancel()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				_cancel()
			KEY_ENTER, KEY_KP_ENTER:
				if state == State.IDLE:
					_end_player_turn()


# ———————— 玩家输入 ————————

func _click(c: Vector2i) -> void:
	if not map.in_bounds(c):
		return
	match state:
		State.IDLE:
			var u := _unit_at(c)
			if u != null and u.faction == "player" and not u.acted:
				_select(u)
			elif u != null:
				_play_sfx("cursor")
		State.SELECTED:
			if reach.has(c):
				_do_move(c)
			elif c == origin_cell:
				_open_menu()
			else:
				var u2 := _unit_at(c)
				if u2 != null and u2.faction == "player" and not u2.acted:
					_select(u2)
				else:
					_deselect()
		State.TARGET:
			var t := _unit_at(c)
			if t != null and t in targets:
				if target_mode == "attack":
					_player_attack(t)
				else:
					_player_heal(t)


func _cancel() -> void:
	match state:
		State.SELECTED:
			_deselect()
		State.MENU:
			_undo_move()
		State.TARGET:
			_open_menu()


func _select(u: SrpgUnit) -> void:
	if selected != null:
		selected.set_selected(false)
	selected = u
	u.set_selected(true)
	origin_cell = u.cell
	reach = map.reachable(u.cell, u.mov, _occupied_except(u))
	map.move_cells = reach.keys() + [u.cell]
	var atk := {}
	for c in map.cells_in_range(u.cell, u.rmin, u.rmax):
		if not reach.has(c) and c != u.cell:
			atk[c] = true
	map.attack_cells = atk.keys()
	map.danger_cells = []
	map.path_cells = []
	_play_sfx("cursor")
	state = State.SELECTED
	map.queue_redraw()


func _deselect() -> void:
	if selected != null:
		selected.set_selected(false)
	selected = null
	reach = {}
	targets = []
	_clear_highlights()
	ui.hide_forecast()
	ui.hide_menu()
	state = State.IDLE


func _do_move(dest: Vector2i) -> void:
	state = State.BUSY
	var path := map.path_from(reach, dest)
	map.move_cells = []
	map.attack_cells = []
	map.path_cells = []
	map.queue_redraw()
	var points := []
	for pcell in path:
		points.append(SrpgBattleMap.cell_to_pos(pcell))
	if not points.is_empty():
		await selected.walk_to(points)
	await events.on_unit_moved(selected)   # 进入区域类事件
	if not over:
		_open_menu()


func _open_menu() -> void:
	state = State.MENU
	var actions := []
	if not _targets_for(selected, "attack").is_empty():
		actions.append("攻击")
	if selected.heal_power > 0 and not _targets_for(selected, "heal").is_empty():
		actions.append("治疗")
	actions.append("待机")
	actions.append("取消")
	ui.show_menu(selected, actions)


func _undo_move() -> void:
	if selected == null:
		_deselect()
		return
	selected.position = SrpgBattleMap.cell_to_pos(origin_cell)
	selected.cell = origin_cell
	ui.hide_forecast()
	_clear_highlights()
	_select(selected)   # 重新选中，恢复范围显示


func _on_action_chosen(action: String) -> void:
	ui.hide_menu()
	match action:
		"攻击":
			_enter_target("attack")
		"治疗":
			_enter_target("heal")
		"待机":
			_finish_unit()
		"取消":
			_undo_move()


# ———————— 行动执行 ————————

func _enter_target(mode: String) -> void:
	target_mode = mode
	targets = _targets_for(selected, mode)
	if targets.is_empty():
		_finish_unit()
		return
	state = State.TARGET
	map.move_cells = []
	map.attack_cells = []
	map.path_cells = []
	map.target_is_heal = mode == "heal"
	var tcells := {}
	for t in targets:
		tcells[t.cell] = true
	map.target_cells = tcells.keys()
	map.queue_redraw()


func _player_attack(t: SrpgUnit) -> void:
	state = State.BUSY
	map.target_cells = []
	map.queue_redraw()
	ui.hide_forecast()
	await _attack(selected, t)
	if not over:
		_finish_unit()


func _player_heal(t: SrpgUnit) -> void:
	state = State.BUSY
	map.target_cells = []
	map.queue_redraw()
	_play_sfx("heal")
	t.heal_by(selected.heal_power)
	t.flash(Color(0.5, 1.0, 0.55))
	_popup("+%d" % selected.heal_power, t.position, Color(0.5, 1.0, 0.55))
	await get_tree().create_timer(0.35).timeout
	if not over:
		_finish_unit()


## 一次完整交手：攻击 → （目标存活且在射程内）反击
func _attack(a: SrpgUnit, d: SrpgUnit) -> void:
	var dmg := map.calc_damage(a, d)
	a.face_towards(SrpgBattleMap.cell_to_pos(d.cell))
	_play_sfx("attack")
	await a.lunge(SrpgBattleMap.cell_to_pos(d.cell))
	d.take_damage(dmg)
	d.flash(Color(1, 0.45, 0.4))
	_play_sfx("damage")
	_popup("-%d" % dmg, d.position, Color(1, 0.5, 0.4))
	await get_tree().create_timer(0.28).timeout
	if d.hp <= 0:
		await _kill(d)
		return
	var dist := map.manhattan(a.cell, d.cell)
	if dist >= d.rmin and dist <= d.rmax:
		var cdmg := map.calc_damage(d, a)
		d.face_towards(a.position)
		_play_sfx("attack")
		await d.lunge(a.position)
		a.take_damage(cdmg)
		a.flash(Color(1, 0.45, 0.4))
		_play_sfx("damage")
		_popup("-%d" % cdmg, a.position, Color(1, 0.5, 0.4))
		await get_tree().create_timer(0.28).timeout
		if a.hp <= 0:
			await _kill(a)


func _kill(u: SrpgUnit) -> void:
	_play_sfx("die")
	units.erase(u)
	ui.update_info(null, "")
	await u.die()
	u.queue_free()
	dead_uids[u.uid] = true
	await events.on_unit_dead(u)   # 死亡触发的事件（如头目败北台词）
	_check_win()


func _finish_unit() -> void:
	if selected != null:
		selected.set_selected(false)
		selected.set_acted(true)
	selected = null
	reach = {}
	targets = []
	_clear_highlights()
	ui.hide_forecast()
	ui.hide_menu()
	state = State.IDLE
	_check_win()


func _check_win() -> void:
	if over:
		return
	if str(win_cond.get("type", "rout")) == "boss" and dead_uids.has(str(win_cond.get("uid", ""))):
		_game_over(true)
		return
	if _alive_of("enemy").is_empty():
		_game_over(true)
	elif _alive_of("player").is_empty():
		_game_over(false)


func _game_over(win: bool) -> void:
	over = true
	state = State.OVER
	_clear_highlights()
	ui.show_result(win)


## 事件命令：中途增援
func spawn_units(tpl_id: String, cells: Array) -> void:
	var tpl: Dictionary = SrpgData.UNITS.get(tpl_id, {})
	if tpl.is_empty():
		return
	var n := 0
	for c in cells:
		var cell := Vector2i(int(c[0]), int(c[1]))
		if not map.in_bounds(cell) or _unit_at(cell) != null:
			continue
		var u := SrpgUnit.new()
		_spawn_counter += 1
		u.setup("spawn_%d" % _spawn_counter, tpl_id, tpl, cell)
		units_root.add_child(u)
		units.append(u)
		u.flash(Color(0.65, 0.9, 1.0))
		_popup("增援！", SrpgBattleMap.cell_to_pos(cell), Color(1, 0.85, 0.4))
		n += 1
	if n > 0:
		_play_sfx("cursor")


# ———————— 回合流转 ————————

func _end_player_turn() -> void:
	_deselect()
	state = State.ENEMY
	ui.update_turn(turn, "敌方回合")
	await ui.show_banner("敌方回合", Color(0.62, 0.2, 0.16))
	await events.on_phase_start("enemy", turn)   # 敌方回合开始的事件
	if over:
		return
	for e in _alive_of("enemy"):
		if over:
			return
		if not is_instance_valid(e) or e.hp <= 0:
			continue
		var plan: Dictionary = SrpgEnemyAI.plan(e, map, units)
		if plan["wait"]:
			await get_tree().create_timer(0.15).timeout
			continue
		var points := []
		for pcell in plan["path"]:
			points.append(SrpgBattleMap.cell_to_pos(pcell))
		if not points.is_empty():
			await e.walk_to(points)
		else:
			e.cell = plan["cell"]
		await events.on_unit_moved(e)   # 敌人也可能踩进区域事件
		if over:
			return
		await get_tree().create_timer(0.18).timeout
		var t = plan["target"]
		if t != null and is_instance_valid(t) and t.hp > 0:
			await _attack(e, t)
			if over:
				return
		await get_tree().create_timer(0.2).timeout
	turn += 1
	for u in units:
		if is_instance_valid(u):
			u.set_acted(false)
	ui.update_turn(turn, "玩家回合")
	state = State.IDLE
	await ui.show_banner("第 %d 回合 · 玩家行动" % turn, Color(0.16, 0.32, 0.65))
	await events.on_phase_start("player", turn)


# ———————— 辅助 ————————

func _unit_at(c: Vector2i) -> SrpgUnit:
	for u in units:
		if is_instance_valid(u) and u.cell == c:
			return u
	return null


func _occupied_except(u: SrpgUnit) -> Dictionary:
	var occ := {}
	for o in units:
		if o != u:
			occ[o.cell] = true
	return occ


## 射程内可攻击 / 可治疗的单位列表
func _targets_for(u: SrpgUnit, mode: String) -> Array:
	var out := []
	for o in units:
		if o == u or not is_instance_valid(o):
			continue
		var d := map.manhattan(u.cell, o.cell)
		if mode == "attack":
			if o.faction != u.faction and d >= u.rmin and d <= u.rmax:
				out.append(o)
		elif o.faction == u.faction and o.hp < o.max_hp and d >= u.rmin and d <= u.rmax:
			out.append(o)
	return out


## 敌方单位悬停时的危险区（它的可移动格 + 由此能打到的格）
func _show_danger(u: SrpgUnit) -> void:
	var r := map.reachable(u.cell, u.mov, _occupied_except(u))
	var cells := {u.cell: true}
	for cc in r:
		cells[cc] = true
		for rc in map.cells_in_range(cc, u.rmin, u.rmax):
			cells[rc] = true
	map.danger_cells = cells.keys()


func _show_forecast(a: SrpgUnit, d: SrpgUnit) -> void:
	var dmg := map.calc_damage(a, d)
	var dist := map.manhattan(a.cell, d.cell)
	var counter := 0
	if dist >= d.rmin and dist <= d.rmax:
		counter = map.calc_damage(d, a)
	ui.show_forecast(a, d, dmg, counter, dmg >= d.hp)


func _terrain_desc(c: Vector2i) -> String:
	if map.move_cost(c) > 90:
		return map.terrain_name(c) + "（不可通行）"
	return "%s（防+%d）" % [map.terrain_name(c), map.terrain_def(c)]


func _alive_of(faction: String) -> Array:
	var out := []
	for u in units:
		if is_instance_valid(u) and u.faction == faction:
			out.append(u)
	return out


func _clear_highlights() -> void:
	map.move_cells = []
	map.attack_cells = []
	map.danger_cells = []
	map.path_cells = []
	map.target_cells = []
	map.queue_redraw()


func _popup(text: String, world_pos: Vector2, col: Color) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 4)
	l.position = world_pos + Vector2(-14, -42)
	l.z_index = 60
	units_root.add_child(l)
	var tw := l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position:y", l.position.y - 26.0, 0.7)
	tw.tween_property(l, "modulate:a", 0.0, 0.45).set_delay(0.25)
	tw.chain().tween_callback(l.queue_free)


func _play_sfx(sname: String) -> void:
	var p := AudioStreamPlayer.new()
	p.stream = SFX[sname]
	p.volume_db = -6.0
	add_child(p)
	p.play()
	p.finished.connect(p.queue_free)


func _restart() -> void:
	get_tree().reload_current_scene()


func _back_to_editor() -> void:
	get_tree().change_scene_to_file("res://editor/editor.tscn")
