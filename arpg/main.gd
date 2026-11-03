extends Node2D
## 「千亿魔女」地牢 ARPG 主控（战斗原型）。
## 流程：角色选择 → 随机地牢实时战斗 → 楼梯下一层 / Boss 传送门 / 暂停撤退 → 结算。
## 战斗之外的「店铺经营」环节后续接入；本文件只管地牢侧闭环。

enum State { SELECT, PLAY, SETTLE }

const SFX := {
	"cursor": "res://assets/se/Cursor1.ogg",
	"attack": "res://assets/se/Attack2.ogg",
	"skill": "res://assets/se/Attack3.ogg",
	"damage": "res://assets/se/Damage1.ogg",
	"die": "res://assets/se/Collapse3.ogg",
	"heal": "res://assets/se/Heal1.ogg",
	"fire": "res://assets/se/Fire1.ogg",
	"magic": "res://assets/se/Magic2.ogg",
}

var state := State.SELECT

## 事件引擎读：进入结算即「局已终」（事件 win/lose 与常规胜负共用此判据）
var over: bool:
	get:
		return state == State.SETTLE

## 镜头：取景算法（rig）+ 调度（director）。用 preload 常量而非全局 class_name：
## 新脚本未进 class cache 时也能引用（见 HANDOFF §6 坑 9）
const CameraRig := preload("res://arpg/camera_rig.gd")
const CameraDirector := preload("res://arpg/camera_director.gd")

var hud: ArpgHUD
var world: ArpgWorld
var player: ArpgPlayer
var dungeon: ArpgDungeon
var cam: CameraDirector         # 镜头调度器（镜头栈 + 兜底）
var camera: CameraRig           # 取景算法层（= cam.rig；外部/测试读 camera.position）

## ——— 可视化配置 ———
## 这几个是「改一下勾选/数字就能跑」的旋钮，检查器里直接调，不用改代码。
## 全部给的是"与原行为一致"的默认值，因此老存档/测试/命令行参数都不受影响。
@export_group("场景")
## 勾上后恢复 Node2D 的全部内置属性（位置/旋转/绘制等，调试用）
## 变量名必须是 ASCII：它会被写进 .tscn，而场景文件的裸标识符只接受 ASCII。
@export var show_raw_props := false:
	set(v):
		show_raw_props = v
		notify_property_list_changed()

@export_group("开局")
## 起始层：调试时直接从第 N 层开始（1 = 正常流程）
@export_range(1, 9) var start_floor := 1
## 开局队友数量。-1 = 读 balance.json 的 party.start_friends（默认行为）
@export_range(-1, 8) var start_friends := -1

@export_group("地牢")
## 地牢基准种子。0 = 每层随机（默认）；固定值 = 布局可复现（叠加层号，每层仍不同）
## 填了固定值之后，「编辑器预览」节点会画出与游戏完全相同的布局。
@export var dungeon_seed := 0:
	set(v):
		dungeon_seed = v
		# 改种子立刻重绘预览，不用手动去找预览节点勾「换一张图」
		var pv := get_node_or_null(NodePath("编辑器预览"))
		if pv != null and pv.has_method("refresh"):
			pv.refresh()

## 检查器瘦身：根节点永远在世界原点、内容全在 world 里，所以 position/rotation/scale/
## visibility/ordering/texture/material/process 这些内置属性对它没有意义。隐藏它们之后，
## 右侧第一屏就是上面这些中文配置，而不是一长串英文。只去掉 EDITOR usage，运行时不受影响。
const _HIDE_PROPS := [
	"position", "rotation", "rotation_degrees", "scale", "skew", "transform",
	"global_position", "global_rotation", "global_rotation_degrees",
	"global_scale", "global_skew", "global_transform",
	"visible", "modulate", "self_modulate", "show_behind_parent", "top_level",
	"clip_children", "light_mask", "visibility_layer",
	"z_index", "z_as_relative", "y_sort_enabled",
	"texture_filter", "texture_repeat", "material", "use_parent_material",
	"canvas_item_priority", "process_mode", "process_priority",
	"process_physics_priority", "process_thread_group",
	"physics_interpolation_mode", "auto_translate_mode", "editor_description",
]


func _validate_property(property: Dictionary) -> void:
	if show_raw_props:
		return
	if str(property.name) in _HIDE_PROPS:
		property.usage &= ~PROPERTY_USAGE_EDITOR


var char_id := "fencer"
var floor_no := 1
var bag := []            # item_id 列表（背包，上限 ArpgBalance.BAG_CAP）
var kills := 0
var _interact_target := {}   # {kind: chest/stairs/portal, node/cell}
var _full_warn_ms := 0
var rng := RandomNumberGenerator.new()

# 震屏（trauma 模型）已移入 ArpgCameraDirector：镜头写入统一走一个出口，避免多处抢写
var event_camera_lock: bool:
	get:
		return cam != null and cam.is_cinematic()

# 压测 / 基准
var _stress_n := 0
var _stress_fx := false
var _bench_s := 0.0
var _bench_t0 := 0
var _bench_frames := 0
var _fps_accum := 0.0
var _fps_n := 0
var _perf_t := 0.0
var _fx_t := 0.0

# 音频池（复用播放器 + 懒加载音源，避免每次播音效都开新节点）
var _sfx_pool := []
var _sfx_i := 0
var _sfx_cache := {}

