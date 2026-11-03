extends SceneTree
## 创作器冒烟：headless 真实实例化 Workspace（插件宿主在编辑器导入时也会这么干），
## 逐个路由左树节点，验证四区布局与各页面工厂不抛错。
## 运行：Godot --headless --path . -s res://tests/smoke_creator.gd

var _fails := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		_fails += 1
		printerr("  ✗ ", msg)


func _initialize() -> void:
	_watchdog()
	_run()


func _watchdog() -> void:
	await create_timer(30.0).timeout
	print("WATCHDOG TIMEOUT")
	quit(2)


func _run() -> void:
	print("== smoke_creator ==")
	var ws = load("res://creator/core/workspace.gd").new()
	root.add_child(ws)
	# -s 模式下 _ready 在下一帧才触发：等两帧再断言
	await process_frame
	await process_frame
	_check(ws.balance.size() > 0, "balance.json 已加载")
	_check(ws.map_data.has("events"), "map 事件已加载")
	_check(ws._tree.get_root() != null, "左树已构建")
	_check(ws._center.get_child_count() > 0, "中央有内容（总览）")
	_check(ws._strip_body.get_child_count() > 0, "底部事件条已挂内容")

	# 逐类路由（含所有数据库实体类型）
	var kinds := [
		{"kind": "char", "id": "fencer", "idx": -1},
		{"kind": "char", "id": "archer", "idx": -1},
		{"kind": "enemy", "id": "imp", "idx": -1},
		{"kind": "boss", "id": "boss", "idx": -1},
		{"kind": "item", "id": "potion", "idx": -1},
		{"kind": "equipment", "id": "short_sword", "idx": -1},
		{"kind": "skill", "id": "whirl", "idx": -1},
		{"kind": "quest", "id": "q_slime", "idx": -1},
		{"kind": "param", "id": "ai", "idx": -1},
		{"kind": "param", "id": "camera", "idx": -1},
		{"kind": "floor", "id": "", "idx": 1},
		{"kind": "floor", "id": "", "idx": 5},
		{"kind": "scene", "id": "scene001", "idx": -1},
	]
	var events: Array = ws.map_data.get("events", [])
	for i in events.size():
		kinds.append({"kind": "event", "id": "", "idx": i})
	for sel in kinds:
		ws._route(sel)
		_check(ws._center.get_child_count() > 0,
			"路由 %s/%s/%s 中央非空" % [sel.kind, sel.id, sel.idx])

	# 事件画布 + 列表选择同步
	if events.size() > 0:
		ws._route({"kind": "event", "id": "", "idx": 0})
		var cv = ws._ev.flow_canvas()
		_check(cv != null, "事件画布已创建")
		cv.sel_path = [0]
		cv.queue_redraw()
		ws._ev.select_event(0)
		_check(ws._right_box.get_child_count() > 0, "事件属性面板非空")

	# 左树结构：事件节点数必须与 map events 一致（防运行时静默失败，如 API 改名）
	var ev_items := 0
	var stack2: Array = [ws._tree.get_root()]
	while not stack2.is_empty():
		var it: TreeItem = stack2.pop_back()
		if it == null:
			continue
		var m: Variant = it.get_metadata(0)
		if m is Dictionary and str(m.get("kind", "")) == "event":
			ev_items += 1
		var ch: TreeItem = it.get_first_child()
		while ch != null:
			stack2.append(ch)
			ch = ch.get_next()
	_check(ev_items == events.size(), "左树事件节点数 = %d" % events.size())

	# 只读校验（红线：冒烟测试不写盘——写盘会重排 data/*.json 的格式并生成备份）
	var e1: String = load("res://creator/core/data_store.gd").validate("balance", ws.balance)
	var e2: String = load("res://creator/core/data_store.gd").validate("map", ws.map_data)
	_check(e1 == "", "balance 结构校验通过")
	_check(e2 == "", "map 结构校验通过")

	if _fails == 0:
		print("== smoke_creator PASS ==")
	else:
		printerr("== smoke_creator FAIL: %d ==" % _fails)
	quit(1 if _fails > 0 else 0)
