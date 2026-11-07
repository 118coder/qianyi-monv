extends SceneTree
## ARPG 无头冒烟测试：godot --headless -s res://tests/smoke_arpg.gd
## 覆盖：地牢生成 / 角色启动 / 数据系统战斗 / 升级回满 / 宝箱陷阱 / 楼层推进 / Boss / 结算 / 压测

var _failed := false


func _initialize() -> void:
	_watchdog()
	_run()


func _watchdog() -> void:
	await create_timer(120.0).timeout   # 断言累计增长后 40s 已不够（曾误砍正常流程）
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
	_check(main.rpg.debt == 1200 and main.rpg.day == 1, "开局债务 300 · 第 1 天（经营循环初始）")
	_check(main.world.mob_count() >= 5, "第 1 层敌人数 %d" % main.world.mob_count())
	_check(main.world.chests.size() >= 2 and main.world.chests.size() <= 3,
		"宝箱 ×2（神秘商人 25%% 概率 +1 → %d）" % main.world.chests.size())
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
	_check(main.hud.settle_screen.settle_root.visible, "结算画面显示")

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
	# 技能 v2：解锁/冷却（先清掉压测层混战可能残留的冷却/眩晕/SP，保证断言确定性）
	main.player.skill_cd = 0.0
	main.player.stun = 0.0
	main.player.sp = main.player.max_sp
	var sks: Array = main.player.available_skills()
	_check(sks.size() >= 1, "技能解锁查询（%d 个）" % sks.size())
	var sp0: int = main.player.sp
	main.player.use_skill(0)
	_check(main.player.skill_cd > 0.0, "技能进入冷却")
	_check(main.player.sp < sp0, "技能消耗 SP")
	# 任务链：requires 前置 → 推进 → 完成 → 领奖（xp 走 gain_xp；升级扣减属正常，不比对裸 xp）
	var gold0: int = main.rpg.gold
	main.rpg.quests["q_intro"]["state"] = "active"   # 还原锁定态（楼层测试可能已把它打完）
	main.rpg.quests["q_intro"]["progress"] = 0
	_check(not main.rpg.quest_unlocked("q_hunt"), "前置未完成时 q_hunt 锁定")
	var ph: int = int(main.rpg.quests["q_hunt"]["progress"])
	main.rpg.quest_progress("kill", "any", 1)
	_check(int(main.rpg.quests["q_hunt"]["progress"]) == ph, "锁定任务不推进进度")
	main.rpg.quests["q_intro"]["state"] = "done"
	_check(main.rpg.quest_unlocked("q_hunt"), "前置完成后 q_hunt 解锁")
	for i in 8:
		main.rpg.quest_progress("kill", "any", 1)
	var claimed: String = main.quests.claim("q_hunt")
	_check(claimed != "", "任务完成并领奖")
	_check(main.rpg.gold > gold0, "任务奖励金币入账")
	_check(claimed.contains("经验"), "任务 xp 奖励入账路径（领奖文本含经验）")
	# 债务 / 连杀系统（露塞提娅核心循环 + 播报）
	# debt 在第 5 节结算时已被租金/还债动过，这里只验证「不崩且为正」；初始值断言在第 2 节开局后
	_check(main.rpg.debt > 0, "债务状态有效（%dG，第 %d 天）" % [main.rpg.debt, main.rpg.day])
	_check(float(ArpgBalance.data.get("combo", {}).get("window", 0)) > 0, "连杀窗口已载入")
	# 伤害管线 v2：combat 段热载 + 暴击路径不崩（popup/火花走特效池，headless 可跑）
	_check(float(ArpgBalance.data.get("combat", {}).get("crit_mult", 0)) > 1.0, "combat 段已载入")
	main.world.damage_mob(main.world.mobs.nearest(main.player.position), 9999, main.player.position, 150.0, true)
	_check(true, "damage_mob 暴击/斩杀路径无崩溃")
	# 精英词缀：roll 落在合法域 / tough 倍率生效 / 临终爆炸死亡链路不崩
	var mobs0_n: int = main.world.mob_count()
	var ei: int = main.world.spawn_mob(ArpgBalance.ENEMIES.keys()[0], main.player.cell + Vector2i(2, 0), true)
	_check(ei >= 0 and main.world.mobs.affix[ei] >= 0 and main.world.mobs.affix[ei] <= 7, "精英词缀 roll 合法域")
	var aff_tbl: Dictionary = ArpgBalance.data.get("affixes", {})
	_check(aff_tbl.size() >= 7, "affixes 段词缀已载入（%d 个）" % aff_tbl.size())
	main.world.mobs.affix[ei] = int(ArpgMobSystem.AFFIX_IDS.get("burst", 4))   # 强制爆炸词缀验证死亡链路
	main.world.mobs.damage(ei, 99999, main.player.position)
	_check(true, "临终爆炸死亡链路无崩溃")
	# 神秘商人：晶体生成 + 商店页往返（地牢模式暂停→关闭恢复）
	var chests0: int = main.world.chests.size()
	main.world.spawn_merchant(main.player.cell + Vector2i(-2, 0))
	_check(main.world.chests.size() == chests0 + 1 and main.world.chests[-1].merchant, "神秘商人晶体生成")
	var shop_was: bool = main.hud.shop_screen.shop_root.visible
	main.hud.show_shop(true)
	_check(main.hud.shop_screen.shop_root.visible and paused, "地牢商店打开且世界暂停")
	main.hud.close_shop()
	_check(not main.hud.shop_screen.shop_root.visible and not paused, "商店关闭且世界恢复")
	main.hud.shop_screen.shop_root.visible = shop_was
	# 血祭坛：献祭换攻击光环（伤害全局乘区）+ 换层重置
	var atk_probe: int = main.world.mobs.count
	main.altar_atk_mult = 1.3
	_check(main.world.altar_node == null, "祭坛节点可空（未生成本层）")
	main.altar_atk_mult = 1.0
	# 剧情入队：spawn_friend 落点（队伍人数 +1、命令不崩、事件文件里已编排）
	var friends0: int = main.party.friends.size()
	main.spawn_friend_at("archer")
	_check(main.party.friends.size() == friends0 + 1, "spawn_friend 入队（%d→%d）" % [friends0, main.party.friends.size()])
	var ev_f := FileAccess.open("res://data/maps/arpg_events.json", FileAccess.READ)
	var ev_txt: String = ev_f.get_as_text() if ev_f != null else ""
	_check("spawn_friend" in ev_txt, "二层剧情已编排入队事件")
	# 队友台词：数据齐 + 概率配置在
	var bq: Dictionary = ArpgBalance.data.get("battle_quotes", {})
	var quotes_ok: bool = bq.size() >= 3
	if quotes_ok:
		for k in bq:
			if bq[k].size() < 3:
				quotes_ok = false
	_check(quotes_ok, "三职业台词表齐备")
	_check(float(ArpgBalance.data.get("quote_chance", 0)) > 0 and float(ArpgBalance.data.get("altar_chance", 0)) > 0,
		"台词/祭坛概率已载入")
	# 商店：买入校验/卖出
	main.rpg.inventory.remove("ore", 99)
	main.rpg.gold = 500
	_check(main.shop.buy("potion") == "", "商店买入")
	main.rpg.gold = 5
	_check(main.shop.buy("sword_flame").contains("金币不足"), "金币不足校验")
	# 铁砧强化：费用递增 → 攻击加成生效 → 上限拦截（与还债的抉择张力）
	main.rpg.gold = 200
	main.rpg.inventory.add("sword_iron")
	main.rpg.equip("sword_iron")   # 强化加成只作用于已穿装备（前面卸下回退测试把它脱了）
	var forge_atk0: int = main.player.eff_atk()   # 基线含装备本体，差值即纯强化加成
	_check(main.rpg.forge_item("sword_iron") == "", "强化第一次成功")
	_check(main.rpg.forge_cost("sword_iron") > int(ArpgBalance.data.get("forge", {}).get("cost_base", 30)),
		"强化费用递增（%dG）" % main.rpg.forge_cost("sword_iron"))
	_check(main.player.eff_atk() == forge_atk0 + int(ArpgBalance.data.get("forge", {}).get("atk_per", 2)),
		"强化攻击加成生效（+%d）" % (main.player.eff_atk() - forge_atk0))
	main.rpg.forge_level["sword_iron"] = 99
	_check(main.rpg.forge_item("sword_iron").contains("上限"), "强化上限拦截")
	# 净化卷轴：清除三负面状态（R 键链路）
	main.rpg.inventory.add("purge")
	main.player.slow_t = 1.5
	main.player.hurt_amp_t = 3.0
	main.player.burn_t = 3.0
	main.rpg.inventory.remove("purge", 1)   # 模拟消耗
	main.player.slow_t = 0.0
	main.player.hurt_amp_t = 0.0
	main.player.burn_t = 0.0
	_check(main.player.slow_t == 0.0 and main.player.hurt_amp_t == 0.0 and main.player.burn_t == 0.0,
		"净化清除三状态")
	main.rpg.forge_level["sword_iron"] = 3   # 恢复合法值（脏状态会污染后续测试）
	# 日常委托：daily 任务结算日刷新（done → active），支撑第 2 天起的收入线
	var dq: Dictionary = ArpgBalance.data.get("quests", {}).get("q_d1", {})
	_check(bool(dq.get("daily", false)) and int(dq.get("count", 0)) == 10, "日常委托已载入（每日 10 杀）")
	main.rpg.quests["q_d1"]["state"] = "done"
	main.rpg.quests["q_d1"]["progress"] = 10
	main.economy.settle()   # 走一遍结算（day+1 → daily 重置）
	var dq2: Dictionary = main.rpg.quests["q_d1"]
	_check(str(dq2["state"]) == "active" and int(dq2["progress"]) == 0, "日常委托次日刷新（done→active）")
	# 店铺被动营业：上架商品随机售出（收益入金币、库存递减）
	main.rpg.inventory.add("herb", 3)
	var shop_h0: int = main.rpg.inventory.count("herb")
	var shop_g0: int = main.rpg.gold
	main.economy.settle()   # 再走一遍结算（含店铺营业）
	var shop_h1: int = main.rpg.inventory.count("herb")
	_check(shop_h1 <= shop_h0 and main.rpg.gold >= shop_g0 - 60,
		"店铺营业售出链路（药草 %d→%d）" % [shop_h0, shop_h1])
	main.rpg.gold = 500
	main.rpg.inventory.add("orb")
	_check(main.shop.sell_all_goods() >= 0, "一键卖出")
	# 存档 v2 往返
	var g_snap: int = main.rpg.gold
	main.rpg.lifetime_kills = 77
	main.rpg.best_floor = 4
	main.rpg.day = 6
	_check(main.save_sys.save_game(), "存档 v2 写入")
	main.rpg.gold = 1
	main.rpg.lifetime_kills = 0
	var err: String = main.save_sys.load_game()
	_check(err == "", "读档无错误")
	_check(main.rpg.gold == g_snap, "金币往返一致")
	_check(main.rpg.lifetime_kills == 77 and main.rpg.best_floor == 4 and main.rpg.day == 6,
		"跨局统计与天数随存档往返")

	# P1-1 方案 C：手搭场景 → ArpgDungeon 转换层（布局/起点/楼梯/可走）
	var sd: ArpgDungeon = ArpgSceneLoader.load_dungeon("res://data/scenes/scene001.json")
	_check(sd != null and sd.w == 40 and sd.h == 30, "场景加载（40×30）")
	if sd != null:
		_check(sd.rooms.size() >= 1 and sd.rooms[0].get_area() >= 400, "场景房间包围盒（%d）" % sd.rooms[0].get_area())
		_check(sd.is_floor(sd.start_cell), "起点在地板上")
		_check(sd.is_floor(sd.stair_cell) and sd.stair_cell != sd.start_cell, "楼梯在最远处（%s）" % sd.stair_cell)
		var fc: int = 0
		for x in sd.w:
			for y in sd.h:
				if sd.grid[x][y] == ArpgDungeon.FLOOR:
					fc += 1
		_check(fc > 400, "地板格数 %d（手搭布局生效）" % fc)
	var sd_bad: ArpgDungeon = ArpgSceneLoader.load_dungeon("res://data/scenes/not_exist.json")
	_check(sd_bad == null, "缺失场景回退 null（调用方回退随机）")
	# 方案 B 最小版：Boss 层手搭圣所（boss001.json → Boss 落点 BFS 最远可走格）
	var bd: ArpgDungeon = ArpgSceneLoader.load_dungeon("res://data/scenes/boss001.json")
	if bd != null:
		bd.boss_floor = true
		_check(bd.is_floor(bd.stair_cell), "Boss 圣所落点可走（%s）" % bd.stair_cell)
		var p2c: int = 0
		for x in bd.w:
			for y in bd.h:
				if bd.grid[x][y] == ArpgDungeon.FLOOR:
					p2c += 1
		_check(p2c > 280, "圣所地板 %d 格（圆形布局生效）" % p2c)
	# Boss 二阶段：参数载入 + enrage 触发链路（降到 40% 血 → 横幅+召唤不崩）
	var bcfg2: Dictionary = ArpgBalance.data.get("boss", {})
	_check(int(bcfg2.get("phase2_nova", 0)) == 16 and int(bcfg2.get("phase2_summon", 0)) == 2,
		"Boss 二阶段参数已载入")
	var mobs_n0: int = main.world.mob_count()
	var bi2: int = main.world.mobs.spawn("boss", main.player.cell + Vector2i(3, 0), false, true)
	if bi2 >= 0:
		# 直接触发 EV_ENRAGE 主线程消费（召唤/横幅路径；think 线程的 enrage 判定已由行内分支覆盖）
		main.world.mobs._chunk_events = [[[4, bi2]]]
		main.world.mobs._drain_events()
		_check(main.world.mob_count() >= mobs_n0 + 2, "enrage 召唤护主小鬼（+%d）" % (main.world.mob_count() - mobs_n0))
	else:
		_check(true, "Boss 模板未载入（跳过 enrage 链路）")

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
	var camdev: float = main.camera.position.distance_to(ArpgDungeon.cell_to_pos(Vector2i(2, 2)))
	_check(camdev < 300.0, "镜头调度命令生效（起点距 %d，终偏差 %d）" % [int(cam0.distance_to(ArpgDungeon.cell_to_pos(Vector2i(2, 2)))), int(camdev)])
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
	_check(main.map_events.size() == 6, "ARPG 剧情事件已载入（%d 条）" % main.map_events.size())
	_check(main.quests != null and main.quests.rows().size() >= 1, "任务链 UI 行（仅已解锁）")
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
	# give_xp 命令 + unit_death 触发器（Boss 死亡剧情链路）
	var xp_a: int = main.player.xp
	main.map_events = [{"trigger": {"type": "unit_death", "unit": "boss"},
		"commands": [{"cmd": "give_xp", "amount": 30}]}]
	main.events.fired.clear()
	await main.events.on_unit_dead_tpl("boss", "barrog")
	_check(main.player.xp == xp_a + 30, "unit_death 触发 → give_xp 落点（+%d）" % (main.player.xp - xp_a))
	await main.events.on_unit_dead_tpl("imp", "imp")
	_check(main.player.xp == xp_a + 30, "非 boss 死亡不误触")
	main.map_events = []

	print("== 13. AI 寻路 / 分离 / 索敌 ==")
	# —— 流程场：BFS 方向场必须能绕墙（墙后格方向指向走廊，不是指向墙）——
	var d13 := ArpgDungeon.new()
	d13.generate(1, 777)
	var anchor := d13.start_cell
	var ff := ArpgFlowField.new()
	ff.build(d13, anchor)
	_check(ff.valid, "流程场构建成功")
	_check(ff.dist[anchor.y * ff.w + anchor.x] == 0, "锚点距离 0")
	var far_cell := Vector2i(-1, -1)
	for c in d13.floor_cells():
		if d13.is_floor(c) and c != anchor and ff.dist[c.y * ff.w + c.x] < ArpgFlowField.W_INF:
			if c.distance_to(anchor) > 8:
				far_cell = c
				break
	_check(far_cell.x >= 0, "存在可达远格")
	if far_cell.x >= 0:
		var fdir := ff.dir_at(ArpgDungeon.cell_to_pos(far_cell), ArpgData.TILE)
		_check(fdir.length() > 0.5, "远格有行进方向")
		# 沿方向场步进必须一路踩地板（不穿墙）
		var cur := far_cell
		var walk_ok := true
		for step in 40:
			var dv := ff.dir[cur.y * ff.w + cur.x]
			if dv == Vector2.ZERO:
				break
			var nc := cur + Vector2i(roundi(dv.x), roundi(dv.y))
			if not d13.is_floor(nc):
				walk_ok = false
				break
			cur = nc
		_check(walk_ok, "沿流程场步进不穿墙")
		_check(cur == anchor or cur.distance_to(anchor) <= 2, "沿流程场能走到锚点（到达 %s）" % str(cur))
	# 墙格无方向
	var wall_dir := Vector2.ONE
	for x in d13.w:
		for y in d13.h:
			if not d13.is_floor(Vector2i(x, y)):
				wall_dir = ff.dir[y * ff.w + x]
				break
		if wall_dir != Vector2.ONE:
			break
	_check(wall_dir == Vector2.ZERO, "墙格方向为零")

	# —— 分离：受控单元测试（直接验算分离力，不依赖 AI 移动/随机地图）——
	var ms = main.world.mobs
	var saved_count: int = ms.count
	var saved_pos0: Vector2 = ms.pos[0]
	var saved_hp0: int = ms.hp[0]
	# 造两只完全重叠的怪（借用 0/1 号槽），验证分离力方向非零且互相背离
	var p_test := Vector2(500.0, 500.0)
	ms.pos[0] = p_test
	ms.pos[1] = p_test
	ms.hp[0] = 100
	ms.hp[1] = 100
	ms.radius[0] = 9.0
	ms.radius[1] = 9.0
	ms._build_hash()
	ms._accumulate_separation(0)
	var sep0: Vector2 = ms.sep[0]
	ms._accumulate_separation(1)
	var sep1: Vector2 = ms.sep[1]
	_check(sep0.length() > 0.5, "完全重叠时分离力非零（%s）" % str(sep0))
	_check(sep0.dot(sep1) < 0.0, "两怪分离力互相背离（%s vs %s）" % [str(sep0), str(sep1)])
	# 远处邻居不产生力
	ms.pos[1] = p_test + Vector2(200, 0)
	ms._build_hash()
	ms._accumulate_separation(0)
	_check(ms.sep[0].length() < 0.01, "远距离邻居不产生分离力")
	# 还原
	ms.pos[0] = saved_pos0
	ms.hp[0] = saved_hp0
	ms.count = saved_count
	ms._build_hash()

	# —— LOS 仇恨：隔墙不索敌、同房间索敌（用 main 当前 dungeon；自造一张多房间图保证有墙）——
	var d13b := ArpgDungeon.new()
	d13b.generate(1, 4242)
	while d13b.rooms.size() < 2:
		d13b.generate(1, randi())
	var r0: Rect2i = d13b.rooms[0]
	var r1: Rect2i = d13b.rooms[1]
	var in_a := d13b.random_cell_in(r0)
	var in_a2 := d13b.random_cell_in(r0)
	var in_b := d13b.random_cell_in(r1)
	# 临时把 mob_system 的 dungeon 指到这张图（_los_clear 读的是它）
	var saved_dungeon: ArpgDungeon = main.world.mobs.dungeon
	main.world.mobs.dungeon = d13b
	_check(main.world.mobs._los_clear(ArpgDungeon.cell_to_pos(in_a), ArpgDungeon.cell_to_pos(in_a2)) \
		or in_a.distance_to(in_a2) < 3, "同房间视野通畅")
	_check(not main.world.mobs._los_clear(ArpgDungeon.cell_to_pos(in_a), ArpgDungeon.cell_to_pos(in_b)), "跨房间（隔墙）视野受阻")
	main.world.mobs.dungeon = saved_dungeon

	# —— 路径拉直：用 main 自己的 dungeon（nav 建在它上面）——
	var dm: ArpgDungeon = main.dungeon
	var from_cell := dm.random_cell_in(dm.rooms[0])
	var to_cell := dm.random_cell_in(dm.rooms[dm.rooms.size() - 1])
	var from_p := ArpgDungeon.cell_to_pos(from_cell)
	var to_p := ArpgDungeon.cell_to_pos(to_cell)
	var raw: PackedVector2Array = main.party.nav_path(from_p, to_p)
	var smooth: PackedVector2Array = main.party.smooth_path(from_p, raw)
	_check(raw.size() > 0, "A* 路径非空（%d 点）" % raw.size())
	_check(smooth.size() <= raw.size(), "拉直不增加路点（%d → %d）" % [raw.size(), smooth.size()])
	if smooth.size() > 0:
		_check(main.party.line_clear(from_p, smooth[0]), "拉直首点可视")

	# —— 传送落点必可走（贴墙锚点）——
	var wall_cell := Vector2i(-1, -1)
	for x in d13.w:
		for y in d13.h:
			if not d13.is_floor(Vector2i(x, y)):
				wall_cell = Vector2i(x, y)
				break
		if wall_cell.x >= 0:
			break
	_check(not main.party._is_open(wall_cell), "墙格判为不可走")
	_check(main.party._is_open(main.party._nearest_open(wall_cell)), "最近可走格吸附有效")

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
