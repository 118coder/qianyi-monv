extends RefCounted
## 创作器通用控件层：深色主题 + 中文字体 + 「数据结构 → 表单」自动生成。
##
## 设计原则（这决定了以后加配置项要不要改界面代码）：
##   · 表单不针对某个字段硬编码，而是按 JSON 里的**值的类型**递归生成控件：
##     int/float → 数字框、bool → 勾选、String → 输入框、Dictionary → 折叠分组、
##     Array → 列表编辑器。balance.json 以后加任何键，界面自动出现，无需改动本文件。
##   · 字段名走「完整词典 → 词根组合 → 原名」三级回落，保证不会满屏英文，
##     也不可能因为漏翻某个键就崩掉。
##   · 所有控件都挂 `on_change(key_path, new_value)` 回调，由上层决定是否标记脏、
##     是否立即热重载，控件本身不碰文件。

# —— 配色：暖近黑 + 暖白 + 单一铜橙强调 ——
# 定调是「工业实用」：地牢火把的色温，配合发丝线与等宽数字，做出仪表盘的信息密度。
# 铁律：ACCENT 只留给关键动作（保存、当前选中、主操作），绝不拿来装饰；
# 模块分类色只在左侧导航条的 3px 色带上出现，不扩散到正文。
const BG := Color("0e0d0c")          # 最底层（暖黑，不用纯黑）
const PANEL := Color("171614")       # 面板表面
const PANEL_2 := Color("1f1d1a")     # 次级表面（输入框、按钮常态）
const PANEL_3 := Color("2a2723")     # 三级表面（悬停、选中）
const LINE := Color("3a352e")        # 发丝线
const TEXT := Color("f5f1ea")        # 暖白正文（对 PANEL 约 15:1）
const DIM := Color("a09a90")         # 次要文字（约 7:1，仍过 AA）
const ACCENT := Color("e8873a")      # 铜橙：唯一强调色
const OK := Color("7fb069")          # 苔绿
const WARN := Color("e0b341")
const ERR := Color("d65a4a")

# 模块语义色（只用于导航条色带，避免五颜六色污染主界面）
const MOD_OVERVIEW := Color("a09a90")
const MOD_NUMBERS := Color("e8873a")
const MOD_DATABASE := Color("7fb069")
const MOD_EVENTS := Color("8b7bd8")
const MOD_LEVEL := Color("5fa8b8")
const MOD_TILES := Color("c98f5e")   # 图块/砖土的暖褐，与"场景搭建"语义对应

