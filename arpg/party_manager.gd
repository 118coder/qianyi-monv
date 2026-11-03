class_name ArpgPartyManager
extends Node
## 队伍管理（需求书 §7 PartyManager）：动态列表（容量 N 配置化）、编队、共享寻路、
## 稳定 ID、经验分享、换层复活、存档序列化。绝不硬编码队伍人数。

var main: Node
var friends: Array = []              # Array[ArpgFriendUnit]
var nav := AStarGrid2D.new()
var _nav_floor := -1
var _nav_id := 0                     # 导航建在哪张 dungeon 实例上（同层重开必须重建）
var _uid_counter := 0
var _slot_of := {}                   # uid → 编队槽位（稳定：一旦分配不再变）

## 扇形编队角度（相对"队长背后"方向）：0 正后方，左右交替展开
const _FAN := [0.0, 0.55, -0.55, 1.05, -1.05, 1.55, -1.55, 2.85]
const _FAN_TRIES := [0.6, -0.6, 1.2, -1.2, 1.9, -1.9, 2.6, -2.6]


func setup(m: Node) -> void:
	main = m


func max_size() -> int:
	return int(ArpgPartyConfig.cfg("max_party_size"))


func friend_count() -> int:
	return friends.size()


## 占用队伍容量的单位数（APC counts_to_cap=false 不占）
func used_slots() -> int:
	var n := 0
	for f in friends:
		if not f.is_apc or bool(f.tags.get("counts_to_cap", true)):
			n += 1
	return n


func can_recruit() -> bool:
	return used_slots() < max_size()


func by_uid(uid: String) -> ArpgFriendUnit:
	for f in friends:
		if f.uid == uid:
			return f
	return null


## 目标表下标 → 单位（targets[1+k] 对应 friends[k]）
func friend_by_slot(k: int) -> ArpgFriendUnit:
	if k < 0 or k >= friends.size():
		return null
	var f = friends[k]
	return f if is_instance_valid(f) else null


func friend_slot(f: ArpgFriendUnit) -> int:
	return friends.find(f)


## 招募角色队友（容量满返回 null，禁止无声失败）
func recruit_char(char_id: String, cell: Vector2i) -> ArpgFriendUnit:
	if not can_recruit():
		main.hud.log("队伍已满（%d/%d），无法招募" % [used_slots(), max_size()])
		return null
	var tpl: Dictionary = ArpgBalance.CHARS.get(char_id, {})
	if tpl.is_empty():
		return null
	_uid_counter += 1
	var u := ArpgFriendUnit.new()
	var tpl_full := tpl.duplicate()
	tpl_full["id"] = char_id
	u.setup(main, main.world, "friend_%d" % _uid_counter, tpl_full, false, {})
	u.position = ArpgDungeon.cell_to_pos(cell)
	u.command = "follow"
	u.ai = ArpgAIController.new()
	u.ai.set_command(u, "follow")
	_actors().add_child(u)
	friends.append(u)
	main.hud.log("%s 加入了队伍！（%d/%d）" % [u.unit_name, used_slots(), max_size()])
	print("[AI] recruit %s (%s)" % [u.uid, char_id])
	return u


## 招募 APC（标签决定是否占容量 / 可指挥 / 可主控）
func recruit_apc(tag_id: String, cell: Vector2i) -> ArpgFriendUnit:
	var tags: Dictionary = ArpgPartyConfig.cfg("apc_tags").get(tag_id, {})
	var tpl: Dictionary = ArpgBalance.APC_UNITS.get(tag_id, {})
	if tags.is_empty() or tpl.is_empty():
		return null
	if bool(tags.get("counts_to_cap", true)) and not can_recruit():
		main.hud.log("队伍已满，无法招募 APC")
		return null
	_uid_counter += 1
	var u := ArpgFriendUnit.new()
	var tpl_full := tpl.duplicate()
	tpl_full["id"] = "apc:" + tag_id
	u.setup(main, main.world, "apc_%d" % _uid_counter, tpl_full, true, tags)
	u.position = ArpgDungeon.cell_to_pos(cell)
	u.command = "follow" if bool(tags.get("can_command", false)) else "hold"
	u.ai = ArpgAIController.new()
	u.ai.set_command(u, u.command)
	_actors().add_child(u)
	friends.append(u)
	main.hud.log("APC「%s」临时加入（%s）" % [u.unit_name, "可指挥" if bool(tags.get("can_command", false)) else "不可指挥"])
	print("[AI] recruit APC %s (%s)" % [u.uid, tag_id])
	return u


func remove_by_uid(uid: String) -> void:
	for f in friends:
		if f.uid == uid:
			if main.possession.is_possessed(f):
				main.possession.force_back_to_player()
			f.queue_free()
			friends.erase(f)
			return


func alive_friends() -> Array:
	var out := []
	for f in friends:
		if not f.dead:
			out.append(f)
	return out


