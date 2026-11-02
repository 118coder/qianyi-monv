class_name ArpgCommandQueue
extends RefCounted
## 高层指令队列（需求书 §7 CommandQueue）：
## P0 为「当前指令即时生效 + 历史留存」；后续指令修饰参数（拾取开关/血量阈值/编队位）挂条目参数。

var items: Array = []


func push(cmd: String) -> void:
	items.append({"cmd": cmd, "t": Time.get_ticks_msec()})


func current() -> String:
	return str(items[-1]["cmd"]) if items.size() > 0 else "follow"


func history() -> Array:
	return items
