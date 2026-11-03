@tool
extends Node2D
## 场景可视化预览层（**只在编辑器里存在**，运行时第一帧即自毁，零开销）。
##
## 为什么需要它：本作的场景内容（地牢地形 / 敌群 / 玩家 / HUD）全部由 `main.gd` 在
## `_ready()` 里用代码生成，`main.tscn` 里原本只有一个空的 `Node2D` 根节点。而未标记
## `@tool` 的脚本在编辑器里根本不会执行 `_ready()`，于是编辑器 2D 视图一片空白：
## 既看不出地图形状，也没法在可视化界面里调参数。
##
## 这一层把「生成结果」直接画进 2D 视口：
##   · 浅灰地板 + 深灰墙体 → 迷宫整体轮廓一眼可见；
##   · 房间按类型描边（绿=出发 / 黄=楼梯 / 橙=宝箱房 / 白=普通）并标序号；
##   · 起点圆点、楼梯方框、宝箱菱形；
##   · 顶部信息条显示层号 / 尺寸 / 房间数 / 可达率。
##
## 所有参数都是中文 `@export`，勾一下就能重新随机，不用改代码、不用跑游戏。
## 编辑器与运行时的唯一约定是「预览层不参与任何游戏逻辑」，因此它可随时删掉。

const Dungeon := preload("res://arpg/dungeon_gen.gd")
const Balance := preload("res://arpg/balance.gd")

const TILE := 32

# —— 灰白配色（与游戏内小地图同一套色系，编辑器里看得清又不刺眼）——
const COL_BG := Color(0.145, 0.155, 0.176)          # 墙体 / 底色（深灰）
const COL_FLOOR := Color(0.78, 0.80, 0.84)          # 地板（浅灰）
const COL_ROOM_NORMAL := Color(1, 1, 1, 0.22)       # 普通房间描边
const COL_ROOM_START := Color(0.36, 0.92, 0.55)     # 出发房（绿）
const COL_ROOM_STAIRS := Color(1, 0.84, 0.35)       # 楼梯房（黄）
const COL_ROOM_LOOT := Color(1, 0.68, 0.32)         # 宝箱房（橙）
const COL_TEXT := Color(0.90, 0.93, 0.97)
const COL_PANEL := Color(0.055, 0.065, 0.082, 0.88)

@export_group("地牢")
## 预览哪一层（1 = 第一层；地牢尺寸随深度变化，越深越大）
@export var floor_no := 1:
	set(v):
		floor_no = clampi(v, 1, 99)
		_rebuild()

## 生成种子：同一种子永远得到同一张图，改数值即可换图（便于截图与复现 bug）
@export var seed_val := 20261103:
	set(v):
		seed_val = v
		_rebuild()

## 跟随根节点 ArpgMain 的「地牢种子」：种子固定时，预览的这一层就是游戏里真实生成的那一层
@export var follow_game := true

## 勾一下 = 换一张随机图（用布尔量做按钮：Godot 检查器最顺手的「立即执行」方式）
@export var regenerate_now := false:
	set(v):
		if v:
			seed_val = randi() % 1000000
			_rebuild()
		regenerate_now = false

@export_group("显示")
## 是否填充墙体（关掉只看地板，画面更亮）
@export var show_walls := true:
	set(v):
		show_walls = v
		queue_redraw()

## 是否画房间边框与序号
@export var show_rooms := true:
	set(v):
		show_rooms = v
		queue_redraw()

## 是否画起点 / 楼梯 / 宝箱房标记
@export var show_marks := true:
	set(v):
		show_marks = v
		queue_redraw()

## 是否画顶部信息条（层号 / 尺寸 / 房间数 / 可达率）
@export var show_info := true:
	set(v):
		show_info = v
		queue_redraw()

## 整体不透明度：调到 0.3 可以把预览当"底图"叠在自己摆的东西下面
@export_range(0.0, 1.0, 0.05) var opacity := 1.0:
	set(v):
		opacity = clampf(v, 0.0, 1.0)
		self_modulate = Color(1, 1, 1, opacity)


var _d = null                 # ArpgDungeon
var _font: Font
var _building := false
var _shown_floor := 1         # 实际生成用的层号（跟随模式下可能与参数不同）
var _shown_seed := 0          # 实际生成用的种子
var _synced := false          # 是否与游戏配置一致


func _ready() -> void:
	if not Engine.is_editor_hint():
		# 运行时这一层没有意义：直接销毁，不占节点、不进绘制
		queue_free()
		return
	_font = _make_font()
	self_modulate = Color(1, 1, 1, opacity)
	_rebuild()


## 供根节点调用：改了「地牢种子 / 起始层」之后立刻重绘预览
func refresh() -> void:
	_rebuild()


## 编辑器里的中文字体：Godot 默认字体不含 CJK，必须显式取系统字体，否则数字之外全是方块
func _make_font() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "SimHei",
		"Noto Sans CJK SC", "Source Han Sans SC", "sans-serif",
	])
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	return f