# 队伍 / AI 队友 / 主控切换 / 拾取仲裁（需求书 §7 模块）
var party: ArpgPartyManager
var possession: ArpgPossessionManager
var arbiter: ArpgPickupArbiter
var party_root: Node2D
var _friends_n := -1          # --friends=N 覆盖（-1 = 用配置默认）
var _want_apc := false        # --apc 调试招募
var _squad_cmd_i := 0
var player_combat_t := 0.0
var flags := {}                  # 事件旗标（set_flag/if 共用）

# 事件引擎（core/events/event_system.gd，与战棋共用；接线见 docs/HANDOFF §2）
var events: SrpgEventSystem
var map_events := []             # 事件列表（地图 JSON 的 events 段）
var ui: ArpgHUD                  # 事件系统经 main.ui 弹对话（沿用战棋命名）
var events_silent := false       # CI/自动化置真：不触发事件对话（headless 无真实输入会挂起）
var _last_player_cell := Vector2i(-99, -99)
var _autoplay := false           # --autoplay 机器人测试

# RPG 元系统（背包/金币/装备/任务/商店/存档）
var rpg: ArpgRpgState
var quests: ArpgQuestManager
var shop: ArpgShop
var save_sys: ArpgSaveSystem
var settings: ArpgSettings
var audio: ArpgAudioManager
var _menu_open := false

# 热重载监视
var _watch_t := 0.0
var _balance_mtime := 0
var _map_mtime := 0


func _ready() -> void:
	_setup_input()
	hud = ArpgHUD.new()
	_slot("界面").add_child(hud)
	ui = hud
	hud.game = self
	hud.start_selected.connect(start_run)
	hud.back_to_title.connect(_back_to_title)
	hud.resume_requested.connect(_resume)
	hud.retreat_requested.connect(func(): _settle(true, "主动撤退", "带着战利品安全返回了地面。"))
	hud.show_select()
	# 全自动测试模式：godot --path . -- --autoplay（无头加 --headless）
	# 压测/基准：--stress=10000 大斗兽场刷 N 只敌人；--bench=15 跑 15 秒输出平均帧率后退出
	#           --stress-fx 高频特效轰炸（配合压测验证特效管线）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stress="):
			_stress_n = clampi(int(a.split("=")[1]), 0, 11000)
		elif a.begins_with("--bench="):
			_bench_s = float(a.split("=")[1])
		elif a == "--stress-fx":
			_stress_fx = true
	# 压测/基准/自动驾驶的自动开局统一放 _ready 末尾（rpg/save_sys/audio 基座就绪之后）
	_autoplay = "--autoplay" in OS.get_cmdline_user_args()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--friends="):
			_friends_n = clampi(int(a.split("=")[1]), 0, 64)
		elif a == "--apc":
			_want_apc = true
	# 队友节点容器（挂 main 下：换层不销毁；z=5 保证在世界地板/敌群之上可见）
	party_root = get_node_or_null(NodePath("队伍"))
	if party_root == null:
		party_root = Node2D.new()
		add_child(party_root)
	party_root.y_sort_enabled = true
	party_root.z_index = 5
	# 热重载：balance.json 保存即生效；地图改动提示 F3
	ArpgBalance.reload_data()
	_balance_mtime = _file_mtime(ArpgBalance.PATH)
	_map_mtime = _file_mtime(SrpgMapLoader.PATH)
	arbiter = ArpgPickupArbiter.new()
	arbiter.main = self
	rpg = ArpgRpgState.new()
	rpg.setup()
	quests = ArpgQuestManager.new()
	quests.setup(self)
	shop = ArpgShop.new()
	shop.setup(self)
	save_sys = ArpgSaveSystem.new()
	save_sys.setup(self)
	events = SrpgEventSystem.new(self)
	# headless / 自动驾驶没有真实键鼠输入，事件对话会无限等待 → 一律静默
	events_silent = DisplayServer.get_name() == "headless" or _autoplay
	settings = ArpgSettings.new()
	add_child(settings)
	audio = ArpgAudioManager.new()
	audio.setup(self)
	add_child(audio)
	audio.play_music("title")
	# 压测/基准自动开局（跳过选人，保证 CI 可复现）；自动驾驶机器人挂载
	if _stress_n > 0:
		start_run("fencer")
	elif _autoplay:
		var bot := ArpgAutopilot.new()
		bot.main = self
		add_child(bot)


## 取场景里预置的容器节点；没有就返回 self（headless / 直接 new 的场景也能跑）。
## 为什么要有这层：world/hud/party/camera 都是运行时 new 出来的，编辑器里原先完全看不见，
## 场景树只有一个空根节点。现在 .tscn 里预置了「世界/队伍/镜头/界面」四个空容器，
## 运行时往对应容器里挂，编辑器里就能看到清晰的分层结构。
func _slot(node_name: String) -> Node:
	var n := get_node_or_null(NodePath(node_name))
	return n if n != null else self


