extends SceneTree
## 无头冒烟测试：godot --headless -s res://tests/smoke.gd
## 覆盖：地图加载器 / JSON 往返（并生成 map001.json）/ 编辑器操作 / 游戏主场景 / 事件系统

var _failed := false


func _initialize() -> void:
	_run()


func _run() -> void:
	print("== 1. 地图加载器 ==")
	var d := SrpgMapLoader.default_map_dict()
	_check(int(d["width"]) == SrpgData.MAP_W and int(d["height"]) == SrpgData.MAP_H, "默认图尺寸")
	_check(d["placements"].size() == SrpgData.PLACEMENTS.size(), "默认单位数 %d" % d["placements"].size())

	print("== 2. JSON 往返（生成 map001.json） ==")
	var ok: bool = SrpgMapLoader.save_file(SrpgMapLoader.PATH, d)
	_check(ok, "保存 map001.json")
	var d2 := SrpgMapLoader.load_file(SrpgMapLoader.PATH)
	_check(not d2.is_empty() and int(d2["width"]) == 20, "读回 JSON")
	_check(d2["events"].size() == 2, "随图事件数量 2")

	var terra := []
	for x in int(d2["width"]):
		var col := []
		col.resize(int(d2["height"]))
		col.fill(SrpgData.Terrain.GRASS)
		terra.append(col)
	for y in int(d2["height"]):
		var row: String = d2["rows"][y]
		for x in int(d2["width"]):
			terra[x][y] = SrpgMapLoader.CHARS.get(row[x], SrpgData.Terrain.GRASS)
	var anchors := SrpgMapLoader.mountain_anchors_from(terra, int(d2["width"]), int(d2["height"]))
	_check(anchors.size() == SrpgData.MOUNTAINS.size(), "山块锚点 %d == %d" % [anchors.size(), SrpgData.MOUNTAINS.size()])
	_check(terra[3][2] == SrpgData.Terrain.FOREST, "森林解码")
	_check(int(SrpgData.TERRAIN[terra[0][0]]["cost"]) > 90, "山不可通行")

	print("== 3. 编辑器 ==")
	var esc: PackedScene = load("res://editor/editor.tscn")
	_check(esc != null, "editor.tscn 加载")
	var ed: Node = esc.instantiate()
	root.add_child(ed)
	await process_frame
	_check(int(ed.gw) == 20 and ed.placements.size() == 7, "编辑器载入地图")
	ed._paint_stroke(Vector2i(5, 5))
	_check(ed.grid[5][5] == SrpgData.Terrain.FOREST, "涂刷森林")
	ed.brush = SrpgData.Terrain.MOUNTAIN
	ed._paint_stroke(Vector2i(0, 0))
	_check(ed.grid[0][0] == SrpgData.Terrain.MOUNTAIN and ed.grid[1][1] == SrpgData.Terrain.MOUNTAIN, "山 2x2 盖章")
	ed._erase_mountain(Vector2i(1, 1))
	_check(ed.grid[0][0] == SrpgData.Terrain.GRASS and ed.grid[1][1] == SrpgData.Terrain.GRASS, "擦除整块山")
	ed._place_unit("orc", Vector2i(6, 5))
	_check(ed._unit_at(Vector2i(6, 5)) >= 0, "放置单位")
	ed._paint_stroke(Vector2i(18, 12))   # 再盖一座山用于拒绝测试
	ed._place_unit("orc", Vector2i(18, 12))
	_check(ed._unit_at(Vector2i(18, 12)) == -1, "山上不能放单位")
	ed._add_event()
	_check(ed.events.size() == 3, "新建事件")
	ed._select_event(2)
	await process_frame
	var saved: Dictionary = ed.build_dict()
	_check(saved["placements"].size() == 8, "build_dict 含新单位")
	_check(saved["events"][2]["trigger"]["type"] == "turn_start", "新事件默认触发器")
	ed._resize(18, 12)
	_check(int(ed.gw) == 18 and ed.placements.size() >= 7, "调整地图尺寸")
	ed.queue_free()
	await process_frame

	print("== 4. 游戏主场景（读 JSON） ==")
	var ps: PackedScene = load("res://srpg/main.tscn")
	_check(ps != null, "main.tscn 加载")
	var main: Node = ps.instantiate()
	root.add_child(main)
	for i in 5:
		await process_frame
	_check(main.units.size() == 7, "游戏按 JSON 生成 7 个单位")
	_check(main.map_events.size() == 2, "游戏读入 2 个事件")

	print("== 5. 事件系统 ==")
	await create_timer(2.3).timeout
	_check(bool(main.ui.dlg_active), "第1回合开场对话自动弹出")
	var tries := 0
	while bool(main.ui.dlg_active) and tries < 8:
		main.ui._dlg_adv = true
		await create_timer(0.35).timeout
		tries += 1
	_check(not bool(main.ui.dlg_active), "对话全部推进后关闭")
	main.map_events.append({
		"name": "区域测试", "trigger": {"type": "zone", "rect": [2, 7, 1, 1], "faction": "player"},
		"once": true, "condition": {},
		"commands": [{"cmd": "set_flag", "flag": "zone_ok", "value": true}],
	})
	await main.events.on_unit_moved(main.units[0])
	_check(bool(main.flags.get("zone_ok", false)), "进入区域事件触发旗标")
	var n0: int = main.units.size()
	main.spawn_units("orc", [[19, 0]])
	_check(main.units.size() == n0 + 1, "中途增援生效")

	var map: SrpgBattleMap = main.map
	var reach: Dictionary = map.reachable(Vector2i(2, 7), 5, {})
	_check(reach.size() >= 10, "寻路可达范围（%d 格）" % reach.size())
	var dmg: int = map.calc_damage(main.units[0], main.units[3])
	_check(dmg == 3, "伤害公式（森林+1）= 3（实际 %d）" % dmg)
	var plan: Dictionary = SrpgEnemyAI.plan(main.units[3], map, main.units)
	_check(plan.has("cell"), "AI 出规划")

	if _failed:
		quit(1)
	else:
		print("SMOKE PASS")
		quit(0)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok  " + msg)
	else:
		_failed = true
		print("  FAIL  " + msg)


func _fail(msg: String) -> void:
	_failed = true
	print("  FAIL  " + msg)
