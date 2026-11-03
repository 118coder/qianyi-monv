@tool
extends EditorPlugin
## 编辑器中文化：补全引擎自带的 zh_CN 翻译里**缺掉的那部分**（检查器属性名与分组名）。
##
## 为什么需要它：Godot 编辑器界面本身是中文的（菜单/面板/按钮都翻好了），
## 但检查器里的属性名（Position / Rotation / Scale…）和属性分组（Transform / CanvasItem…）
## 走的是属性名直译，官方翻译长期没覆盖，于是出现"界面中文 + 右边一堆英文"的割裂。
##
## 做法：往 TranslationServer 注入一份运行时构造的 `Translation`（locale = 当前编辑器语言），
## 编辑器里所有 `TTR("Position")` 就会命中这条翻译。不改引擎、不改二进制、随项目走。
##
## 三条安全约束：
##   1. 只在编辑器语言是中文时注入 —— 英文环境不该被翻成中文；
##   2. 只翻译「检查器/属性名」这类短词，不碰有业务含义的长句；
##   3. `_exit_tree` 里摘掉自己注入的翻译，禁用插件即完全还原。

## 词表：key 必须与引擎内部的属性名逐字一致（首字母大写、含空格）。
## 覆盖 Node / CanvasItem / Node2D / Control 的高频项 + 检查器分组标题。
const TERMS := {
	# —— 检查器分组标题 ——
	"Transform": "变换",
	"Visibility": "可见性",
	"Ordering": "排序",
	"Texture": "纹理",
	"Material": "材质",
	"CanvasItem": "画布项",
	"Node": "节点",
	"Node2D": "二维节点",
	"Control": "控件",
	"Groups": "组",
	"Metadata": "元数据",

	# —— 变换 ——
	"Position": "位置",
	"Rotation": "旋转",
	"Scale": "缩放",
	"Skew": "倾斜",
	"Global Transform": "全局变换",
	"Global Position": "全局位置",
	"Global Rotation": "全局旋转",
	"Global Scale": "全局缩放",

	# —— CanvasItem 绘制 ——
	"Visible": "可见",
	"Z Index": "Z 索引",
	"Z As Relative": "Z 相对父节点",
	"Show Behind Parent": "在父节点之后显示",
	"Top Level": "顶层绘制",
	"Y Sort Enabled": "启用 Y 轴排序",
	"Modulate": "调制色",
	"Self Modulate": "自身调制色",
	"Light Mask": "光照遮罩",
	"Texture Repeat": "纹理重复",
	"Texture Filter": "纹理过滤",
	"Use Parent Material": "使用父级材质",

	# —— Node 基础 ——
	"Name": "名称",
	"Script": "脚本",
	"Mode": "模式",
	"Process": "处理",
	"Process Mode": "处理模式",
	"Process Priority": "处理优先级",
	"Physics Process": "物理处理",
	"Pause": "暂停",
	"Editor Description": "编辑器描述",
	"Clip Children": "裁剪子节点",
	"Mouse Filter": "鼠标过滤",
	"Anchor": "锚点",
	"Offset": "偏移",

	# —— 本项目的导出变量（检查器把 snake_case 自动分词成标题形式显示）——
	# 变量名必须是 ASCII（要写进 .tscn），中文标签只能靠这里补。
	"Note": "说明",
	"Show Raw Props": "显示原始属性",
	"Start Floor": "起始层",
	"Start Friends": "开局队友数",
	"Dungeon Seed": "地牢种子",
	"Floor No": "层号",
	"Seed Val": "种子",
	"Regenerate Now": "换一张图",
	"Follow Game": "跟随游戏种子",
	"Show Walls": "显示墙体",
	"Show Rooms": "显示房间",
	"Show Marks": "显示标记",
	"Show Info": "显示信息条",
	"Opacity": "不透明度",
}

## 需要注入的翻译域：
##  · 主域 —— 运行时 tr()
##  · godot.editor —— 编辑器 UI（菜单/按钮）
##  · godot.properties —— **检查器属性名**（Position / Rotation 这些就是从这里取的）
## 只加主域是不够的：`TranslationServer.add_translation()` 只写主域，
## 而编辑器查属性名走的是独立的 properties 域，所以上一版完全没生效。
const DOMAINS := ["godot.editor", "godot.properties"]

var _tr: Translation
var _domains: Array = []


func _enter_tree() -> void:
	var loc := TranslationServer.get_locale()
	if not loc.begins_with("zh"):
		print("[中文化] 跳过：当前语言为 %s，不是中文环境" % loc)
		return
	_tr = Translation.new()
	if _tr == null:
		push_warning("[中文化] Translation 实例化失败，检查器术语保持英文")
		return
	_tr.locale = loc
	# 同一个词同时注册「原样」和「小写」两种 key：检查器取属性名时用的是
	# capitalize 之后的形式（"Position"），而部分面板直接拿原始属性名（"position"）。
	# 两边都放一份，才不会出现"明明加了词表却没命中"。
	var n := 0
	for key in TERMS:
		var zh: String = str(TERMS[key])
		var en: String = str(key)
		_tr.add_message(StringName(en), StringName(zh))
		var low: String = en.to_lower()
		if low != en:
			_tr.add_message(StringName(low), StringName(zh))
		n += 1

	TranslationServer.add_translation(_tr)
	_domains.clear()
	# 兼容保护：TranslationDomain 是 4.4+ 才有的 API。旧版没有就直接只用主域，
	# 绝不能在 _enter_tree 里抛错（否则整个插件会被编辑器判定为加载失败）。
	if TranslationServer.has_method("get_or_add_domain"):
		for dname in DOMAINS:
			var d = TranslationServer.get_or_add_domain(StringName(str(dname)))
			if d != null:
				d.add_translation(_tr)
				_domains.append(d)
	print("[中文化] 已注入 %d 条术语到 %d 个域（locale=%s）" % [n, _domains.size() + 1, loc])


func _exit_tree() -> void:
	if _tr != null:
		TranslationServer.remove_translation(_tr)
		for d in _domains:
			if d != null:
				d.remove_translation(_tr)
		_tr = null
	_domains.clear()