const FONT_NAMES := ["Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "Noto Sans CJK SC"]
## 等宽：所有数字、坐标、种子都用它，读数时字符不会跳宽
const MONO_NAMES := ["Consolas", "Cascadia Mono", "DejaVu Sans Mono", "Courier New"]


## 全局中文字体：Godot 自带字体不含 CJK，不设这个整屏都是方块
static func make_font(size: int = 14) -> SystemFont:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(FONT_NAMES)
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	return f


static func make_mono_font() -> SystemFont:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(MONO_NAMES)
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	return f


## 等宽字体缓存：SystemFont 构造不便宜，界面里有几十处数字标签，必须复用
static var _mono: Font
static func mono() -> Font:
	if _mono == null:
		_mono = make_mono_font()
	return _mono


## 等宽数字标签（坐标 / 种子 / 数值读数）
static func mono_label(parent: Node, text: String, size: int = 13, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", mono())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


static func _sb(color: Color, border: int = 0, radius: int = 3, pad_x: int = 10, pad_y: int = 5) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	if border > 0:
		s.border_width_left = border
		s.border_width_right = border
		s.border_width_top = border
		s.border_width_bottom = border
		s.border_color = LINE
	s.content_margin_left = pad_x
	s.content_margin_right = pad_x
	s.content_margin_top = pad_y
	s.content_margin_bottom = pad_y
	return s


## 统一主题：小圆角 + 发丝边框 + 暖黑底，不做大圆角卡片和投影
static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = make_font(14)
	t.default_font_size = 14

	for tn in ["Panel", "PanelContainer"]:
		t.set_stylebox("panel", tn, _sb(PANEL, 1, 4, 10, 10))

	# 按钮：常态是「表面色 + 发丝线」，悬停才提亮，按下才用强调色的低透明版
	t.set_stylebox("normal", "Button", _sb(PANEL_2, 1, 3))
	t.set_stylebox("hover", "Button", _sb(PANEL_3, 1, 3))
	var pressed := _sb(PANEL_3, 1, 3)
	pressed.border_color = ACCENT
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", _sb(Color("141311"), 1, 3))
	t.set_stylebox("focus", "Button", _sb(Color(0, 0, 0, 0), 1, 3))
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color(1, 1, 1))
	t.set_color("font_pressed_color", "Button", ACCENT)
	t.set_color("font_disabled_color", "Button", Color("5a564e"))

	t.set_stylebox("normal", "LineEdit", _sb(Color("100f0d"), 1, 3))
	var lef := _sb(Color("100f0d"), 1, 3)
	lef.border_color = ACCENT
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_color("selection_color", "LineEdit", Color(0.91, 0.53, 0.23, 0.28))

	t.set_stylebox("panel", "PopupMenu", _sb(PANEL_2, 1, 3))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", Color(1, 1, 1))
	t.set_color("font_separator_color", "PopupMenu", DIM)
	t.set_stylebox("hover", "PopupMenu", _sb(PANEL_3, 0, 2))

	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0))

	t.set_stylebox("panel", "ItemList", _sb(Color("100f0d"), 1, 3))
	t.set_color("font_color", "ItemList", TEXT)
	t.set_color("font_selected_color", "ItemList", Color(1, 1, 1))
	var sel := _sb(Color(0.91, 0.53, 0.23, 0.22), 0, 2)
	t.set_stylebox("selected", "ItemList", sel)
	t.set_stylebox("selected_focus", "ItemList", sel)
	t.set_stylebox("cursor", "ItemList", _sb(Color(0, 0, 0, 0), 1, 2))
	t.set_stylebox("cursor_unfocused", "ItemList", _sb(Color(0, 0, 0, 0), 1, 2))

	t.set_stylebox("panel", "Tree", _sb(Color("100f0d"), 1, 3))
	t.set_color("font_color", "Tree", TEXT)
	t.set_color("font_selected_color", "Tree", Color(1, 1, 1))
	t.set_stylebox("selected", "Tree", _sb(Color(0.91, 0.53, 0.23, 0.22), 0, 2))
	t.set_stylebox("selected_focus", "Tree", _sb(Color(0.91, 0.53, 0.23, 0.22), 0, 2))

	t.set_stylebox("panel", "TabContainer", _sb(PANEL, 1, 4))
	t.set_stylebox("tab_selected", "TabContainer", _sb(PANEL_3, 1, 3))
	t.set_stylebox("tab_unselected", "TabContainer", _sb(PANEL, 1, 3))

	for bar in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", bar, _sb(Color("121110"), 0, 3, 0, 0))
		t.set_stylebox("grabber", bar, _sb(Color("35312b"), 0, 3, 0, 0))
		t.set_stylebox("grabber_highlight", bar, _sb(Color("4a443b"), 0, 3, 0, 0))
		t.set_stylebox("grabber_pressed", bar, _sb(ACCENT, 0, 3, 0, 0))

	t.set_stylebox("panel", "TooltipPanel", _sb(PANEL_3, 1, 3))
	t.set_color("font_color", "TooltipLabel", TEXT)

	t.set_color("font_color", "CheckBox", TEXT)
	t.set_color("font_hover_color", "CheckBox", Color(1, 1, 1))
	t.set_color("font_pressed_color", "CheckBox", ACCENT)
	t.set_color("font_color", "CheckButton", TEXT)

	t.set_stylebox("normal", "OptionButton", _sb(PANEL_2, 1, 3))
	t.set_stylebox("hover", "OptionButton", _sb(PANEL_3, 1, 3))
	t.set_stylebox("pressed", "OptionButton", pressed)
	t.set_stylebox("focus", "OptionButton", _sb(Color(0, 0, 0, 0), 1, 3))
	t.set_color("font_color", "OptionButton", TEXT)

	t.set_stylebox("panel", "SpinBox", _sb(Color("100f0d"), 1, 3))
	return t



