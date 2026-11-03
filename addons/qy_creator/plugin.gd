@tool
extends EditorPlugin
## 「千亿魔女」编辑器扩展：把创作工坊做成 Godot 编辑器的一个主屏页签。
##
## 与编辑器机制的兼容方式（只走官方扩展点，不改引擎）：
##   · `_has_main_screen()` 返回 true → 编辑器自动在主屏按钮行加一个页签；
##   · `_make_visible(on)` → 编辑器切页时回调，这里只做显示/隐藏；
##   · `_get_plugin_name()` / `_get_plugin_icon()` → 按钮文案与图标；
##   · 主屏容器挂在 `EditorInterface.get_editor_main_screen()` 下，由编辑器负责生命周期。
##
## 职责边界：插件**不实现任何编辑逻辑**，只做三件事——注册页签、隐藏用不上的页签、
## 把试玩请求转给编辑器。真正的编辑能力全部来自 `creator/core/workspace.gd`，
## 与独立创作器完全同一份代码。

const MainScreen := preload("res://addons/qy_creator/main_screen.gd")

## 主屏按钮行里要隐藏的页签（中英文都列，命中即隐藏；找不到就静默跳过）
## 之所以按文案匹配而不是按下标：按钮顺序随引擎版本变化，下标不可靠。
const HIDE_TABS := ["3D", "AssetLib", "资产库", "资源商店"]

const MENU_SAVE := "千亿魔女：保存创作数据"
const MENU_RESTORE := "千亿魔女：恢复编辑器默认页签"

var _screen: Control
var _menu_added := false


func _enter_tree() -> void:
	_screen = MainScreen.new()
	_screen.name = "千亿魔女"
	EditorInterface.get_editor_main_screen().add_child(_screen)
	_make_visible(false)

	# 主屏按钮要等编辑器布局与翻译都就绪才稳定，等两帧再精简
	_deferred_trim()
	add_tool_menu_item(MENU_SAVE, _menu_save)
	add_tool_menu_item(MENU_RESTORE, _menu_restore)
	_menu_added = true


func _exit_tree() -> void:
	# EditorPlugin 没有 has_tool_menu_item()，用标志位记录，避免重复移除报错
	if _menu_added:
		remove_tool_menu_item(MENU_SAVE)
		remove_tool_menu_item(MENU_RESTORE)
		_menu_added = false
	_trim_tabs(false)
	if _screen != null and is_instance_valid(_screen):
		_screen.queue_free()
		_screen = null


# ———————— 主屏页签（官方扩展点） ————————

func _has_main_screen() -> bool:
	return true


func _make_visible(on: bool) -> void:
	if _screen != null and is_instance_valid(_screen):
		_screen.visible = on


func _get_plugin_name() -> String:
	return "千亿魔女"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("Tools", "EditorIcons")


# ———————— 页签精简 ————————

## 隐藏用不上的主屏页签，让编辑器看起来像专用工具。
## 只做 visible=false，不删节点 —— 随时可以调菜单「恢复编辑器默认页签」还原。
## 等两帧再动：主屏按钮行是在编辑器布局完成、且页签文案翻译之后才创建并写字的，
## 太早执行会匹配不到 text，表现为「取消失败但不报错」。
func _deferred_trim() -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	_trim_tabs(true)


func _trim_tabs(on: bool) -> void:
	var ms := EditorInterface.get_editor_main_screen()
	if ms == null:
		return
	# 不假设按钮行一定是哪个容器类型：挨个看一层子节点的子节点，
	# 命中 Button 就按文案匹配。版本变化时最坏是「没隐藏」，不会报错。
	for row in ms.get_children():
		for b in row.get_children():
			if b is Button:
				if str((b as Button).text).strip_edges() in HIDE_TABS:
					(b as Button).visible = not on


# ———————— 菜单 ————————

func _menu_save() -> void:
	if _screen != null and is_instance_valid(_screen) and _screen.has_method("save_now"):
		_screen.save_now()


func _menu_restore() -> void:
	_trim_tabs(false)
	if _screen != null and is_instance_valid(_screen) and _screen.has_method("notify"):
		_screen.notify("已恢复编辑器的全部页签", 0)
