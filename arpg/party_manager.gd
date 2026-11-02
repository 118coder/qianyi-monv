class_name ArpgPartyManager
extends Node
## 队伍管理（需求书 §7 PartyManager）：动态列表（容量 N 配置化）、编队、共享寻路、
## 稳定 ID、经验分享、换层复活、存档序列化。绝不硬编码队伍人数。

var main: Node
var friends: Array = []              # Array[ArpgFriendUnit]
var nav := AStarGrid2D.new()
var _nav_floor := -1
var _uid_counter := 0


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


## 松散编队点：存活队友按序绕玩家均匀分布，避免挤门
func formation_point(unit) -> Vector2:
	var alive := alive_friends()
	var idx: int = alive.find(unit)
	if idx < 0:
		idx = 0
	var dist := float(ArpgPartyConfig.cfg("command")["follow"]["follow_distance"])
	var n := maxi(alive.size(), 1)
	var ang := TAU * idx / n + PI * 0.25
	return main.player.position + Vector2.RIGHT.rotated(ang) * dist


## 共享寻路（每层建一次 AStar；所有队友共用，查询预算由各自重拍间隔控制）
func build_nav(d: ArpgDungeon) -> void:
	if _nav_floor == main.floor_no and nav.size == Vector2i(d.w, d.h):
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
	for f in friends:
		if f.dead:
			f.revive(ratio)
			f.position = main.possession.current_unit.position + Vector2(randf_range(-40, 40), randf_range(-40, 40))


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