# ———————— 字段名中文化 ————————

## 完整字段词典：命中即用（比词根拼装通顺）
const FIELD_ZH := {
	"max_floor": "楼层总数", "bag_cap": "背包格数", "death_loss": "死亡掉落比例",
	"elite_chance": "精英怪概率", "trap_chance": "陷阱箱概率", "aggro_range": "仇恨距离",
	"gold_drop_min": "金币下限", "gold_drop_max": "金币上限",
	"xp_base": "经验基数", "xp_per_level": "每级经验", "sell_ratio": "出售折价",
	"floor_enemy_count_base": "每层怪物基数", "floor_enemy_count_per": "每层递增",
	"elite_tint": "精英染色", "drop_base": "基础掉落表", "loot_base": "基础战利品",
	"drop_f2_add": "第2层追加", "drop_f4_add": "第4层追加",
	"loot_f2_add": "第2层战利品追加", "loot_f3_add": "第3层战利品追加",
	"base_zoom": "基础缩放", "min_zoom": "最小缩放", "pan_weight": "平移权重",
	"safe_frac": "安全区比例", "fit_bias": "适配偏置", "track_ratio": "跟踪余量",
	"track_release": "释放余量", "margin": "边距", "smooth_time": "平滑时间",
	"max_speed": "最大速度", "zoom_out_rate": "拉远速率", "zoom_in_rate": "拉近速率",
	"zoom_deadband": "缩放死区", "max_shot_time": "镜头最长停留",
	"focus_rate": "推镜速率", "look_ahead": "前视距离",
	"enabled": "启用", "settle_mode": "结算时机", "elite_mult": "精英倍率",
	"boss_mult": "首领倍率", "scatter_time": "散开时长", "friction": "阻尼",
	"bounce": "反弹系数", "scatter_speed_min": "散开速度下限",
	"scatter_speed_max": "散开速度上限", "attract_radius": "吸附半径",
	"attract_delay": "吸附延迟", "attract_speed_start": "吸附初速",
	"attract_speed_end": "吸附末速", "attract_time": "吸附时长",
	"arrive_dist": "到达判定", "lifetime": "存在时长",
	"scale_start": "起始缩放", "scale_end": "结束缩放",
	"count_min": "数量下限", "count_max": "数量上限", "chance": "概率",
	"value": "数值", "reveal_radius": "探索半径", "reveal_interval": "探索间隔",
	"width": "宽", "height": "高", "hp": "生命", "atk": "攻击", "def": "防御",
	"spd": "速度", "cd": "冷却", "range": "射程", "radius": "半径",
	"self_defense_radius": "自卫半径", "assist_radius": "协战半径",
	"assist_idle_radius": "待机协战半径", "los_penalty": "隔墙惩罚",
	"stick_bonus": "粘性加成", "switch_margin": "换目标余量",
	"reach_timeout": "到达超时", "blacklist_time": "黑名单时长",
	"ranged_engage": "远程交战距离", "ranged_keep_min": "远程最近保持",
	"ranged_keep_max": "远程最远保持", "arrive_radius": "到达半径",
	"resume_radius": "恢复半径", "pickup_threat_radius": "拾取威胁半径",
	"skill_min_enemies": "技能最少目标", "stuck_repath": "卡住重寻路",
	"stuck_sidestep": "卡住侧移", "stuck_regroup": "卡住归位",
	"stuck_teleport": "卡住传送", "hold_leash": "待机牵引距离",
	"aim_max_lead": "预判上限", "think_interval": "思考间隔",
	"nav_repath_interval": "重寻路间隔", "follow_distance": "跟随距离",
	"spread": "散布", "engage_radius": "接战半径", "search_radius": "搜索半径",
	"leash_radius": "脱缰半径", "protect_player": "保护玩家",
	"low_hp_retreat": "低血撤退", "no_enemy": "无敌人时",
	"engage_with_player": "随玩家接战", "pickup": "拾取", "self_defense": "自卫",
	"defense_radius": "自卫半径", "ally_frac": "友军比例",
	"elite_mult_": "精英倍率", "bonus": "加成", "atk_mult": "攻击倍率",
	"name": "名称", "desc": "说明", "tier": "层级", "price": "价格",
	"heal": "回复量", "sp": "技力", "power": "威力", "cost": "消耗",
	"growth": "成长", "tpl": "模板", "weapon": "武器类型",
	"atk_range": "攻击距离", "atk_cd": "攻击间隔", "proj_spd": "弹速",
	"behavior": "行为", "cool": "冷却", "move": "移速", "faction": "阵营",
}

