extends Control
## 独立创作器 —— 只有一层薄外壳，编辑能力全在 `creator/core/workspace.gd`。
##
## 这一层存在的唯一理由：独立运行时需要「自己起一个游戏进程来试玩」，
## 而在 Godot 编辑器插件里，试玩应该交给编辑器（`EditorInterface.play_main_scene()`）。
## 所以两套宿主各自实现这几十行胶水，其余全部共用同一份编辑逻辑。
##
## 打开方式：双击根目录「打开创作器.bat」。

const UI := preload("res://creator/core/ui_kit.gd")
const Workspace := preload("res://creator/core/workspace.gd")

var ws


func _ready() -> void:
	theme = UI.make_theme()
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	ws = Workspace.new()
	ws.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(ws)

	ws.playtest_requested.connect(_playtest)
	ws.dirty_changed.connect(_on_dirty)

	DisplayServer.window_set_title("千亿魔女 · 创作工坊")
	DisplayServer.window_set_min_size(Vector2i(1080, 700))


## 独立版：另起一个 Godot 进程跑主场景。创作器本身不退出，方便边改边看。
func _playtest() -> void:
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var scene := ProjectSettings.globalize_path("res://arpg/main.tscn")
	var pid := OS.create_process(exe, ["--path", proj, scene])
	if pid > 0:
		ws.notify("已启动试玩窗口；改完记得先保存", 1)
	else:
		ws.notify("启动试玩失败，请手动运行「运行游戏.bat」", 2)


func _on_dirty(is_dirty: bool) -> void:
	DisplayServer.window_set_title("千亿魔女 · 创作工坊" + ("　● 未保存" if is_dirty else ""))
