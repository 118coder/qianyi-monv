@tool
extends CanvasLayer
## 场景分层容器（界面）。
##
## 与 `scene_layer.gd` 同理：容器本身不参与绘制，`layer / offset / rotation / scale /
## follow_viewport…` 这些内置属性对它是纯噪音，默认从检查器隐藏。
## 同样**不定义 @export**：`.tscn` 裸标识符只接受 ASCII，中文属性名会写坏场景文件。
## 需要临时改层号时，把 SHOW_RAW 改成 true。

## 调试开关：改为 true 后恢复 CanvasLayer 的全部内置属性
const SHOW_RAW := false

const _HIDE := [
	"layer", "visible", "offset", "rotation", "rotation_degrees", "scale",
	"transform", "follow_viewport_enabled", "follow_viewport_scale",
	"custom_viewport", "process_mode", "process_priority",
	"process_physics_priority", "process_thread_group",
	"physics_interpolation_mode", "auto_translate_mode", "editor_description",
]


func _validate_property(property: Dictionary) -> void:
	if SHOW_RAW:
		return
	if str(property.name) in _HIDE:
		property.usage &= ~PROPERTY_USAGE_EDITOR