## 词根词典：完整词典没命中时按 `_` 拆词拼中文，避免满屏英文
const WORD_ZH := {
	"enable": "启用", "enabled": "启用", "disable": "禁用", "min": "下限", "max": "上限",
	"base": "基础", "rate": "速率", "speed": "速度", "time": "时长", "interval": "间隔",
	"chance": "概率", "radius": "半径", "range": "距离", "dist": "距离", "count": "数量",
	"mult": "倍率", "ratio": "比例", "frac": "比例", "bonus": "加成", "penalty": "惩罚",
	"delay": "延迟", "scale": "缩放", "zoom": "缩放", "pan": "平移", "smooth": "平滑",
	"look": "前视", "ahead": "距离", "fit": "适配", "bias": "偏置", "track": "跟踪",
	"release": "释放", "safe": "安全", "margin": "边距", "deadband": "死区",
	"shot": "镜头", "focus": "聚焦", "width": "宽", "height": "高", "speed_": "速度",
	"hp": "生命", "sp": "技力", "atk": "攻击", "def": "防御", "spd": "速度",
	"cd": "冷却", "power": "威力", "cost": "消耗", "heal": "回复", "price": "价格",
	"tier": "层级", "name": "名称", "desc": "说明", "level": "等级", "gold": "金币",
	"drop": "掉落", "loot": "战利品", "item": "物品", "items": "物品", "skill": "技能",
	"skills": "技能", "quest": "任务", "quests": "任务", "shop": "商店", "stock": "库存",
	"party": "队伍", "ai": "AI", "camera": "镜头", "drops": "掉落表现",
	"minimap": "小地图", "common": "通用", "gem": "宝石", "gold_": "金币",
	"scatter": "散开", "attract": "吸附", "arrive": "到达", "life": "存在",
	"start": "起始", "end": "结束", "follow": "跟随", "game": "游戏",
	"assist": "协战", "self": "自身", "defense": "防御", "stick": "粘性",
	"switch": "切换", "reach": "到达", "blacklist": "黑名单", "ranged": "远程",
	"engage": "交战", "keep": "保持", "pickup": "拾取", "threat": "威胁",
	"stuck": "卡住", "repath": "重寻路", "sidestep": "侧移", "regroup": "归位",
	"teleport": "传送", "hold": "待机", "leash": "牵引", "aim": "瞄准",
	"lead": "预判", "think": "思考", "nav": "导航", "search": "搜索",
	"spread": "散布", "protect": "保护", "player": "玩家", "retreat": "撤退",
	"enemy": "敌人", "ally": "友军", "weapon": "武器", "proj": "弹道",
	"behavior": "行为", "cool": "冷却", "move": "移动", "faction": "阵营",
	"elite": "精英", "boss": "首领", "trap": "陷阱", "floor": "楼层",
	"enemies": "怪物", "chars": "角色", "equipment": "装备", "skills_": "技能",
	"weapon_": "武器", "armor": "护甲", "trinket": "饰品", "slots": "槽位",
	"aggro": "仇恨", "death": "死亡", "loss": "损失", "bag": "背包", "cap": "容量",
	"xp": "经验", "per": "每级", "sell": "出售", "reveal": "探索", "view": "视野",
}


