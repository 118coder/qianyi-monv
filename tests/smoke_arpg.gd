extends SceneTree
## ARPG 无头冒烟测试：godot --headless -s res://tests/smoke_arpg.gd
## 覆盖：地牢生成 / 角色启动 / 数据系统战斗 / 升级回满 / 宝箱陷阱 / 楼层推进 / Boss / 结算 / 压测

var _failed := false


func _initialize() -> void:
	_watchdog()
	_run()


func _watchdog() -> void:
	await create_timer(40.0).timeout
	print("WATCHDOG TIMEOUT")
	quit(2)


func _run() -> void:
	print("== 1. 地牢生成 ==")
	for f in [1, 3, 5]:
		var d := ArpgDungeon.new()
		d.generate(f, 12345)
		_check(d.rooms.size() >= (1 if d.boss_floor else 5), "第 %d 层房间数 %d" % [f, d.rooms.size()])
		_check(d.is_floor(d.start_cell), "出发格可走")
	var arena := ArpgDungeon.new()
	arena.generate_arena(170, 120)
	_check(arena.floor_cells().size() > 15000, "斗兽场地板格 %d" % arena.floor_cells().size())

	print("== 2. 启动对局 ==")
	var ps: PackedScene = load("res://arpg/main.tscn")
	_check(ps != null, "main.tscn 加载")
	var main: Node = ps.instantiate()
	root.add_child(main)
	for i in 5:
		await process_frame
	_check(main.hud.select_root.visible, "角色选择画面显示")
	main.start_run("witch")
	await process_frame
	_check(main.state == main.State.PLAY, "进入 PLAY")
	_check(main.world.mob_count() >= 5, "第 1 层敌人数 %d" % main.world.mob_count())
	_check(main.world.chests.size() == 2, "宝箱 ×2")
	_check(main.bag.size() == 3, "初始药水 ×3")

	print("== 3. 数据系统战斗 ==")
	var player: ArpgPlayer = main.player
	var i0: int = main.world.mobs.nearest(player.position)
	_check(i0 >= 0, "能查询到敌人")
	var hp0: int = main.world.mobs.hp[i0]
	main.world.damage_mob(i0, 8, player.position)
	_check(main.world.mobs.hp[i0] < hp0 or main.world.mobs.hp[i0] <= 0, "敌人受扣血")
	var xp0: int = player.xp
	var kills0: int = main.kills
	main.world.damage_mob(i0, 99999, player.position)
	await create_timer(0.5).timeout
	_check(player.xp > xp0 or player.level > 1, "击杀获得经验")
	_check(main.kills == kills0 + 1, "击杀计数")
	var lv0: int = player.level
	player.gain_xp(ArpgBalance.xp_need(player.level))
	_check(player.level == lv0 + 1, "升级")
	_check(player.hp == player.max_hp and player.sp == player.max_sp, "升级完全回满")
	var hp1: int = player.hp
	player.take_damage(5, player.position + Vector2(10, 0))
	_check(player.hp == hp1 - 5, "玩家受击扣血")
	player.take_damage(5, player.position + Vector2(10, 0))
	_check(player.hp == hp1 - 5, "无敌帧内不再扣血")
	# 扇形查询
	var arc: PackedInt32Array = main.world.mobs_in_arc(player.position, Vector2.RIGHT.angle(), 200.0)
	print("  弧形查询命中 %d 个" % arc.size())

	print("== 4. 背包 / 药水 / 宝箱 ==")
	var bag0: int = main.bag.size()
	main.try_pickup("herb")
	_check(main.bag.size() == bag0 + 1, "拾取入包")
	for i in 30:
		main.try_pickup("ore")
	_check(main.bag.size() == ArpgBalance.BAG_CAP, "背包上限 20")
	main.bag_full_warn()
	var hp2: int = player.hp
	player.take_damage(30, player.position + Vector2(10, 0))
	main.drink_potion()
	_check(player.hp > hp2 - 30, "药水回血生效")
	main.open_chest(main.world.chests[0])
	await process_frame
	_check(main.world.chests[0].opened, "宝箱可开启")

	print("== 5. 楼层推进 / Boss / 结算 ==")
	main.floor_no = 5
	main.build_floor()
	await process_frame
	var boss_i: int = main.world.mobs.find_boss()
	_check(boss_i >= 0, "第 5 层有 Boss")
	if boss_i >= 0:
		main.world.damage_mob(boss_i, 99999, main.player.position)
		await create_timer(0.8).timeout
	_check(main.world.portal_cell.x >= 0, "Boss 死后出现传送门")
	main._settle(true, "测试凯旋", "flavor")
	_check(main.state == main.State.SETTLE, "结算画面状态")
	_check(main.hud.settle_root.visible, "结算画面显示")

	print("== 6. 压测管线 ==")
	main._stress_n = 300
	main.build_floor()
	await process_frame
	_check(main.world.mob_count() >= 250, "压测刷怪 %d" % main.world.mob_count())
	for i in 20:
		await process_frame
	_check(main.world.mobs.sim_ms < 16.0, "万级模拟单帧耗时 %.2fms < 16ms" % main.world.mobs.sim_ms)
	main._stress_n = 0

	print("== 7. 队伍 / AI / 主控切换 / 仲裁 / 存档 ==")
	_check(main.party.friend_count() == 2, "默认 2 名队友")
	_check(main.party.max_size() == 8, "MaxPartySize=8 来自配置")
	# N 容量可配（需求书 §5.1）：走热重载数据层改容量
	ArpgBalance.data["party"]["max_party_size"] = 3
	_check(main.party.max_size() == 3, "热改容量生效（3）")
	_check(main.party.can_recruit(), "容量 3 可再招")
	_check(main.party.recruit_char("archer", main.dungeon.start_cell + Vector2i(1, 0)) != null, "招募第 3 名")
	_check(not main.party.can_recruit(), "容量满拒绝招募")
	ArpgBalance.data["party"]["max_party_size"] = 8
	# APC：不占容量、默认不可主控（需求书 §5.6）
	var apc = main.party.recruit_apc("mercenary", main.dungeon.start_cell + Vector2i(-1, 0))
	_check(apc != null and apc.is_apc, "APC 招募（不占容量）")
	_check(main.possession.switch_block_reason(apc).contains("APC"), "APC 默认不可主控")
	# 三指令下达
	main.party.set_squad_command("hold")
	_check(main.party.friends[0].command == "hold", "小队指令下达")
	# 主控切换：状态连续（需求书 §5.4 / §9）
	var f0 = main.party.friends[0]
	f0.skill_cd = 2.0
	f0.hp = f0.max_hp - 5
	_check(main.possession.switch_to(f0), "切换主控到队友")
	_check(main.possession.is_possessed(f0), "主控已切换")
	_check(f0.skill_cd > 1.5, "技能 CD 连续（%.2f）" % f0.skill_cd)
	_check(f0.hp == f0.max_hp - 5, "血量连续")
	_check(not main.possession.switch_to(main.player), "冷却期内禁止切回")
	# 死亡禁止主控
	var f1 = main.party.friends[1]
	f1.dead = true
	_check(not main.possession.switch_to(f1), "死亡单位禁止主控")
	f1.dead = false
	# 拾取仲裁：防重复 + 玩家优先（需求书 §5.5 / §9）
	var iid: int = main.world.pickups.spawn(main.player.position, "herb")
	_check(main.arbiter.request("friend_x", iid), "AI 认领掉落")
	_check(not main.arbiter.request("friend_y", iid), "他人重复认领被拒")
	_check(main.arbiter.request("player", iid), "玩家优先覆盖认领")
	# 存档往返：稳定 uid + 指令 + 状态（需求书 §6 / §9）
	var snap: Dictionary = main.party.to_dict()
	f0.hp = 1
	main.party.set_squad_command("active")
	main.party.from_dict(snap)
	_check(main.party.friends[0].hp == int(snap["friends"][0]["hp"]), "存档回滚 HP")
	_check(main.party.friends[0].command == "hold", "存档回滚指令")
	await create_timer(1.0).timeout
	_check(main.party.friends[0].state != "", "队友 AI 正常思考（state=%s）" % main.party.friends[0].state)

	print("== 8. 热重载 ==")
	var imp_hp: int = int(ArpgBalance.ENEMIES["imp"]["hp"])
	ArpgBalance.ENEMIES["imp"]["hp"] = 777
	main.world.mobs.apply_balance()   # 真实链路：监视器 reload 后必然调用
	var ni: int = main.world.spawn_mob("imp", main.dungeon.random_cell_in(main.dungeon.rooms[0]), false, false)
	_check(ni >= 0 and main.world.mobs.max_hp[ni] == 777, "新生成怪物使用热改数值（%d）" % (main.world.mobs.max_hp[ni] if ni >= 0 else -1))
	main.world.mobs.apply_balance()
	_check(main.world.mobs.tpl_hp[main.world.mobs.tpl_name.find("imp")] == 777, "模板表热刷新")
	# 文件级：改 balance.json → reload → 生效 → 恢复
	var orig: String = FileAccess.get_file_as_string(ArpgBalance.PATH)
	var parsed = JSON.parse_string(orig)
	parsed["enemies"]["imp"]["hp"] = 555
	var fw := FileAccess.open(ArpgBalance.PATH, FileAccess.WRITE)
	fw.store_string(JSON.stringify(parsed, "  "))
	fw.close()
	var ok := false
	for attempt in 6:
		ok = ArpgBalance.reload_data() and int(ArpgBalance.ENEMIES["imp"]["hp"]) == 555
		if ok:
			break
		await create_timer(0.2).timeout
	_check(ok, "balance.json 重载成功且文件修改即时生效（555）")
	main.world.mobs.apply_balance()
	var fw2 := FileAccess.open(ArpgBalance.PATH, FileAccess.WRITE)
	fw2.store_string(orig)
	fw2.close()
	var restored := false
	for attempt in 6:
		restored = int(ArpgBalance.ENEMIES["imp"]["hp"]) == imp_hp
		if restored:
			break
		ArpgBalance.reload_data()
		await create_timer(0.2).timeout
	_check(restored, "恢复文件数值（%d）" % imp_hp)
	main.world.mobs.apply_balance()

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
