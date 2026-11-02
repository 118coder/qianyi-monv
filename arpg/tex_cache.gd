class_name ArpgTex
extends RefCounted
## 懒加载纹理缓存（LRU）：千张特效贴图按需加载，超上限自动淘汰最久未用的。
## 所有运行期贴图都从这里取，避免 preload 一次性吃满内存。

const MAX_ENTRIES := 300

static var _cache := {}
static var _order := []   # key 队列，队尾 = 最近使用


static func tex(path: String) -> Texture2D:
	if _cache.has(path):
		_touch(path)
		return _cache[path]
	var t: Texture2D = load(path)
	if t == null:
		return null
	_cache[path] = t
	_order.append(path)
	if _order.size() > MAX_ENTRIES:
		var victim: String = _order.pop_front()
		_cache.erase(victim)   # 引用清零后 Godot 自动释放显存
	return t


static func _touch(path: String) -> void:
	var i := _order.find(path)
	if i >= 0 and i != _order.size() - 1:
		_order.remove_at(i)
		_order.append(path)


static func clear() -> void:
	_cache.clear()
	_order.clear()