## 字段名 → 中文：完整词典 → 词根组合 → 原名
static func pretty(key: String) -> String:
	if FIELD_ZH.has(key):
		return str(FIELD_ZH[key])
	var parts := key.split("_", false)
	var out := ""
	var hit := 0
	for p in parts:
		var lp := str(p).to_lower()
		if WORD_ZH.has(lp):
			out += str(WORD_ZH[lp])
			hit += 1
		else:
			out += str(p).capitalize()
	if hit == 0:
		return key.replace("_", " ").capitalize()
	return out


# ———————— 基础控件工厂 ————————

static func label(parent: Node, text: String, size: int = 14, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


static func hint(parent: Node, text: String) -> Label:
	var l := label(parent, text, 12, DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


static func button(parent: Node, text: String, cb: Callable, min_w: float = 0.0) -> Button:
	var b := Button.new()
	b.text = text
	if min_w > 0.0:
		b.custom_minimum_size.x = min_w
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


static func panel(parent: Node, pad: int = 10) -> PanelContainer:
	var p := PanelContainer.new()
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", pad)
	m.add_theme_constant_override("margin_right", pad)
	m.add_theme_constant_override("margin_top", pad)
	m.add_theme_constant_override("margin_bottom", pad)
	p.add_child(m)
	parent.add_child(p)
	return p


static func vbox(parent: Node, sep: int = 6) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	parent.add_child(v)
	return v


static func hbox(parent: Node, sep: int = 6) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	parent.add_child(h)
	return h


static func hsep(parent: Node) -> void:
	var c := ColorRect.new()
	c.color = LINE
	c.custom_minimum_size.y = 1
	parent.add_child(c)


## 区块标题：左侧一条语义色竖线 + 标题。用色线而不是大标题字，是为了在
## 高密度界面里建立层级而不占垂直空间（工业仪表盘的做法）。
static func section(parent: Node, title: String, color: Color = ACCENT) -> VBoxContainer:
	var h := hbox(parent, 8)
	var bar := ColorRect.new()
	bar.color = color
	bar.custom_minimum_size = Vector2(3, 16)
	h.add_child(bar)
	var l := label(h, title, 15, TEXT)
	l.add_theme_font_size_override("font_size", 15)
	var v := vbox(parent, 6)
	return v


## 细竖条（用于导航、卡片左缘）
static func accent_bar(parent: Node, color: Color, w: float = 3.0, h: float = 18.0) -> ColorRect:
	var bar := ColorRect.new()
	bar.color = color
	bar.custom_minimum_size = Vector2(w, h)
	parent.add_child(bar)
	return bar


# ———————— 动效 ————————
# 只做「一次编排好的入场」，不做零散微交互：工作台会被反复切换，
# 每次切换都放动画会烦人。所以入场控制在 0.28s、错峰 60ms、最多 8 个元素。

const MOTION_STEP := 0.055
const MOTION_DUR := 0.26
const MOTION_MAX := 8


## 编排式入场：子控件错峰淡入。
## 只动 opacity，不动 position —— 这些子控件都长在 Container 里，
## Container 每帧会重写子节点的 position，用位移做入场会被立刻打回原位。
static func stagger_in(parent: Node, step: float = MOTION_STEP, dur: float = MOTION_DUR) -> void:
	if not parent.is_inside_tree():
		return
	var i := 0
	for c in parent.get_children():
		if not (c is Control):
			continue
		if i >= MOTION_MAX:
			break
		var ctrl: Control = c
		ctrl.modulate.a = 0.0
		var tw := ctrl.create_tween()
		tw.tween_interval(step * float(i))
		tw.tween_property(ctrl, "modulate:a", 1.0, dur).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		i += 1


## 单个控件的淡入（切换面板时用）
static func fade_in(ctrl: Control, dur: float = MOTION_DUR) -> void:
	if not ctrl.is_inside_tree():
		return
	ctrl.modulate.a = 0.0
	var tw := ctrl.create_tween()
	tw.tween_property(ctrl, "modulate:a", 1.0, dur).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)


## 数字读数统一格式：坐标 (12, 7)、尺寸 56×40
static func coord(x: int, y: int) -> String:
	return "(%d, %d)" % [x, y]


# ———————— 类型 → 控件（递归） ————————

## 生成一个可编辑控件，值变化时回调 on_change(new_value)
## kind 由值的实际类型决定，调用方不用关心字段是什么
static func editor_for(parent: Node, key: String, value: Variant, on_change: Callable) -> Control:
	match typeof(value):
		TYPE_BOOL:
			var cb := CheckBox.new()
			cb.text = pretty(key)
			cb.button_pressed = bool(value)
			cb.toggled.connect(func(v): on_change.call(v))
			parent.add_child(cb)
			return cb
		TYPE_INT:
			var sp := SpinBox.new()
			sp.min_value = -100000
			sp.max_value = 100000
			sp.step = 1
			sp.value = int(value)
			sp.allow_greater = true
			sp.allow_lesser = true
			sp.custom_minimum_size.x = 120
			sp.value_changed.connect(func(v): on_change.call(int(v)))
			_row(parent, key, sp)
			return sp
		TYPE_FLOAT:
			var sp2 := SpinBox.new()
			sp2.min_value = -100000
			sp2.max_value = 100000
			sp2.step = 0.01
			sp2.value = float(value)
			sp2.allow_greater = true
			sp2.allow_lesser = true
			sp2.custom_minimum_size.x = 120
			sp2.value_changed.connect(func(v): on_change.call(float(v)))
			_row(parent, key, sp2)
			return sp2
		TYPE_STRING:
			var le := LineEdit.new()
			le.text = str(value)
			le.custom_minimum_size.x = 180
			le.text_changed.connect(func(t): on_change.call(t))
			_row(parent, key, le)
			return le
		TYPE_ARRAY:
			return _array_editor(parent, key, value, on_change)
		TYPE_DICTIONARY:
			return _dict_editor(parent, key, value, on_change)
	var l := label(parent, "%s = %s" % [pretty(key), str(value)], 13, DIM)
	return l


## 一行「标签 + 控件」
static func _row(parent: Node, key: String, ctrl: Control) -> HBoxContainer:
	var h := hbox(parent, 8)
	var l := label(h, pretty(key), 13, DIM)
	l.custom_minimum_size.x = 132
	l.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	h.add_child(ctrl)
	return h


## 数组：同质标量 → 逐项编辑 + 增删；二元数组（[[id, n], ...]）→ 键值行
## 行内回调一律用 `bind` 把下标当参数传进去，**不在闭包里捕获循环变量**：
## 循环内闭包捕获在 GDScript 里容易出意外（所有行指向最后一个下标），
## bind 是显式、可读、可静态检查的写法。
static func _array_editor(parent: Node, key: String, value: Array, on_change: Callable) -> Control:
	var box := vbox(parent, 4)
	var head := hbox(box, 8)
	label(head, pretty(key), 13, DIM)
	var cnt := label(head, "（%d 项）" % value.size(), 12, DIM)
	var rows := vbox(box, 3)
	var data: Array = value
	_fill_rows(rows, data, on_change, cnt)
	var acts := hbox(box, 6)
	button(acts, "＋ 添加", _array_append.bind(data, on_change, rows, cnt), 90)
	return box


static func _fill_rows(rows: Node, data: Array, on_change: Callable, cnt: Label) -> void:
	for c in rows.get_children():
		rows.remove_child(c)
		c.queue_free()
	for i in data.size():
		var it = data[i]
		var h := hbox(rows, 6)
		if it is Array and (it as Array).size() == 2 and not (it[0] is Array):
			var a := LineEdit.new()
			a.text = str(it[0])
			a.custom_minimum_size.x = 150
			a.text_changed.connect(_set_pair_str.bind(data, i, on_change))
			h.add_child(a)
			var b := SpinBox.new()
			b.min_value = 0
			b.max_value = 99999
			b.value = int(it[1])
			b.value_changed.connect(_set_pair_num.bind(data, i, on_change))
			h.add_child(b)
		else:
			var le := LineEdit.new()
			le.text = str(it)
			le.custom_minimum_size.x = 220
			le.text_changed.connect(_set_item.bind(data, i, on_change))
			h.add_child(le)
		button(h, "×", _remove_at.bind(data, i, on_change, rows, cnt))
	cnt.text = "（%d 项）" % data.size()


static func _set_pair_str(t: String, data: Array, i: int, on_change: Callable) -> void:
	if i < 0 or i >= data.size():
		return
	var cur: Array = data[i] if data[i] is Array else ["", 0]
	data[i] = [t, cur[1] if cur.size() > 1 else 0]
	on_change.call(data)


static func _set_pair_num(v: float, data: Array, i: int, on_change: Callable) -> void:
	if i < 0 or i >= data.size():
		return
	var cur: Array = data[i] if data[i] is Array else ["", 0]
	data[i] = [cur[0] if cur.size() > 0 else "", int(v)]
	on_change.call(data)


static func _set_item(t: String, data: Array, i: int, on_change: Callable) -> void:
	if i < 0 or i >= data.size():
		return
	data[i] = t
	on_change.call(data)


static func _remove_at(data: Array, i: int, on_change: Callable, rows: Node, cnt: Label) -> void:
	if i < 0 or i >= data.size():
		return
	data.remove_at(i)
	on_change.call(data)
	_fill_rows(rows, data, on_change, cnt)


static func _array_append(data: Array, on_change: Callable, rows: Node, cnt: Label) -> void:
	if data.size() > 0 and data[0] is Array:
		data.append(["", 1])
	elif data.size() > 0 and data[0] is String:
		data.append("")
	elif data.size() > 0 and data[0] is int:
		data.append(0)
	else:
		data.append(0.0 if (data.size() > 0 and data[0] is float) else 0)
	on_change.call(data)
	_fill_rows(rows, data, on_change, cnt)


## 字典：折叠面板 + 递归（深度有限，避免无限嵌套把界面撑爆）
static func _dict_editor(parent: Node, key: String, value: Dictionary, on_change: Callable) -> Control:
	var fold := VBoxContainer.new()
	fold.add_theme_constant_override("separation", 4)
	parent.add_child(fold)

	var head := Button.new()
	head.text = "▾ " + pretty(key) + "（%d 项）" % value.size()
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.add_theme_font_size_override("font_size", 13)
	head.custom_minimum_size.y = 26
	fold.add_child(head)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 3)
	fold.add_child(inner)

	var open := [true]
	head.pressed.connect(func():
		open[0] = not open[0]
		inner.visible = open[0]
		head.text = ("▾ " if open[0] else "▸ ") + pretty(key) + "（%d 项）" % value.size()
	)

	for k in value.keys():
		var kk := str(k)
		var sub = value[k]
		if sub is Dictionary:
			_dict_editor(inner, key + "." + kk, sub, _set_key.bind(value, kk, on_change))
		elif sub is Array:
			_array_editor(inner, kk, sub, _set_key.bind(value, kk, on_change))
		else:
			editor_for(inner, kk, sub, _set_key.bind(value, kk, on_change))
	return fold


## 把「改哪个键」用 bind 显式传进来。不在循环里用闭包捕获 kk——
## 那种写法一旦捕获语义不如预期，所有输入框会一起写到同一个键上，且极难复现。
static func _set_key(nv: Variant, container: Dictionary, key: String, on_change: Callable) -> void:
	container[key] = nv
	on_change.call(container)
