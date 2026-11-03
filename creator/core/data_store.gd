extends RefCounted
## 创作器的数据层：读 / 写 / 备份 / 校验。
##
## 为什么单独抽一层：创作器直接改的是游戏运行时要读的 `balance.json` 与 `map001.json`，
## 一旦写坏，游戏就跑不起来。所以这里的三条硬规矩是：
##   1. **原子写**：先写同目录 `.tmp`，再 `rename` 覆盖。中途崩溃只会留下 .tmp，正式文件始终完整。
##   2. **写前备份**：正式文件先复制成 `xxx.bak.0/.1/.2`，只留最近 3 份，出问题能回滚。
##   3. **写前校验**：`balance` 必须含 `chars/enemies/max_floor`，`map` 必须含 `width/height/events`。
##      校验不过直接拒绝保存并返回原因，绝不落到磁盘。
##
## 运行时侧不需要任何改动：`ArpgBalance` 与 `SrpgMapLoader` 读的还是同两个文件，
## 游戏里的 `_hot_reload_watch` 会在文件变化后自动重载。

const BALANCE_PATH := "res://data/balance.json"
const MAP_PATH := "res://data/maps/map001.json"
const BACKUP_KEEP := 3
const TEMP_SUFFIX := ".tmp"


## 读 JSON；失败返回空字典并给出原因
static func load_json(path: String) -> Dictionary:
	var res := {"ok": false, "data": {}, "error": ""}
	if not FileAccess.file_exists(path):
		res["error"] = "文件不存在：" + path
		return res
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		res["error"] = "打开失败（错误码 %d）：%s" % [FileAccess.get_open_error(), path]
		return res
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if parsed == null or not (parsed is Dictionary):
		res["error"] = "JSON 解析失败，文件可能已被写坏：" + path
		return res
	res["ok"] = true
	res["data"] = parsed
	return res


## 校验：结构不对就不许保存
static func validate(which: String, data: Dictionary) -> String:
	if which == "balance":
		for k in ["chars", "enemies", "max_floor"]:
			if not data.has(k):
				return "缺少必需字段 `%s`，不是有效的数值文件" % k
		if int(data.get("max_floor", 0)) < 1:
			return "楼层总数必须 ≥ 1"
		if not (data.get("chars") is Dictionary) or (data.get("chars") as Dictionary).is_empty():
			return "角色表为空或格式错误"
	elif which == "map":
		for k in ["width", "height"]:
			if not data.has(k):
				return "缺少字段 `%s`" % k
		if int(data.get("width", 0)) < 4 or int(data.get("height", 0)) < 4:
			return "地图尺寸过小（至少 4×4）"
		if not (data.get("events") is Array):
			return "`events` 必须是数组"
	return ""


## 原子写 + 备份。返回 {"ok": bool, "error": String, "backup": String}
static func save_json(path: String, data: Dictionary, which: String) -> Dictionary:
	var err := validate(which, data)
	if err != "":
		return {"ok": false, "error": err, "backup": ""}

	var text := JSON.stringify(data, "  ", false)   # 2 空格缩进，人也能读
	var tmp := path + TEMP_SUFFIX
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "无法写入临时文件：%s" % tmp, "backup": ""}
	f.store_string(text)
	f.close()

	# 校验临时文件能被读回（防止字符串化出问题写出半个文件）
	var check := load_json(tmp)
	if not check["ok"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
		return {"ok": false, "error": "写出的内容无法解析，已放弃保存", "backup": ""}

	var backup := ""
	if FileAccess.file_exists(path):
		backup = _rotate_backup(path)

	var dir := path.get_base_dir()
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var abs_dst := ProjectSettings.globalize_path(path)
	var e := DirAccess.rename_absolute(abs_tmp, abs_dst)
	if e != OK:
		return {"ok": false, "error": "替换正式文件失败（错误码 %d）" % e, "backup": backup}
	return {"ok": true, "error": "", "backup": backup}


## 轮转备份：xxx.bak.0 最新，老的往后挪，超过 BACKUP_KEEP 份就删掉最旧的
static func _rotate_backup(path: String) -> String:
	for i in range(BACKUP_KEEP - 1, -1, -1):
		var src := "%s.bak.%d" % [path, i]
		if not FileAccess.file_exists(src):
			continue
		if i == BACKUP_KEEP - 1:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(src))
		else:
			DirAccess.rename_absolute(
				ProjectSettings.globalize_path(src),
				ProjectSettings.globalize_path("%s.bak.%d" % [path, i + 1]))
	var first := path + ".bak.0"
	var e := DirAccess.copy_absolute(ProjectSettings.globalize_path(path),
		ProjectSettings.globalize_path(first))
	return first if e == OK else ""


## 目录里已有的备份（供界面展示「可回滚到哪一版」）
static func list_backups(path: String) -> Array:
	var out: Array = []
	for i in BACKUP_KEEP:
		var p := "%s.bak.%d" % [path, i]
		if FileAccess.file_exists(p):
			var t := FileAccess.get_modified_time(p)
			out.append({"path": p, "time": Time.get_datetime_string_from_unix_time(int(t), true)})
	return out