## 用代码注册输入映射（免改 project.godot）：键盘 + Xbox/PS 手柄通用语义键位
func _setup_input() -> void:
	var defs := {
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"move_up": [KEY_W, KEY_UP],
		"move_down": [KEY_S, KEY_DOWN],
		"attack": [KEY_J, KEY_Z],
		"skill": [KEY_K, KEY_X],
		"potion": [KEY_Q],
		"interact": [KEY_E],
	}
	for action in defs:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in defs[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)

	# —— 手柄（Godot 语义键位：A=Xbox A/PS叉, X=Xbox X/PS方块, B=Xbox B/PS圆圈, Y=Xbox Y/PS三角）——
	var face := {
		"attack": [JOY_BUTTON_A],       # A / 叉：普攻
		"skill": [JOY_BUTTON_X],        # X / 方块：技能
		"interact": [JOY_BUTTON_B],     # B / 圆圈：互动
		"potion": [JOY_BUTTON_Y],       # Y / 三角：药水
	}
	for action in face:
		for b in face[action]:
			var jb := InputEventJoypadButton.new()
			jb.button_index = b
			InputMap.action_add_event(action, jb)
	# 左摇杆 + 十字键移动
	var axes := [
		["move_left", JOY_AXIS_LEFT_X, -1.0], ["move_right", JOY_AXIS_LEFT_X, 1.0],
		["move_up", JOY_AXIS_LEFT_Y, -1.0], ["move_down", JOY_AXIS_LEFT_Y, 1.0],
	]
	for a in axes:
		var m := InputEventJoypadMotion.new()
		m.axis = a[1]
		m.axis_value = a[2]
		InputMap.action_add_event(a[0], m)
	var dpad := {
		"move_left": JOY_BUTTON_DPAD_LEFT, "move_right": JOY_BUTTON_DPAD_RIGHT,
		"move_up": JOY_BUTTON_DPAD_UP, "move_down": JOY_BUTTON_DPAD_DOWN,
	}
	for action in dpad:
		var db := InputEventJoypadButton.new()
		db.button_index = dpad[action]
		InputMap.action_add_event(action, db)
	# 扳机：RT 攻击 / LT 技能
	var rt := InputEventJoypadMotion.new()
	rt.axis = JOY_AXIS_TRIGGER_RIGHT
	rt.axis_value = 1.0
	InputMap.action_add_event("attack", rt)
	var lt := InputEventJoypadMotion.new()
	lt.axis = JOY_AXIS_TRIGGER_LEFT
	lt.axis_value = 1.0
	InputMap.action_add_event("skill", lt)
	# Start = 暂停（并入 ui_cancel）
	var st := InputEventJoypadButton.new()
	st.button_index = JOY_BUTTON_START
	InputMap.action_add_event("ui_cancel", st)
	# 队伍/主控/调试
	var more := {
		"possession_next": [KEY_TAB],
		"squad_cmd": [KEY_T],
		"debug_panel": [KEY_F1],
		"save_party": [KEY_F9],
		"load_party": [KEY_F10],
		"char_menu": [KEY_C],
		"skill2": [KEY_L],
		"reload_balance": [KEY_F2],
		"reload_map": [KEY_F3],
		"restart_run": [KEY_F4],
	}
	for action in more:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in more[action]:
			var ke := InputEventKey.new()
			ke.physical_keycode = key
			InputMap.action_add_event(action, ke)
	# 摇杆死区
	for a2 in ["move_left", "move_right", "move_up", "move_down"]:
		InputMap.action_set_deadzone(a2, 0.28)


## 手柄震动（Xbox / PS；未连接手柄时静默跳过）
func rumble(weak: float, strong: float, dur: float) -> void:
	if state != State.PLAY:
		return
	var scale := float(settings.get_value("rumble")) if settings != null else 1.0
	if scale <= 0.001:
		return
	for d in Input.get_connected_joypads():
		Input.start_joy_vibration(d, weak * scale, strong * scale, dur)


# ———————— 开局 / 楼层 ————————

func start_run(id: String) -> void:
	char_id = id
	floor_no = maxi(1, start_floor)      # 可视化配置：起始层（默认 1，等价于原行为）
	kills = 0
	rpg.setup()   # 刷新背包容量/任务表；金币与物品跨局保留（商店循环）
	if not rpg.inventory.has("potion"):
		rpg.inventory.add("potion", 3)
	# 重新开局：清空旧队伍
	if party != null:
		for f in party.friends:
			f.queue_free()
		party.friends.clear()
	hud.hide_select()
	hud.hide_pause()
	_load_map_events()
	build_floor()
	if _stress_n == 0:
		_recruit_party()
	hud.log("带 3 瓶回复药水出发。祝好运！")


## P0：招募 AI 队友（默认 2 名，其他角色模板）；--friends=N / --apc 可覆盖
func _recruit_party() -> void:
	var want := int(ArpgPartyConfig.cfg("start_friends"))
	if start_friends >= 0:               # 可视化配置优先于 balance.json
		want = start_friends
	if _friends_n >= 0:                  # 命令行 --friends=N 优先级最高
		want = _friends_n
	var others := []
	for cid in ArpgBalance.CHARS:
		if cid != char_id:
			others.append(cid)
	var recruited := 0
	for cid in others:
		if recruited >= want:
			break
		var cell := dungeon.start_cell + Vector2i(1 + recruited, 1)
		if party.recruit_char(cid, cell) != null:
			recruited += 1
	if _want_apc:
		party.recruit_apc("mercenary", dungeon.start_cell + Vector2i(-1, 1))


