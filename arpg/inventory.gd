class_name ArpgInventory
extends RefCounted
## 背包系统（需求：堆叠格模型）：
## · 不同物品占一格，同类堆叠（上限 99），总格数受容量限制（默认 20，走 balance 热重载）
## · 金币不占格（挂在 ArpgRpgState.gold）
## · 与拾取仲裁/商店/任务/存档互通；add/remove 全部有明确返回值，禁止无声失败

const STACK_MAX := 99

var slots: Array = []          # [{id: String, count: int}]
var cap := 20


func setup(cap_v: int) -> void:
	cap = cap_v


func used() -> int:
	return slots.size()


func is_full() -> bool:
	return slots.size() >= cap


## 添加 n 个；失败返回 false（容量不足时一件都不加入，保证原子性）
func add(id: String, n: int = 1) -> bool:
	if n <= 0:
		return false
	var remaining := n
	# 先填充已有堆叠
	for s in slots:
		if s["id"] == id and int(s["count"]) < STACK_MAX:
			var take := mini(STACK_MAX - int(s["count"]), remaining)
			s["count"] = int(s["count"]) + take
			remaining -= take
			if remaining <= 0:
				return true
	# 剩余开新格
	var need := ceili(float(remaining) / STACK_MAX)
	if slots.size() + need > cap:
		return false   # 原子性：不开一半
	while remaining > 0:
		var put := mini(STACK_MAX, remaining)
		slots.append({"id": id, "count": put})
		remaining -= put
	return true


## 移除 n 个；不足则整体失败（返回 false 且不改动）
func remove(id: String, n: int = 1) -> bool:
	if count(id) < n:
		return false
	var remaining := n
	for i in range(slots.size() - 1, -1, -1):
		var s: Dictionary = slots[i]
		if s["id"] == id:
			var take := mini(int(s["count"]), remaining)
			s["count"] = int(s["count"]) - take
			remaining -= take
			if int(s["count"]) <= 0:
				slots.remove_at(i)
			if remaining <= 0:
				break
	return true


func count(id: String) -> int:
	var n := 0
	for s in slots:
		if s["id"] == id:
			n += int(s["count"])
	return n


func has(id: String) -> bool:
	return count(id) > 0


## 按格列出（UI 用）：[{id, name, count, kind, value}]
func rows() -> Array:
	var out := []
	for s in slots:
		var it: Dictionary = ArpgBalance.ITEMS.get(s["id"], {})
		var eq: Dictionary = ArpgBalance.data.get("equipment", {}).get(s["id"], {})
		var name: String = it.get("name", eq.get("name", str(s["id"])))
		var kind: String = it.get("kind", "equip" if not eq.is_empty() else "misc")
		out.append({"id": s["id"], "name": name, "count": int(s["count"]),
			"kind": kind, "value": int(it.get("value", eq.get("value", 0)))})
	return out


func to_dict() -> Dictionary:
	return {"cap": cap, "slots": slots.duplicate(true)}


func from_dict(d: Dictionary) -> void:
	cap = int(d.get("cap", ArpgBalance.BAG_CAP))
	slots = d.get("slots", []).duplicate(true)