## 可被主控的单位（玩家 + 标签允许的队友）
func possessable() -> Array:
	var out := [main.player]
	for f in alive_friends():
		if not f.is_apc or bool(f.tags.get("can_possess", false)):
			out.append(f)
	return out


## 松散编队点：**以主控单位为队长**，站在其背后呈扇面展开（不挡视线、不挤身位）
## 槽位一旦分配就固定（有人倒下不会让全队换位）；落点必做可走校验
func formation_point(unit) -> Vector2:
	var leader = _leader()
	if leader == null:
		return unit.position
	var dist := float(ArpgPartyConfig.cfg("command")["follow"]["follow_distance"])
	var idx := slot_index(unit)
	var ring := int(idx / 8)                       # 超过 8 人排第二圈
	var ang_off: float = float(_FAN[idx % 8])
	var fdir: Vector2 = _leader_facing(leader)
	if fdir.length_squared() < 0.01:
		fdir = Vector2.DOWN
	var back: Vector2 = -fdir.normalized()
	var radius: float = dist * (1.0 + 0.55 * float(ring))
	var p: Vector2 = leader.position + back.rotated(ang_off) * radius
	if _is_open(Vector2i((p / float(ArpgData.TILE)).floor())):
		return p
	# 背向点落在墙里（贴墙/贴角极常见）：沿同一半径左右试探，别再指向墙内
	for off in _FAN_TRIES:
		var p2: Vector2 = leader.position + back.rotated(ang_off + float(off)) * radius
		if _is_open(Vector2i((p2 / float(ArpgData.TILE)).floor())):
			return p2
	return ArpgDungeon.cell_to_pos(_nearest_open(Vector2i((p / float(ArpgData.TILE)).floor())))


## 编队槽位：按分配顺序编号，分配后固定（存档/换层都不重排）
func slot_index(unit) -> int:
	var id: String = str(unit.uid)
	if _slot_of.has(id):
		return int(_slot_of[id])
	var used := {}
	for k in _slot_of.values():
		used[int(k)] = true
	var n := 0
	while used.has(n):
		n += 1
	_slot_of[id] = n
	return n


## 队长 = 当前主控单位（切人后队友跟的是"你正在操作的那个人"，而不是永远跟剑士）
func _leader():
	if main == null:
		return null
	if main.possession != null and main.possession.current_unit != null \
			and is_instance_valid(main.possession.current_unit):
		return main.possession.current_unit
	return main.player


func _leader_facing(leader) -> Vector2:
	if leader == null:
		return Vector2.DOWN
	if leader is ArpgPlayer:
		return leader.facing
	if leader is ArpgFriendUnit:
		return leader.face_dir()
	if leader.has_method("face_dir"):
		return leader.call("face_dir")
	return Vector2.DOWN


