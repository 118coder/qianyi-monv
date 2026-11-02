class_name ArpgPickupArbiter
extends RefCounted
## 拾取仲裁器（需求书 §5.5 / §7 PickupArbiter）：
## · 优先级：玩家手动/自动拾取 > 任务物品锁定（预留） > AI 按规则拾取
## · 同一掉落同一时刻只归一个认领者，杜绝多个 AI 重复拾取
## · 玩家拾取无条件优先（覆盖任何认领）
## · 全程日志，玩家可知道物品去向；禁止无声失败

var main: Node
var claims := {}              # item_id(int) -> owner_uid(String)
var _warn_ms := {}


func request(uid: String, item_id: int) -> bool:
	var owner: String = claims.get(item_id, "")
	if owner == uid:
		return true
	if owner != "" and uid == "player":
		claims[item_id] = uid   # 玩家优先级最高：直接覆盖 AI 认领
		print("[PICKUP] 玩家覆盖认领 #%d（原：%s）" % [item_id, owner])
		return true
	if owner != "":
		_throttled_warn("%s 想捡的物品已被 %s 认领" % [uid, owner])
		print("[PICKUP] deny %s → #%d（已归 %s）" % [uid, item_id, owner])
		return false
	claims[item_id] = uid
	print("[PICKUP] claim %s → #%d" % [uid, item_id])
	return true


## 玩家拿走物品：清除任何认领（玩家优先级最高）
func player_took(item_id: int) -> void:
	if claims.has(item_id):
		print("[PICKUP] 玩家优先拾取 #%d（原认领：%s）" % [item_id, claims[item_id]])
		claims.erase(item_id)


## AI 到位收取：走共享背包；失败（背包满）释放认领，稍后可重试
func collect(unit, item_id: int) -> bool:
	var ok: bool = main.try_pickup_for(unit, item_id)
	claims.erase(item_id)
	return ok


func release(item_id: int) -> void:
	claims.erase(item_id)


func release_all(uid: String) -> void:
	for k in claims.keys():
		if claims[k] == uid:
			claims.erase(k)


## 物品被吃掉/消失时清理（拾取系统压缩时调用）
func drop_gone(item_id: int) -> void:
	claims.erase(item_id)


func _throttled_warn(msg: String) -> void:
	var now := Time.get_ticks_msec()
	if now - int(_warn_ms.get(msg, 0)) > 2000:
		_warn_ms[msg] = now
		main.hud.log(msg)