func build_floor() -> void:
	# 旧玩家节点会随旧 world 一起释放：先留引用 + 快照成长数据。
	# （玩家是节点，等级/经验/装备加成只活在节点上；重建节点若不搬运，下到第 2 层
	#   就直接掉回 1 级——这是"进入第二层异常"的另一半。）
	var prev_player = player
	var carry := {}
	if prev_player != null and is_instance_valid(prev_player):
		carry = {"level": prev_player.level, "xp": prev_player.xp}
	if is_instance_valid(world):
		world.queue_free()
	world = null
	player = null
	rng.randomize()
	dungeon = ArpgDungeon.new()
	if _stress_n > 0:
		dungeon.generate_arena()
	else:
		dungeon.generate(floor_no, dungeon_seed + floor_no * 7919 if dungeon_seed != 0 else -1)

	world = ArpgWorld.new()
	_slot("世界").add_child(world)
	world.build(dungeon, self)
	world.spawn_player(char_id)
	player = world.player
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
	# 它随旧 world 被 queue_free → 变成已释放对象。于是：
	#   1. possession.is_possessed(新玩家) 恒为 false → 新玩家被当成 AI 单位，键盘鼠标全部失效
	#   2. main 取不到有效焦点 → 镜头彻底停止跟随（表现为"镜头调度再次失效"）
	#   3. HUD / 队友 LOD 每帧读 current_unit.position → 持续报错
	# 判据改为"无效或被换掉"，而不是"为空"。
	if party == null:
		party = ArpgPartyManager.new()
		party.setup(self)
		add_child(party)
	party.build_nav(dungeon)
	if possession == null:
		possession = ArpgPossessionManager.new()
		possession.setup(self, player)
	else:
		var cur = possession.current_unit
		if cur == null or not is_instance_valid(cur) or cur == prev_player:
			possession.current_unit = player

	# 镜头：调度器（director）复用节点，每层只重设边界；rig 由调度器持有
	if cam == null:
		cam = CameraDirector.new()
		_slot("镜头").add_child(cam)
		cam.focus_fallback = Callable(self, "_camera_focus")
	cam.setup(self, dungeon)
	camera = cam.rig
	camera.make_current()
	var c0 = _camera_focus()
	cam.bind(c0, party.friends)
	cam.reset(c0.position if c0 != null else player.position)

	if _stress_n == 0:
		party.revive_all_on_floor()
		# 开局落点：按槽位环形展开且必须可走。
		# 旧实现随机 ±50 偏移不校验 → 贴墙开局直接把队友放进墙里，一开局就在"卡住"状态。
		for f in party.friends:
			if not f.dead:
				var ang := float(party.slot_index(f)) * (TAU / 8.0) + 0.5
				var p: Vector2 = player.position + Vector2.RIGHT.rotated(ang) * 44.0
				var c := Vector2i((p / float(ArpgData.TILE)).floor())
				if not party._is_open(c):
					p = ArpgDungeon.cell_to_pos(party._nearest_open(c))
				f.teleport_to(p)
	# 换层后刷新队友的 world/main 引用（party_root 不随楼层销毁）
	for f in party.friends:
		f.world = world
		f.main = self

	if _stress_n > 0:
		_setup_stress()
	elif dungeon.boss_floor:
		var room: Rect2i = dungeon.rooms[0]
		world.spawn_mob("boss", Vector2i(room.end.x - 4, room.position.y + room.size.y / 2), false, true)
		for i in 2:
			world.spawn_mob("imp", dungeon.random_cell_in(room), false, false)
		hud.log("魔王的气息逼近——击败它就能凯旋！")
	else:
		# 敌人：逐个随机房间（跳过出发房间；rooms 已按距起点距离排序，越靠后越深）
		var count := ArpgBalance.floor_enemy_count(floor_no)
		var pool := ArpgBalance.floor_pool(floor_no)
		var room_hi := maxi(dungeon.rooms.size() - 1, 1)
		for i in count:
			var room: Rect2i = dungeon.rooms[0]
			if dungeon.rooms.size() > 1:
				room = dungeon.rooms[rng.randi_range(1, room_hi)]
			var cell := dungeon.random_cell_in(room)
			if ArpgDungeon.cell_to_pos(cell).distance_to(ArpgDungeon.cell_to_pos(dungeon.start_cell)) < 200.0:
				continue
			var tpl_id := ArpgBalance.weighted_pick(pool, dungeon.rng)
			world.spawn_mob(tpl_id, cell, rng.randf() < ArpgBalance.ELITE_CHANCE, false)
		# 宝箱 ×2：优先放叶节点房间（只连一条走廊的尽头），跑一趟有回报
		for i in 2:
			world.spawn_chest(dungeon.random_cell_in(dungeon.loot_room(rng)))
		# 楼梯放在生成器算好的最远房间（stair_cell），不再依赖 rooms 的下标含义
		world.set_stairs(dungeon.stair_cell if dungeon.stair_cell.x >= 0 \
			else dungeon._center(dungeon.rooms[dungeon.rooms.size() - 1]))

	state = State.PLAY
	hud.play_hud.visible = true
	hud.show_boss_bar(dungeon.boss_floor, 1.0, ArpgBalance.BOSS["name"] if dungeon.boss_floor else "")
	hud.log("—— 地下 %d 层 ——" % floor_no)
	quests.on_reach_floor(floor_no)
	audio.play_music("boss" if dungeon.boss_floor else "dungeon")
	_hud_static()
	if _stress_n == 0:
		_intro()


## 地图 JSON 只取事件列表（重开一局 / F3 重载本层都会重新读取）
func _load_map_events() -> void:
	var mdict: Dictionary = SrpgMapLoader.load_file(SrpgMapLoader.PATH)
	map_events = mdict.get("events", [])


## 楼层开场：横幅后触发「回合开始」事件（楼层号 = 事件引擎的回合数：
## 地图事件 1 = turn 1 开场对话；事件 2 = turn 3 增援，在地下 3 层触发）
func _intro() -> void:
	if events_silent:
		return
	await get_tree().create_timer(0.3).timeout
	if state != State.PLAY:
		return
	await hud.show_banner("地下 %d 层" % floor_no, Color(0.16, 0.32, 0.65))
	if events != null:
		await events.on_phase_start("player", floor_no)


func _hud_static() -> void:
	pass  # 数值每帧在 _process 里刷新


