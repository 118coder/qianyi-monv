@tool
extends VBoxContainer
## 编辑器主屏页容器：把共享工作区塞进 Godot 编辑器，并接上编辑器侧的两个能力。
##
## 与独立创作器的差别只有两处，都集中在这里：
##   1. 试玩 → 调 `EditorInterface.play_main_scene()`，而不是起新进程；
##   2. 状态/脏标记 → 交给编辑器（编辑器没有统一状态栏可写，所以直接复用工作区自带的状态条，
##      只在标题上不显示星号，避免和编辑器自己的标题冲突）。
##
## 其余一切（五个模块、保存、备份、校验、热重载）都来自 `creator/core/workspace.gd`。

const UI := preload("res://creator/core/ui_kit.gd")
const Workspace := preload("res://creator/core/workspace.gd")

var ws


func _ready() -> void:
	theme = UI.make_theme()
	add_theme_constant_override("separation", 0)

	ws = Workspace.new()
	ws.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(ws)
	ws.playtest_requested.connect(_playtest)

	# 编辑器里跑的时候，工作区第一次加载会读 res://data/*.json；
	# 此时编辑器可能刚扫描完资源，读文件是安全的（JSON 不是导入资源）。


## 编辑器版试玩：直接跑项目主场景，复用编辑器的运行配置（调试器、断点都能用）
func _playtest() -> void:
	EditorInterface.play_main_scene()


## 供插件菜单调用
func save_now() -> void:
	if ws != null:
		ws.save_now()


## 供插件菜单调用
func notify(msg: String, level: int = 0) -> void:
	if ws != null:
		ws.notify(msg, level)
