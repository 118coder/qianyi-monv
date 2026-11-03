@tool
extends Node2D
## 场景分层容器（世界 / 队伍 / 镜头）。
##
## 运行时由 `main.gd` 往这些空容器里挂内容；这里只负责让「编辑器里能看见结构」。
## 为什么还要挂脚本：不挂的话，选中容器节点时会看到 position / rotation / scale /
## visibility / ordering / texture / material / process… 一长串对容器毫无意义的英文属性
## （容器永远在原点、不参与绘制）。挂上本脚本后，这些属性在检查器里被隐藏，
## 右侧面板就是干净的——容器不需要调任何东西。
##
## ⚠️ 这里刻意**不定义任何 @export**：`.tscn` 里的裸标识符只接受 ASCII，
## 中文属性名一旦随场景保存就会让文件读不回来（VariantParser 是 ASCII-only）。
## 需要临时调节点位置/层级时：把脚本里的 SHOW_RAW 常量改成 true 即可恢复内置属性。

## 调试开关：改为 true 后恢复 Node2D 的全部内置属性（改常量而不是导出变量，
## 就是为了不产生会被写进 .tscn 的字段）
const SHOW_RAW := false

## 对容器节点没有意义的属性：位置/变换/绘制/运行时处理，全部从检查器里去掉。
## 只去掉 EDITOR usage，运行时读写完全不受影响。
const _HIDE := [
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
	if SHOW_RAW:
		return
	if str(property.name) in _HIDE:
		property.usage &= ~PROPERTY_USAGE_EDITOR
