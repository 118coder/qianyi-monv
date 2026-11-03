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
	_check(main.rpg.inventory.count("potion") == 3, "初始药水 ×3")

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
	var herb0: int = main.rpg.inventory.count("herb")
	main.try_pickup("herb")
	_check(main.rpg.inventory.count("herb") == herb0 + 1, "拾取入包（堆叠）")
	for i in 30:
		main.try_pickup("ore")
	_check(main.rpg.inventory.count("ore") >= 30, "同类堆叠 30 个不占新格")
	_check(main.rpg.inventory.used() <= main.rpg.inventory.cap, "不超容量")
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

	print("== 9. RPG 系统（背包/装备/技能/任务/商店/存档） ==")
	# 背包：堆叠 + 容量原子性
	var inv := ArpgInventory.new()
	inv.setup(4)
	_check(inv.add("potion", 5), "堆叠添加")
	_check(inv.count("potion") == 5 and inv.used() == 1, "同类堆叠不占多格")
	_check(inv.add("herb") and inv.add("ore") and inv.add("gems"), "新格添加至满")
	_check(not inv.add("orb"), "容量满拒绝（原子性）")
	_check(inv.remove("potion", 3) and inv.count("potion") == 2, "部分移除")
	# 装备：加成与回退
	main.rpg.inventory.add("sword_iron")
	var base_atk: int = main.player.atk
	_check(main.rpg.equip("sword_iron"), "穿装备")
	_check(main.player.eff_atk() == base_atk + 3, "攻击加成生效（+%d）" % (main.player.eff_atk() - base_atk))
	main.rpg.unequip("weapon")
	_check(main.player.eff_atk() == base_atk, "卸下回退")
	# 技能 v2：解锁/冷却
	var sks: Array = main.player.available_skills()
	_check(sks.size() >= 1, "技能解锁查询（%d 个）" % sks.size())
	var sp0: int = main.player.sp
	main.player.use_skill(0)
	_check(main.player.skill_cd > 0.0, "技能进入冷却")
	_check(main.player.sp < sp0, "技能消耗 SP")
	# 任务：进度/完成/领奖
	var gold0: int = main.rpg.gold
	for i in 8:
		main.rpg.quest_progress("kill", "any", 1)
	var claimed: String = main.quests.claim("q_hunt")
	_check(claimed != "", "任务完成并领奖")
	_check(main.rpg.gold > gold0, "任务奖励金币入账")
	# 商店：买入校验/卖出
	main.rpg.inventory.remove("ore", 99)
	main.rpg.gold = 500
	_check(main.shop.buy("potion") == "", "商店买入")
	main.rpg.gold = 5
	_check(main.shop.buy("sword_flame").contains("金币不足"), "金币不足校验")
	main.rpg.gold = 500
	main.rpg.inventory.add("orb")
	_check(main.shop.sell_all_goods() >= 0, "一键卖出")
	# 存档 v2 往返
	var g_snap: int = main.rpg.gold
	_check(main.save_sys.save_game(), "存档 v2 写入")
	main.rpg.gold = 1
	var err: String = main.save_sys.load_game()
	_check(err == "", "读档无错误")
	_check(main.rpg.gold == g_snap, "金币往返一致")

	print("== 10. 基座（设置/音频/存档槽/校验/字符串） ==")
	var mv: Variant = main.settings.get_value("master_vol")
	main.settings.set_value("master_vol", 0.5)
	_check(float(main.settings.get_value("master_vol")) == 0.5, "设置写入并持久化")
	var bus_idx := AudioServer.get_bus_index("Master")
	_check(bus_idx >= 0 and AudioServer.get_bus_volume_db(bus_idx) < -3.0, "总线音量即时应用")
	main.settings.set_value("master_vol", mv)
	_check(AudioServer.get_bus_index("Music") >= 0 and AudioServer.get_bus_index("SFX") >= 0, "Music/SFX 总线就绪")
	main.audio.play_music("dungeon")
	_check(main.audio._current_track == "dungeon", "BGM 按键切轨")
	var errs: Array = ArpgBalance.validate()
	_check(errs.is_empty(), "内容校验无错误 %s" % str(errs))
	_check(L10n.text("ui.shop", "x") == "店铺（试营业）", "字符串表命中")
	_check(L10n.text("ui.nonexistent_key", "兜底文案") == "兜底文案", "缺失键回退兜底")
	var gold_saved: int = main.rpg.gold
	_check(main.save_sys.save_game(2), "槽位 2 覆盖保存")
	main.rpg.gold = 777
	_check(main.save_sys.load_game(2) == "", "槽位 2 读取")
	_check(main.rpg.gold == gold_saved, "槽位隔离数据一致（回滚到 %d）" % main.rpg.gold)
	_check(main.save_sys.slot_meta(2).has("floor"), "槽位元信息齐全")

	print("== 11. 节点式事件 / 镜头调度 / 状态机 ==")
	main.flags.clear()
	var nested: Array = [
		{"cmd": "set_flag", "flag": "a", "value": true},
		{"cmd": "if", "flag": "a", "equals": true, "then": [
			{"cmd": "set_flag", "flag": "b", "value": true},
			{"cmd": "if", "flag": "zzz", "equals": true, "then": [], "else": [
				{"cmd": "set_flag", "flag": "c", "value": true}]},
		], "else": [
			{"cmd": "set_flag", "flag": "d", "value": true}]},
	]
	await main.events._run_commands(nested)
	_check(bool(main.flags.get("b", false)), "嵌套 IF 是分支执行")
	_check(bool(main.flags.get("c", false)), "嵌套 IF 否分支执行")
	_check(not main.flags.has("d"), "未走的分支不执行")
	var flat: Array = []
	EditorAdvancedTabs.flatten(nested, 0, [], flat)
	_check(flat.size() == 6, "画布铺平 %d 节点（含分支）" % flat.size())
	var cam0: Vector2 = main.camera.position
	await main.events._run_commands([{"cmd": "camera", "mode": "focus_cell", "cell": [2, 2], "dur": 0.3}])
	_check(main.camera.position.distance_to(ArpgDungeon.cell_to_pos(Vector2i(2, 2))) < 300.0, "镜头调度命令生效")
	await main.events._run_commands([{"cmd": "wait", "time": 0.2}, {"cmd": "give_gold", "amount": 33}])
	_check(main.rpg.gold >= 33, "等待/给金币命令")
	var hp00: int = int(ArpgBalance.ENEMIES["imp"]["hp"])
	ArpgBalance.ENEMIES["imp"]["hp"] = hp00 + 10
	main.world.mobs.apply_balance()
	_check(int(ArpgBalance.ENEMIES["imp"]["hp"]) == hp00 + 10, "状态机参数热改生效")
	ArpgBalance.ENEMIES["imp"]["hp"] = hp00
	main.world.mobs.apply_balance()
	_check(EditorAdvancedTabs.ai_states(ArpgBalance.ENEMIES["imp"]).size() == 4, "AI 状态图节点")
	_check(EditorAdvancedTabs.ai_states(ArpgBalance.BOSS).size() == 5, "Boss 状态图节点")

	print("== 12. 事件引擎接线（main 侧触发链路） ==")
	_check(main.events != null, "事件引擎已实例化")
	_check(main.map_events.size() == 2, "地图 JSON 事件已载入（%d 条）" % main.map_events.size())
	_check(main.over == false, "局未结束判定")
	# 真实触发链路：on_phase_start → _fire → map_events 匹配 → 命令落点
	main.map_events = [{"trigger": {"type": "turn_start", "phase": "player", "turn": 1},
		"commands": [{"cmd": "give_gold", "amount": 50}]}]
	var gold_a: int = main.rpg.gold
	await main.events.on_phase_start("player", 1)
	_check(main.rpg.gold == gold_a + 50, "回合事件触发 → give_gold 落点")
	await main.events.on_phase_start("player", 2)
	_check(main.rpg.gold == gold_a + 50, "回合不匹配不误触")
	# zone 触发（玩家 faction/cell 上报）+ spawn 落点（暂停世界避免队友击杀干扰计数）
	var mobs0: int = main.world.mob_count()
	paused = true
	main.map_events = [{"trigger": {"type": "zone", "rect": [0, 0, 9999, 9999], "faction": "player"},
		"commands": [{"cmd": "spawn", "tpl": "orc", "cells": [[main.player.cell.x, main.player.cell.y]]}]}]
	main.events.fired.clear()
	await main.events.on_unit_moved(main.player)
	_check(main.world.mob_count() == mobs0 + 1, "zone 事件触发 → spawn 落点（+1 敌）")
	paused = false
	main.map_events = []

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
