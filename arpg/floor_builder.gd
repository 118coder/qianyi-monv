class_name ArpgFloorBuilder
extends RefCounted
## ⚠️ 跨脚本引用未进 class cache 的类一律 preload（踩坑清单 #5，CameraDirector 即此类）
const CameraDirector := preload("res://arpg/camera_director.gd")
## 楼层组装编排（P1-2 第三步从 main.build_floor 拆出）：
## 地牢来源决策（压测/手搭场景/Boss 圣所/随机）→ world 重建 → 成长搬运 →
## 队伍/主控/镜头重绑 → 怪物/宝箱/商人/祭坛/楼梯铺排 → PLAY 收尾。
## main 只保留一行转调；成员访问一律经 main 引用（不持有状态）。


static func build(main: Node) -> void:
	# 旧玩家节点会随旧 world 一起释放：先留引用 + 快照成长数据。
	# （玩家是节点，等级/经验/装备加成只活在节点上；重建节点若不搬运，下到第 2 层
	#   就直接掉回 1 级——这是"进入第二层异常"的另一半。）
	var prev_player = main.player
	var carry := {}
	if prev_player != null and is_instance_valid(prev_player):
		carry = {"level": prev_player.level, "xp": prev_player.xp}
	if is_instance_valid(main.world):
		main.world.queue_free()
	main.world = null
	main.player = null
	main.rng.randomize()
	main.dungeon = ArpgDungeon.new()
	if main._stress_n > 0:
		main.dungeon.generate_arena()
	elif main.scene_name != "":
		# P1-1 方案 C：手搭场景试玩模式（--scene=scene001）；加载失败回退随机
		var sd: ArpgDungeon = ArpgSceneLoader.load_dungeon("res://data/scenes/%s.json" % main.scene_name)
		if sd != null:
			main.dungeon = sd
		else:
			push_warning("场景 %s 加载失败，回退随机生成" % main.scene_name)
			main.dungeon.generate(main.floor_no, main.dungeon_seed + main.floor_no * 7919 if main.dungeon_seed != 0 else -1,
				maxi(2, ArpgBalance.max_footprint()))
	elif main.dungeon.boss_floor and FileAccess.file_exists("res://data/scenes/boss001.json"):
		# 方案 B 最小版：Boss 层用手搭圣所（boss001.json 存在即用；无则随机 Boss 房）
		var bd: ArpgDungeon = ArpgSceneLoader.load_dungeon("res://data/scenes/boss001.json")
		if bd != null:
			main.dungeon = bd
			main.dungeon.boss_floor = true   # loader 默认关 Boss 层（试玩模式语义），这里恢复
		else:
			main.dungeon.generate(main.floor_no, main.dungeon_seed + main.floor_no * 7919 if main.dungeon_seed != 0 else -1,
				maxi(2, ArpgBalance.max_footprint()))
	else:
		# 走廊宽度下限 = 全场最大实体占几格（大角色进得去，不靠玩家撞墙才发现）
		main.dungeon.generate(main.floor_no, main.dungeon_seed + main.floor_no * 7919 if main.dungeon_seed != 0 else -1,
			maxi(2, ArpgBalance.max_footprint()))

	var world: ArpgWorld = ArpgWorld.new()
	main.world = world
	main._slot("世界").add_child(world)
	world.build(main.dungeon, main)
	world.spawn_player(main.char_id)
	main.player = world.player
	var player: ArpgPlayer = main.player
	if not carry.is_empty():
		# 搬运成长：只搬等级/经验，派生属性按等级重算，避免两份真值打架
		player.level = int(carry["level"])
		player.xp = int(carry["xp"])
	# 派生属性一律重算：等级成长 + 当前装备加成（新节点默认只有模板 1 级数值）
	player.apply_level_stats()
	player.hp = player.max_hp          # 换层回满（沿用原行为）
	player.sp = player.max_sp
	player.refresh_bars()

	# —— 队伍 / 主控：必须在本层重建玩家之后立刻重绑 ——
	# ⚠️ 这里就是"下到第二层镜头失效 / 角色不受控"的根因：
	# 旧实现只在 `current_unit == null` 时重绑，而换层后 current_unit 指向的是**上一层的玩家节点**，
	# 它随旧 world 被 queue_free → 变成已释放对象。判据改为"无效或被换掉"，而不是"为空"。
	if main.party == null:
		main.party = ArpgPartyManager.new()
		main.party.setup(main)
		main.add_child(main.party)
	main.party.build_nav(main.dungeon)
	if main.possession == null:
		main.possession = ArpgPossessionManager.new()
		main.possession.setup(main, player)
	else:
		var cur = main.possession.current_unit
		if cur == null or not is_instance_valid(cur) or cur == prev_player:
			main.possession.current_unit = player

	# 镜头：调度器（director）复用节点，每层只重设边界；rig 由调度器持有
	if main.cam == null:
		main.cam = CameraDirector.new()
		main._slot("镜头").add_child(main.cam)
		main.cam.focus_fallback = Callable(main, "_camera_focus")
	main.cam.setup(main, main.dungeon)
	main.camera = main.cam.rig
	main.camera.make_current()
	var c0 = main._camera_focus()
	main.cam.bind(c0, main.party.friends)
	main.cam.reset(c0.position if c0 != null else player.position)

	if main._stress_n == 0:
		main.party.revive_all_on_floor()
		# 开局落点：按槽位环形展开且必须可走。
		# 旧实现随机 ±50 偏移不校验 → 贴墙开局直接把队友放进墙里，一开局就在"卡住"状态。
		for f in main.party.friends:
			if not f.dead:
				var ang := float(main.party.slot_index(f)) * (TAU / 8.0) + 0.5
				var p: Vector2 = player.position + Vector2.RIGHT.rotated(ang) * 44.0
				var c := Vector2i((p / float(ArpgData.TILE)).floor())
				if not main.party._is_open(c):
					p = ArpgDungeon.cell_to_pos(main.party._nearest_open(c))
				f.teleport_to(p)
	# 换层后刷新队友的 world/main 引用（party_root 不随楼层销毁）
	for f in main.party.friends:
		f.world = world
		f.main = main

	_populate(main)
	_finish(main)