func _is_open(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < nav.size.x and c.y < nav.size.y and not nav.is_point_solid(c)


## 网格直线视野（8px 采样）：供路径拉直 / 传送落点校验（对齐 autopilot 的做法）
func line_clear(a: Vector2, b: Vector2) -> bool:
	var dv := b - a
	var steps := int(dv.length() / 8.0) + 1
	var step := dv / float(steps)
	var p := a
	for s in steps:
		p += step
		if not _is_open(Vector2i((p / float(ArpgData.TILE)).floor())):
			return false
	return true


## 拉直路径（string pulling）：从当前点能直视的最远路点开始走 → 少切角、少蹭墙
func smooth_path(from: Vector2, pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	if pts.is_empty():
		return out
	var i := 0
	while i < pts.size() - 1 and line_clear(from, pts[i + 1]):
		i += 1
	for k in range(i, pts.size()):
		out.append(pts[k])
	return out


## 共享寻路（每层建一次 AStar；所有队友共用，查询预算由各自重拍间隔控制）
## ⚠️ 只比"楼层号 + 尺寸"是不够的：同层重开（读档/F3 重载/重开一局）会换一张新地图，
##    墙位完全不同却沿用旧 nav → 队友会往新地图的墙里走。故加实例 id 判定。
func build_nav(d: ArpgDungeon) -> void:
	if _nav_floor == main.floor_no and _nav_id == d.get_instance_id() \
			and nav.size == Vector2i(d.w, d.h):
		return
	nav.size = Vector2i(d.w, d.h)
	nav.cell_size = Vector2(ArpgData.TILE, ArpgData.TILE)
	nav.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	nav.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	nav.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	nav.update()
	for x in d.w:
		for y in d.h:
			if d.grid[x][y] != ArpgDungeon.FLOOR:
				nav.set_point_solid(Vector2i(x, y))
	_nav_floor = main.floor_no
	_nav_id = d.get_instance_id()


func nav_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var a := Vector2i((from / float(ArpgData.TILE)).floor())
	var b := Vector2i((to / float(ArpgData.TILE)).floor())
	a = _nearest_open(a)
	b = _nearest_open(b)
	var pts := nav.get_id_path(a, b)
	var out := PackedVector2Array()
	for c in pts:
		out.append(ArpgDungeon.cell_to_pos(c))
	return out


func _nearest_open(c: Vector2i) -> Vector2i:
	if not nav.is_point_solid(c):
		return c
	for r in range(1, 7):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var n := c + Vector2i(dx, dy)
				if n.x >= 0 and n.y >= 0 and n.x < nav.size.x and n.y < nav.size.y \
						and not nav.is_point_solid(n):
					return n
	return c


func gain_xp_all(xp: int) -> void:
	var ratio := float(ArpgPartyConfig.cfg("xp_share_ratio"))
	for f in alive_friends():
		f.gain_xp(int(xp * ratio))


func notify_death(uid: String) -> void:
	var f := by_uid(uid)
	main.hud.log("%s 倒下了……（下层%s）" % [
		f.unit_name if f != null else uid,
		"将复活" if bool(ArpgPartyConfig.cfg("revive_on_floor_change")) else "无法复活"])
	# 被主控的单位死亡 → 强制切回玩家（状态规则：死亡禁止保持主控）
	if f != null and main.possession.is_possessed(f):
		main.possession.force_back_to_player()


func revive_all_on_floor() -> void:
	if not bool(ArpgPartyConfig.cfg("revive_on_floor_change")):
		return
	var ratio := float(ArpgPartyConfig.cfg("revive_ratio"))
	var base: Vector2 = main.player.position
	if main.possession != null and is_instance_valid(main.possession.current_unit):
		base = main.possession.current_unit.position
	for f in friends:
		if f.dead:
			f.revive(ratio)
			# 复活落点必须可走（旧实现随机偏移，可能直接落进墙里 → 下一个 AI 周期继续卡）
			var ang := float(slot_index(f)) * (TAU / 6.0) + 0.7
			var p: Vector2 = base + Vector2.RIGHT.rotated(ang) * 42.0
			var c := Vector2i((p / float(ArpgData.TILE)).floor())
			if not _is_open(c):
				p = ArpgDungeon.cell_to_pos(_nearest_open(c))
			f.teleport_to(p)


## 三指令：小队级（T 键循环）与 单位级 两条入口
func set_squad_command(cmd: String) -> void:
	for f in alive_friends():
		if not f.is_apc or bool(f.tags.get("can_command", false)):
			f.ai.set_command(f, cmd)
	hud_log_cmd(cmd)


func set_command(uid: String, cmd: String) -> void:
	var f := by_uid(uid)
	if f == null or f.dead:
		return
	if f.is_apc and not bool(f.tags.get("can_command", false)):
		main.hud.log("APC「%s」不可指挥" % f.unit_name)
		return
	f.ai.set_command(f, cmd)
	hud_log_cmd(cmd)


func hud_log_cmd(cmd: String) -> void:
	main.hud.log("小队指令 → %s" % ArpgAIController.cmd_name(cmd))
	main.rumble(0.15, 0.3, 0.12)


## 存档：稳定 uid + 动态数量（需求书 §6）
func to_dict() -> Dictionary:
	var arr := []
	for f in friends:
		arr.append({
			"uid": f.uid, "char_id": f.char_id, "is_apc": f.is_apc,
			"hp": f.hp, "sp": f.sp, "command": f.command, "dead": f.dead,
		})
	return {
		"max_party_size": max_size(),
		"friends": arr,
		"player": {"hp": main.player.hp, "sp": main.player.sp,
			"command": main.player.command, "uid": main.player.uid},
		"possessed_uid": main.possession.current_unit.uid if main.possession.current_unit != null else "player",
	}


func from_dict(d: Dictionary) -> void:
	ArpgPartyConfig.CONFIG["max_party_size"] = int(d.get("max_party_size", 8))
	var pd: Dictionary = d.get("player", {})
	main.player.hp = int(pd.get("hp", main.player.max_hp))
	main.player.sp = int(pd.get("sp", main.player.sp))
	main.player.command = str(pd.get("command", "follow"))
	for fd in d.get("friends", []):
		var f := by_uid(str(fd["uid"]))
		if f == null:
			continue
		f.hp = int(fd.get("hp", f.max_hp))
		f.sp = int(fd.get("sp", f.sp))
		f.command = str(fd.get("command", "follow"))
		if bool(fd.get("dead", false)):
			f.die()
	# 主控恢复
	var puid := str(d.get("possessed_uid", "player"))
	if puid != "player":
		var f2 := by_uid(puid)
		if f2 != null and not f2.dead:
			main.possession.switch_to(f2, true)
	main.hud.log("已读取队伍存档（%d 名队友）" % friends.size())


func _actors() -> Node:
	return main.party_root
