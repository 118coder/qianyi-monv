extends RefCounted
## 数据库实体预览卡 + 数值参数摘要表（中央预览区的内容）。
##
## 项目红线：预览只渲染真实存在、运行时真的会读的字段——
## 数据唯一来源是传入的 balance 字典（与右栏编辑器是同一份引用），
## 所以在右栏改数值，重新路由/刷新后预览必然同步，不存在「第二份事实」。

const UI := preload("res://creator/core/ui_kit.gd")
const SpriteView := preload("res://creator/core/sprite_view.gd")

## 各类实体的字段展示顺序；没列出的标量按原字典顺序排在后面
const ORDER := {
	"chars": ["title", "hp", "sp", "atk", "spd", "atk_cd", "atk_range", "proj_spd", "weapon", "skill", "growth"],
	"enemies": ["hp", "atk", "spd", "move", "cool", "windup", "behavior", "proj_spd", "atk_range"],
	"items": ["desc", "price", "heal", "tier"],
	"equipment": ["desc", "price", "slots", "atk", "def"],
	"skills": ["desc", "power", "cost", "cd", "sp"],
	"quests": ["desc"],
	"boss": ["hp", "atk", "spd"],
}

const KIND_ZH := {
	"chars": "角色", "enemies": "怪物", "boss": "首领", "items": "物品",
	"equipment": "装备", "skills": "技能", "quests": "任务",
}


## 实体预览卡。kind 决定字段顺序，ent 必须是 balance 里的原字典。
static func build(parent: Node, kind: String, id: String, ent: Variant) -> void:
	var box := UI.card(parent, 16)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not (ent is Dictionary):
		UI.hint(box, "这一条不是字典结构，无法预览。原始值：" + str(ent))
		return
	var e: Dictionary = ent

	# —— 头部：大精灵 + 名称/称号 ——
	var head := UI.hbox(box, 16)
	var spr: Array = e.get("sprite", []) if e.get("sprite") is Array else []
	if spr.size() >= 3:
		var frame := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color("0b0a09")
		sb.set_corner_radius_all(4)
		sb.set_border_width_all(1)
		sb.border_color = UI.LINE
		sb.set_content_margin_all(6)
		frame.add_theme_stylebox_override("panel", sb)
		head.add_child(frame)
		var sv := SpriteView.new()
		sv.custom_minimum_size = Vector2(140, 140)
		sv.set_sprite(str(spr[0]), int(spr[1]), int(spr[2]))
		frame.add_child(sv)
	var info := UI.vbox(head, 4)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := UI.hbox(info, 10)
	UI.label(nm, str(e.get("name", id)), 21, UI.TEXT)
	UI.id_chip(nm, id)
	if e.has("title"):
		UI.label(info, str(e["title"]), 13, UI.ACCENT)
	if e.has("desc"):
		var d := UI.hint(info, str(e["desc"]))
		d.custom_minimum_size.y = 34

	UI.hsep(box)

	# —— 字段区：按 ORDER 顺序，未列出的标量跟在后面 ——
	var done := {}
	_order_for(kind, e, func(k: String):
		done[k] = true
		_render_field(box, kind, e, k)
	)
	for k in e.keys():
		if done.has(str(k)) or str(k) in ["name", "sprite"]:
			continue
		_render_field(box, kind, e, str(k))


static func _order_for(kind: String, e: Dictionary, cb: Callable) -> void:
	for k in ORDER.get(kind, []):
		if e.has(k):
			cb.call(str(k))


static func _render_field(box: Node, kind: String, e: Dictionary, k: String) -> void:
	var v = e[k]
	match k:
		"skill":
			if v is Dictionary:
				var s := UI.inspector_section(box, "技能 · " + str(v.get("name", "")), UI.MOD_EVENTS)
				for sk in (v as Dictionary).keys():
					_stat_row(s, str(sk), v[sk])
		"growth":
			if v is Dictionary:
				var g := UI.inspector_section(box, "成长（每级）", UI.OK)
				for gk in (v as Dictionary).keys():
					_stat_row(g, str(gk), v[gk])
		"title":
			pass   # 头部已展示
		"desc":
			pass   # 头部已展示
		_:
			if v is Dictionary:
				var sec := UI.inspector_section(box, UI.pretty(k), UI.MOD_DATABASE)
				for sk in (v as Dictionary).keys():
					_stat_row(sec, str(sk), v[sk])
			elif v is Array:
				_array_section(box, k, v)
			else:
				_stat_row(box, k, v)


## 二元数组（掉落表 [["imp",8], ...]）逐行「名 ×n」，普通数组逗号连接
static func _array_section(box: Node, k: String, arr: Array) -> void:
	var all_pairs := arr.size() > 0
	for it in arr:
		if not (it is Array and (it as Array).size() == 2):
			all_pairs = false
			break
	if all_pairs:
		var sec := UI.inspector_section(box, UI.pretty(k) + "（%d 项）" % arr.size(), UI.MOD_NUMBERS)
		for it in arr:
			_stat_row(sec, str(it[0]), "×" + str(it[1]))
	else:
		var parts := PackedStringArray()
		for it in arr:
			parts.append(str(it))
		_stat_row(box, k, "，".join(parts))


static func _stat_row(parent: Node, k: String, v: Variant) -> void:
	var h := UI.hbox(parent, 10)
	var l := UI.label(h, UI.pretty(k), 13, UI.DIM)
	l.custom_minimum_size.x = 116
	l.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	UI.mono_label(h, str(v), 13, UI.TEXT)


# ———————— 数值参数摘要（中央预览） ————————

## 把 balance 的一组参数铺成只读摘要表；编辑在右栏，这里负责「一眼看全」。
static func params_table(parent: Node, key: String, value: Variant) -> void:
	var box := UI.card(parent, 16)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var head := UI.hbox(box, 10)
	UI.label(head, UI.pretty(key), 18, UI.TEXT)
	UI.mono_label(head, key, 12, UI.DIM)
	UI.hsep(box)
	_rows(box, value, 0)


static func _rows(parent: Node, v: Variant, depth: int) -> void:
	if v is Dictionary:
		var d: Dictionary = v
		if depth > 0:
			UI.label(parent, "· " + "／".join(_keys_zh(d)), 13, UI.ACCENT)
		for k in d.keys():
			var sub = d[k]
			if sub is Dictionary:
				_rows(parent, sub, depth + 1)
			elif sub is Array:
				_stat_row(parent, str(k), _arr_text(sub))
			else:
				_stat_row(parent, str(k), sub)
	else:
		_stat_row(parent, "value", _arr_text(v))


static func _keys_zh(d: Dictionary) -> Array:
	var out := PackedStringArray()
	for k in d.keys():
		out.append(UI.pretty(str(k)))
	return Array(out)


static func _arr_text(arr: Array) -> String:
	var parts := PackedStringArray()
	for i in mini(arr.size(), 8):
		parts.append(str(arr[i]))
	var s := "，".join(parts)
	if arr.size() > 8:
		s += " …共 %d 项" % arr.size()
	return s