## 重新生成预览图。属性 setter 在「节点还没进树」时就会被调用（@export 初始化），
## 所以三道保护缺一不可：只在编辑器、已在树内、不在重入中。
func _rebuild() -> void:
	if not Engine.is_editor_hint() or _building or not is_inside_tree():
		return
	_building = true
	# 编辑器里静态变量可能还没完成初始化（@tool 首次加载的时序问题）。若不显式重载，
	# MAX_FLOOR 可能读成 0，而 generate() 里判据是 `floor >= MAX_FLOOR` ——
	# 于是第 1 层被当成 Boss 层生成，画出来就是「一间大房 + 一个起点」，
	# 跟游戏里的迷宫完全对不上。这行是预览与游戏一致的前提。
	Balance.reload_data()
	# 双重兜底：reload 若失败，MAX_FLOOR 可能停在未初始化值。而 generate() 内部的判据是
	# `floor >= MAX_FLOOR`，只要它是 0 或 1，任何层都会被当成 Boss 层 →
	# 画出来就是"一间大房 + 一个起点"，和游戏里的迷宫完全不同。这里直接修正静态值。
	if int(Balance.MAX_FLOOR) < 2:
		Balance.MAX_FLOOR = 5
	var max_floor: int = int(Balance.MAX_FLOOR)
	var lv := clampi(floor_no, 1, max_floor)
	var sd := seed_val
	# 跟随根节点的种子时，用与 main.build_floor 完全相同的公式（seed + floor * 7919），
	# 这样预览出来的就是游戏里真正会生成的那一层。
	_synced = false
	if follow_game:
		var p := get_parent()
		if p != null and "dungeon_seed" in p:
			var gs := int(p.get("dungeon_seed"))
			if gs != 0:
				sd = gs + lv * 7919
				_synced = true
	var dd = Dungeon.new()
	dd.generate(lv, sd)
	# 第二道保险：只有"最后一层"才该是 Boss 层。若层号不是最后一层却生成了 Boss 层，
	# 说明 MAX_FLOOR 判定仍然异常，直接按普通层重来，避免又画成一间大房。
	if bool(dd.boss_floor) and lv != max_floor:
		lv = 1
		dd = Dungeon.new()
		dd.generate(lv, sd)
	_d = dd
	_shown_floor = lv
	_shown_seed = sd
	_building = false
	queue_redraw()


func _draw() -> void:
	if _d == null:
		return
	var w: int = int(_d.w)
	var h: int = int(_d.h)
	if w <= 0 or h <= 0:
		return

	# ① 底色 = 墙体：先铺满一整块，地板再盖上去，轮廓自然成形
	if show_walls:
		draw_rect(Rect2(0, 0, w * TILE, h * TILE), COL_BG)

	# ② 地板：逐行合并连续格（44×32=1408 格压到几十条绘制指令）
	var fi: int = Dungeon.FLOOR
	for y in h:
		var x := 0
		while x < w:
			if int(_d.grid[x][y]) != fi:
				x += 1
				continue
			var run := 1
			while x + run < w and int(_d.grid[x + run][y]) == fi:
				run += 1
			draw_rect(Rect2(x * TILE, y * TILE, run * TILE, TILE), COL_FLOOR)
			x += run

	# ③ 房间边框 + 序号（颜色即类型，不用记图例）
	if show_rooms and _d.room_kind.size() == _d.rooms.size():
		for i in _d.rooms.size():
			var r: Rect2i = _d.rooms[i]
			var kind: int = int(_d.room_kind[i])
			var col := COL_ROOM_NORMAL
			match kind:
				Dungeon.RoomKind.START:
					col = COL_ROOM_START
				Dungeon.RoomKind.STAIRS:
					col = COL_ROOM_STAIRS
				Dungeon.RoomKind.TREASURE:
					col = COL_ROOM_LOOT
			var rect := Rect2(r.position.x * TILE, r.position.y * TILE, r.size.x * TILE, r.size.y * TILE)
			draw_rect(rect, col, false, 2.0)
			if _font != null:
				draw_string(_font, rect.position + Vector2(4, 15), str(i + 1),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)

	# ④ 关键标记
	if show_marks:
		var sp: Vector2 = Dungeon.cell_to_pos(_d.start_cell)
		draw_circle(sp, 12.0, COL_ROOM_START)
		draw_circle(sp, 5.0, Color(1, 1, 1, 0.95))
		if _d.stair_cell.x >= 0:
			var tp: Vector2 = Dungeon.cell_to_pos(_d.stair_cell)
			draw_rect(Rect2(tp - Vector2(12, 12), Vector2(24, 24)), COL_ROOM_STAIRS, false, 2.5)
			draw_rect(Rect2(tp - Vector2(5, 5), Vector2(10, 10)), COL_ROOM_STAIRS)
		if _d.room_kind.size() == _d.rooms.size():
			for i in _d.rooms.size():
				if int(_d.room_kind[i]) != Dungeon.RoomKind.TREASURE:
					continue
				var r2: Rect2i = _d.rooms[i]
				var cp := Vector2(r2.position) * TILE + Vector2(r2.size) * TILE * 0.5
				draw_colored_polygon(PackedVector2Array([
					cp + Vector2(0, -9), cp + Vector2(9, 0),
					cp + Vector2(0, 9), cp + Vector2(-9, 0),
				]), COL_ROOM_LOOT)

	# ⑤ 顶部信息条
	if show_info and _font != null:
		var kind := "Boss 层" if bool(_d.boss_floor) else "普通层"
		var sync := "与游戏一致" if _synced else "示意（游戏为随机种子）"
		var txt := "%s · 第 %d 层 · %d×%d 格 · 种子 %d · %s · %s" % [
			kind, _shown_floor, w, h, _shown_seed, str(_d.debug_stats()), sync]
		var bar_w := 26.0 + float(txt.length()) * 7.6
		draw_rect(Rect2(6, 6, bar_w, 26), COL_PANEL)
		draw_string(_font, Vector2(15, 24), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, COL_TEXT)


## 场景树里给一句提示，省得以后有人把它当普通节点删了/加逻辑
func _get_configuration_warnings() -> PackedStringArray:
	if not Engine.is_editor_hint():
		return PackedStringArray()
	return PackedStringArray([
		"这是编辑器预览层：只在编辑器里绘制，运行时自动销毁。",
		"它不参与游戏逻辑，可随时删除或改参数。",
		"选中本节点后按 F，可把 2D 视图框到整张地图。",
	])