## 怪物 / 宝箱 / 商人 / 祭坛 / 楼梯铺排（按层型分支）
static func _populate(main: Node) -> void:
	var dungeon: ArpgDungeon = main.dungeon
	var world: ArpgWorld = main.world
	var rng: RandomNumberGenerator = main.rng
	if main._stress_n > 0:
		main._setup_stress()
	elif dungeon.boss_floor:
		var room: Rect2i = dungeon.rooms[0]
		# Boss 落点：手搭场景（rooms 是大包围盒）用 stair_cell（BFS 最远可走格）；
		# 随机 Boss 房仍用房间右缘。两者都保证 Boss 不卡墙。
		var boss_cell := Vector2i(room.end.x - 4, room.position.y + room.size.y / 2)
		if dungeon.stair_cell.x >= 0 and dungeon.is_floor(dungeon.stair_cell) \
				and dungeon.tile_ids.size() > 0:
			boss_cell = dungeon.stair_cell
		world.spawn_mob("boss", boss_cell, false, true)
		for i in 2:
			world.spawn_mob("imp", dungeon.random_cell_in(room), false, false)
		main.hud.log("魔王的气息逼近——击败它就能凯旋！")
	else:
		# 敌人：逐个随机房间（跳过出发房间；rooms 已按距起点距离排序，越靠后越深）
		var count := ArpgBalance.floor_enemy_count(main.floor_no)
		var pool: Array = ArpgBalance.floor_pool(main.floor_no)
		var room_hi := maxi(dungeon.rooms.size() - 1, 1)
		for i in count:
			var room: Rect2i = dungeon.rooms[0]
			if dungeon.rooms.size() > 1:
				room = dungeon.rooms[rng.randi_range(1, room_hi)]
			var cell := dungeon.random_cell_in(room)
			if ArpgDungeon.cell_to_pos(cell).distance_to(ArpgDungeon.cell_to_pos(dungeon.start_cell)) < 200.0:
				continue
			var tpl_id: String = ArpgBalance.weighted_pick(pool, dungeon.rng)
			world.spawn_mob(tpl_id, cell, rng.randf() < ArpgBalance.ELITE_CHANCE, false)
		# 宝箱 ×2：优先放叶节点房间（只连一条走廊的尽头），跑一趟有回报
		for i in 2:
			world.spawn_chest(dungeon.random_cell_in(dungeon.loot_room(rng)))
		# 神秘商人晶体：普通层概率出现（紫色晶体 E 键进店——地牢里的补给惊喜点）
		if rng.randf() < float(ArpgBalance.data.get("merchant_chance", 0.25)):
			world.spawn_merchant(dungeon.random_cell_in(dungeon.loot_room(rng)))
		# 血祭坛：20% 概率，献祭 30% 生命换全队攻击 +30%（本层有效，高风险高回报）
		main.altar_atk_mult = 1.0
		world.clear_altar()
		if not dungeon.boss_floor and rng.randf() < float(ArpgBalance.data.get("altar_chance", 0.2)):
			var altar_room: Rect2i = dungeon.rooms[rng.randi_range(1, dungeon.rooms.size() - 2)]
			world.spawn_altar(dungeon.random_cell_in(altar_room))
		# 楼梯放在生成器算好的最远房间（stair_cell），不再依赖 rooms 的下标含义
		world.set_stairs(dungeon.stair_cell if dungeon.stair_cell.x >= 0 \
			else dungeon._center(dungeon.rooms[dungeon.rooms.size() - 1]))


## PLAY 收尾：状态切换 / HUD / 音乐 / 任务推进 / 开场事件
static func _finish(main: Node) -> void:
	main.state = main.State.PLAY
	main.hud.play_hud.visible = true
	main.hud.show_boss_bar(main.dungeon.boss_floor, 1.0,
		ArpgBalance.BOSS["name"] if main.dungeon.boss_floor else "")
	main.hud.log("—— 地下 %d 层 ——" % main.floor_no)
	main.quests.on_reach_floor(main.floor_no)
	main.audio.play_music("boss" if main.dungeon.boss_floor else "dungeon")
	main._hud_static()
	if main._stress_n == 0:
		main._intro()