## 压测斗兽场：洗牌全图地板格批量刷怪；无敌观察态；--bench 时自动计时退出
func _setup_stress() -> void:
	var cells := dungeon.floor_cells()
	var center := ArpgDungeon.cell_to_pos(dungeon.start_cell)
	for i in range(cells.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := cells[i]
		cells[i] = cells[j]
		cells[j] = t
	var pool := ArpgBalance.floor_pool(3)
	var spawned := 0
	for c in cells:
		if spawned >= _stress_n:
			break
		if ArpgDungeon.cell_to_pos(c).distance_to(center) < 240.0:
			continue
		world.spawn_mob(ArpgBalance.weighted_pick(pool, dungeon.rng), c, rng.randf() < 0.05, false)
		spawned += 1
	player.iframes = 1e9   # 基准不被死亡打断
	hud.log("压测模式：%d 只敌人 · 无敌观察态" % spawned)
	print("[STRESS] spawned=%d" % spawned)
	if _bench_s > 0.0:
		_bench_t0 = Time.get_ticks_usec()
		_bench_frames = 0


# ———————— 每帧 ————————

## 镜头焦点：主控单位 → 玩家 → 无。
## 单点取焦点，是为了让"节点被释放/换层/切人"这三种情况都只有一条判定路径。
func _camera_focus() -> Node2D:
	if possession != null and possession.current_unit != null \
			and is_instance_valid(possession.current_unit):
		return possession.current_unit
	if player != null and is_instance_valid(player):
		return player
	return null


func _process(delta: float) -> void:
	_hot_reload_watch(delta)
	# —— 镜头调度：放在流程状态判断之前 ——
	# 事件镜头/结算镜头在非 PLAY 状态下也要能推进；否则状态一变镜头就"冻住"
	if cam != null:
		if state == State.PLAY:
			cam.bind(_camera_focus(), party.friends if party != null else [])
		cam.update(delta)
	if state != State.PLAY:
		return
	# 玩家战斗状态计时（队友 AI 参战判定用）
	if player_combat_t > 0.0:
		player_combat_t -= delta

	# 性能 HUD + 队伍面板（每 0.5s 刷新）
	_perf_t -= delta
	if _perf_t <= 0.0:
		_perf_t = 0.5
		hud.set_perf(Engine.get_frames_per_second(), world.mob_count(), world.projs.count, world.mobs.sim_ms)
		if party != null:
			var cf0 = _camera_focus()
			hud.set_gold(rpg.gold)
			hud.update_party(party_rows(), cf0.uid if cf0 != null else "")
			hud.set_debug_lines(_debug_rows())
	# 压测特效轰炸（验证特效管线上限池）
	if _stress_fx:
		_fx_t -= delta
		if _fx_t <= 0.0:
			_fx_t = 0.06
			for k in 3:
				if world.mob_count() > 0:
					var idx := rng.randi_range(0, world.mob_count() - 1)
					world.spawn_nova(world.mobs.pos[idx], Color(1.0, randf_range(0.3, 0.8), 0.3))
					world.spawn_hit_spark(world.mobs.pos[idx] + Vector2(20, 0), Color(1, 0.9, 0.6))
	# 基准计时：到点输出平均帧率并以阈值决定退出码
	if _bench_s > 0.0:
		_bench_frames += 1
		var el := float(Time.get_ticks_usec() - _bench_t0) / 1e6
		if el >= _bench_s:
			var avg := float(_bench_frames) / el
			print("[BENCH] %.1fs 平均帧率 %.1f FPS · 敌 %d · 敌群模拟 %.2fms/帧" % [
				el, avg, world.mob_count(), world.mobs.sim_ms])
			get_tree().quit(0 if avg >= 50.0 else 1)

	if Input.is_action_just_pressed("potion"):
		drink_potion()
	if Input.is_action_just_pressed("interact"):
		_do_interact()
	_update_interact_prompt()
	if player != null:
		var potions := 0
		for it in bag:
			if it == "potion":
				potions += 1
		hud.update_bars(player, bag.size(), potions, floor_no, dungeon.boss_floor)

	# 事件钩子：玩家跨格触发 zone 事件（引擎内有矩形/阵营过滤，重复调用安全）
	if events != null and not events_silent and player != null \
			and is_instance_valid(player) and player.cell != _last_player_cell:
		_last_player_cell = player.cell
		events.on_unit_moved(player)


## 顿帧：短暂压低时间流速，用「真实时间」计时恢复（挂起世界一瞬，强调命中）
func hit_stop(dur := 0.05, sc := 0.1) -> void:
	if state != State.PLAY or get_tree().paused:
		return
	Engine.time_scale = sc
	get_tree().create_timer(dur, true, false, true).timeout.connect(func():
		if Engine.time_scale < 1.0:
			Engine.time_scale = 1.0)


func _update_interact_prompt() -> void:
	_interact_target = {}
	var text := ""
	var cur = _camera_focus()
	if cur == null or cur.dead:
		hud.set_prompt("")
		return
	for c in world.chests:
		if is_instance_valid(c) and not c.opened and (c.position - cur.position).length() < 44.0:
			_interact_target = {"kind": "chest", "node": c}
			text = "E 开箱"
			break
	if stairs_dist() < 40.0:
		_interact_target = {"kind": "stairs"}
		text = "E 下到第 %d 层" % (floor_no + 1)
	if world.portal_cell.x >= 0 and world.portal_dist(cur.position) < 46.0:
		_interact_target = {"kind": "portal"}
		text = "E 进入传送门（凯旋结算）"
	hud.set_prompt(text)


func stairs_dist() -> float:
	if world.stairs_cell.x < 0:
		return INF
	var cur = _camera_focus()
	if cur == null:
		return INF
	return ArpgDungeon.cell_to_pos(world.stairs_cell).distance_to(cur.position)


func _do_interact() -> void:
	match _interact_target.get("kind", ""):
		"chest":
			open_chest(_interact_target["node"])
		"stairs":
			floor_no += 1
			play_sfx("cursor")
			build_floor()
			# 落地时补一道传送门：换层瞬间整层重建，必须在新的 world 上播
			world.spawn_pxfx("portal", world.player.position, {"scale": 0.9, "speed": 1.4, "once": true})
		"portal":
			_settle(true, "凯旋而归！", "魔王已被讨伐，战利品铺满行囊。")


# ———————— 宝箱 / 陷阱 ————————

func open_chest(chest: ArpgChest) -> void:
	chest.opened = true
	chest.queue_redraw()
	play_sfx("cursor")
	if rng.randf() < ArpgBalance.TRAP_CHANCE:
		var trap := rng.randi_range(0, 2)
		match trap:
			0:
				player.set_stun(2.5)
				world.spawn_popup("陷阱！麻痹", player.position, Color(1, 0.8, 0.3))
				hud.log("是陷阱箱！毒针麻痹了你……")
			1:
				hud.log("是陷阱箱！魔物从暗处涌出！")
				for i in 3:
					var cell := dungeon.random_cell_in(_near_room(player.position))
					var e_pos := ArpgDungeon.cell_to_pos(cell)
					# 旧实现调用了不存在的 world.spawn_enemy / world.enemies（每层必崩）：
					# 敌群是 SoA 数据层，只能走 spawn_mob + mobs.aggro[]
					var mi: int = world.spawn_mob("imp", cell, false, false)
					if mi >= 0:
						world.mobs.aggro[mi] = 1
					play_sfx("die")
					world.spawn_popup("召唤！", e_pos, Color(1, 0.4, 0.3))
			2:
				var cell2 := dungeon.random_cell_in(Rect2i())
				player.position = ArpgDungeon.cell_to_pos(cell2)
				player.iframes = 1.0
				world.spawn_popup("陷阱！传送", player.position, Color(0.7, 0.6, 1.0))
				hud.log("是陷阱箱！被随机传送了……")
		add_shake(0.42)
		rumble(0.5, 0.9, 0.4)
		return
	# 正常掉落 1~3 件
	world.spawn_pxfx("burst", chest.position, {"scale": 0.5, "tint": Color(1, 0.85, 0.4, 0.95)})
	world.burst(chest.position + Vector2(0, -6), ArpgTex.tex(ArpgWorld.FX_PARTICLE_PATH), Color(1, 0.9, 0.5), 8, 130.0, 0.4, 0.08)
	var n := rng.randi_range(1, 3)
	for i in n:
		var item := ArpgBalance.weighted_pick(ArpgBalance.loot_weight(floor_no), rng)
		world.spawn_pickup(chest.position, item)
	hud.log("宝箱开启：获得 %d 件战利品！" % n)


func _near_room(pos: Vector2) -> Rect2i:
	for r in dungeon.rooms:
		if Rect2i(r).grow(1).has_point(Vector2i((pos / float(ArpgData.TILE)).floor())):
			return r
	return dungeon.rooms[0]


# ———————— 拾取 / 消耗 / 掉落 ————————

func try_pickup(item_id: String) -> bool:
	if not rpg.inventory.add(item_id):
		bag_full_warn()
		return false
	quests.on_pickup(item_id)
	var iname: String = ArpgBalance.ITEMS[item_id]["name"]
	hud.log("获得 %s（%d/%d 格）" % [iname, rpg.inventory.used(), rpg.inventory.cap])
	play_sfx("cursor")
	return true


## 玩家自动拾取回调（拾取系统在玩家身边触发）
func on_player_pickup(item_id: String) -> void:
	try_pickup(item_id)


## 拾取仲裁回调：AI 队友收取（共享背包，日志注明去向——需求书 §5.5）
func try_pickup_for(unit, drop_id: int) -> bool:
	var item_str: String = world.pickups.item_of(drop_id)
	if not rpg.inventory.add(item_str):
		bag_full_warn()
		return false
	var item_id: String = world.pickups.take_by_id(drop_id)
	quests.on_pickup(item_id)
	var iname: String = ArpgBalance.ITEMS[item_id]["name"]
	hud.log("%s 拾取 %s（%d/%d 格）" % [(unit.uid if unit != null else "?"), iname, rpg.inventory.used(), rpg.inventory.cap])
	play_sfx("cursor", -10.0)
	return true


## 队友 AI 参战判定：玩家受击或近身处有敌人
func player_in_combat() -> bool:
	if player != null and player.in_combat_until > 0.0:
		return true
	if world != null and world.mobs != null and player != null:
		return world.mobs.nearest(player.position, 260.0) >= 0
	return false


func on_possession_changed(_u, _prev) -> void:
	if hud != null and party != null:
		hud.update_party(party_rows())


func party_rows() -> Array:
	var rows := []
	if party == null:
		return rows
	for f in party.friends:
		rows.append({"name": f.unit_name, "uid": f.uid, "hp": f.hp, "max": f.max_hp,
			"cmd": f.command, "state": f.state, "apc": f.is_apc, "dead": f.dead})
	return rows


## 调试面板内容（需求书 §5.8）：AI 状态 / 指令 / 目标 / 拾取仲裁 / 主控
func _toggle_menu() -> void:
	_menu_open = not _menu_open
	if _menu_open:
		get_tree().paused = true
		hud.show_menu_ui(_menu_snapshot())
	else:
		get_tree().paused = false
		hud.hide_menu_ui()


func _menu_snapshot() -> Dictionary:
	return {"rpg": rpg, "player": player, "party": party, "quests": quests, "shop": shop, "save_sys": save_sys}


func _menu_close() -> void:
	if _menu_open:
		_menu_open = false
		get_tree().paused = false
		hud.hide_menu_ui()


func _debug_rows() -> Array:
	var out := []
	out.append("金币 %dG · 背包 %d/%d 格 · 任务 %d" % [rpg.gold, rpg.inventory.used(), rpg.inventory.cap, quests.rows().size()])
	if player != null:
		out.append("[P] %s %s cmd=%s state=%s HP=%d/%d" % [
			player.uid, player.uname, player.command, player.state, player.hp, player.max_hp])
	if party != null:
		for f in party.friends:
			out.append("[%s] %s %s cmd=%s state=%s HP=%d/%d tgt=%d" % [
				"APC" if f.is_apc else "F", f.uid, f.unit_name, f.command, f.state,
				f.hp, f.max_hp, f.ai_target])
	if arbiter != null and not arbiter.claims.is_empty():
		out.append("拾取认领: %s" % str(arbiter.claims))
	var cf = _camera_focus()
	out.append("主控: %s" % (cf.uid if cf != null else "?"))
	if world != null and world.mobs != null:
		out.append("AI 质量: 卡住 %.0f%% · 堆叠 %.0f%% · 敌群 %.2fms" % [
			world.mobs.stuck_ratio * 100.0, world.mobs.stack_ratio * 100.0, world.mobs.sim_ms])
	if camera != null:
		out.append(camera.debug_info())
	if dungeon != null:
		out.append("地牢: " + dungeon.debug_stats())
	if hud != null and hud.minimap != null:
		out.append(hud.minimap.debug_info())
	return out


## 调试存档（F9/F10）：队伍稳定 ID + 指令 + 状态往返（需求书 §6 存档要求）
func _save_party() -> void:
	save_sys.save_game()


func _load_party() -> void:
	var err: String = save_sys.load_game()
	if err != "":
		hud.log("读档失败：" + err)
	_menu_close()


func drink_potion() -> void:
	var u = _camera_focus()
	if u == null:
		return
	if not rpg.inventory.remove("potion", 1):
		hud.log("没有药水了！")
		return
	var heal: int = int(ArpgBalance.ITEMS["potion"]["heal"])
	u.hp = mini(u.max_hp, u.hp + heal)
	u.heal_flash()
	world.spawn_popup("+%d" % heal, u.position, Color(0.5, 1, 0.55))
	world.spawn_nova(u.position, Color(0.5, 1, 0.6))
	world.spawn_pxfx("heal", u.position + Vector2(0, -6), {"scale": 0.6, "speed": 1.4})
	hud.log("%s 喝下回复药水（剩 %d 瓶）" % ["你" if u == player else u.unit_name, _potion_count()])
	play_sfx("heal")


func _potion_count() -> int:
	return rpg.inventory.count("potion")


## 掉落结算：金币/宝石到达角色时入账（结算时机由 drops.settle_mode 控制）
func on_drop_collected(_kind: int, value: int) -> void:
	if value <= 0:
		return
	rpg.gold += value


func on_mob_dead(i: int) -> void:
	kills += 1
	play_sfx("die")
	if player != null and is_instance_valid(player):
		player.gain_xp(world.mobs.xp[i])
	if party != null:
		party.gain_xp_all(world.mobs.xp[i])
	world.spawn_death_poof(world.mobs.pos[i], Color(0.9, 0.85, 0.8))
	# 金币/宝石爆量：这只怪"值多少"仍由 gold_drop_min/max 决定（经济不变），
	# 掉多少颗、怎么散、怎么吸由 drops 段配置
	var gold_total := rng.randi_range(int(ArpgBalance.data.get("gold_drop_min", 2)),
		int(ArpgBalance.data.get("gold_drop_max", 6)))
	world.spawn_drops(world.mobs.pos[i], gold_total, world.mobs.elite[i] == 1, world.mobs.boss[i] == 1)
	if rng.randf() < 0.6:
		world.spawn_pickup(world.mobs.pos[i], ArpgBalance.weighted_pick(ArpgBalance.drop_weight(floor_no), rng))
	if world.mobs.boss[i] == 1:
		add_shake(0.72)
		rumble(0.7, 1.0, 0.6)
		hud.log("魔王倒下了！传送门出现在它倒下的地方——")
		audio.play_music("town")
		world.set_portal(world.mobs.pos[i])


# ———————— 暂停 / 结算 ————————

## 热重载监视（每秒轮询 mtime）：balance.json 保存即生效；地图改动提示 F3
func _hot_reload_watch(delta: float) -> void:
	_watch_t -= delta
	if _watch_t > 0.0:
		return
	_watch_t = 1.0
	var bm := _file_mtime(ArpgBalance.PATH)
	if bm != _balance_mtime and bm > 0:
		_balance_mtime = bm
		var ok := ArpgBalance.reload_data()
		if world != null and is_instance_valid(world) and world.mobs != null:
			world.mobs.apply_balance()
		hud.log("平衡数据已热重载%s" % ("" if ok else "（解析失败，用内置默认）"))
		print("[BALANCE] hot reload ok=", ok)
	var mm := _file_mtime(SrpgMapLoader.PATH)
	if mm != _map_mtime and mm > 0:
		_map_mtime = mm
		if state == State.PLAY:
			hud.log("地图已修改 —— 按 F3 重载本层（保留队伍）")


func _file_mtime(path: String) -> int:
	return FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0


func _manual_reload_balance() -> void:
	_balance_mtime = _file_mtime(ArpgBalance.PATH)
	var ok := ArpgBalance.reload_data()
	if world != null and is_instance_valid(world) and world.mobs != null:
		world.mobs.apply_balance()
	hud.log("平衡数据已手动重载%s" % ("" if ok else "（解析失败，用内置默认）"))


## 事件命令：镜头调度（压入"定点镜头"到调度器，到期自动弹栈回归跟随）
## 调用方（事件引擎）await 的是"这个镜头占用的时长"，所以这里等到 dur 再返回。
func event_camera_focus(pos: Vector2, dur: float) -> void:
	var d := maxf(0.25, dur)
	if cam != null:
		cam.play_focus_point(pos, d)
	await get_tree().create_timer(d).timeout


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if state == State.PLAY and not get_tree().paused:
			get_tree().paused = true
			hud.show_pause()
		elif get_tree().paused:
			_resume()
		return
	if state != State.PLAY or get_tree().paused:
		return
	if event.is_action_pressed("possession_next"):
		possession.cycle()
	elif event.is_action_pressed("squad_cmd"):
		_squad_cmd_i = (_squad_cmd_i + 1) % 3
		party.set_squad_command(["active", "follow", "hold"][_squad_cmd_i])
	elif event.is_action_pressed("debug_panel"):
		hud.toggle_debug()
	elif event.is_action_pressed("char_menu"):
		_toggle_menu()
	elif event.is_action_pressed("save_party"):
		_save_party()
	elif event.is_action_pressed("load_party"):
		_load_party()
	elif event.is_action_pressed("reload_balance"):
		_manual_reload_balance()
	elif event.is_action_pressed("reload_map"):
		build_floor()
		_map_mtime = _file_mtime(SrpgMapLoader.PATH)
		hud.log("地图已热重载（保留队伍状态）")
	elif event.is_action_pressed("restart_run"):
		start_run(char_id)


func _resume() -> void:
	get_tree().paused = false
	hud.hide_pause()


func _settle(win: bool, title: String, flavor: String) -> void:
	if state == State.SETTLE:
		return
	_resume()
	state = State.SETTLE
	hud.play_hud.visible = false
	hud.show_boss_bar(false, 0.0, "")
	# 商品盘点（死亡折损一半）
	var counts := {}
	for r in rpg.inventory.rows():
		if r["kind"] == "goods":
			counts[r["id"]] = counts.get(r["id"], 0) + int(r["count"])
	var lines := []
	var total := 0
	for id in counts:
		var n: int = counts[id]
		if not win:
			n = int(n * (1.0 - ArpgBalance.DEATH_LOSS))
		if n <= 0:
			continue
		var itpl: Dictionary = ArpgBalance.ITEMS[id]
		total += n * int(itpl["value"])
		lines.append("%s ×%d —— %d G" % [itpl["name"], n, n * int(itpl["value"])])
	var goods_text := "\n".join(lines) if lines.size() > 0 else "（空手而归……）"
	var stats := "%s\n到达：地下 %d 层    击败：%d 只    等级：Lv %d" % [
		flavor, floor_no, kills, player.level]
	hud.show_settle(title, Color(1, 0.95, 0.75) if win else Color(1, 0.55, 0.5), stats, goods_text, total)


func on_player_dead() -> void:
	play_sfx("die")
	add_shake(0.6)
	_settle(false, "倒在了地下 %d 层……" % floor_no, "商品在逃亡中散失了一半。")


# ———————— 事件引擎落点（core/events/event_system.gd 调用） ————————

## 事件命令 win / lose 的落点
func _game_over(win: bool) -> void:
	_settle(win, "凯旋而归！" if win else "倒在了地牢里……",
		"带着战利品返回了地面。" if win else "商品在逃亡中散失了一半。")


## 事件命令 spawn 的落点（与压测刷怪共用世界）。
## 地图事件的格子对不上随机地牢地板（可能是墙）时，就近改刷在玩家所在房间的地板上。
func spawn_units(tpl_id: String, cells: Array) -> void:
	if world == null or not ArpgBalance.ENEMIES.has(tpl_id):
		return
	var anchor := player.position if player != null else ArpgDungeon.cell_to_pos(dungeon.start_cell)
	for c in cells:
		var cell := Vector2i(int(c[0]), int(c[1]))
		if not dungeon.is_floor(cell):
			cell = dungeon.random_cell_in(_near_room(anchor))
		world.spawn_mob(tpl_id, cell, false, false)
		world.spawn_nova(ArpgDungeon.cell_to_pos(cell), Color(0.65, 0.9, 1.0))


func _back_to_title() -> void:
	state = State.SELECT
	if audio != null:
		audio.play_music("title")
	if is_instance_valid(world):
		world.queue_free()
	world = null
	player = null
	hud.show_select()


## 震屏入口：v 为 trauma 强度 0~1（0.15 轻拍 / 0.35 受击 / 0.7 大事件）
func add_shake(v: float) -> void:
	var scale := float(settings.get_value("screen_shake")) if settings != null else 1.0
	if cam != null:
		cam.add_shake(v * scale)


func play_sfx(sname: String, db: float = -6.0) -> void:
	audio.play_sfx(sname, db)


func bag_full_warn() -> void:
	var now := Time.get_ticks_msec()
	if now - _full_warn_ms > 1600:
		_full_warn_ms = now
		hud.log("背包已满！（上限 %d）" % ArpgBalance.BAG_CAP)
