class_name ArpgSettings
extends Node
## 设置系统（需求 §6 非功能：所有可调项持久化 + 即时应用，禁止无声失败）。
## · user://settings.cfg，键不存在时用默认
## · apply() 即时生效：音频总线音量 / 震屏强度 / 震动强度 / 全屏
## · 菜单系统页的滑条直接调用 set_value

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"master_vol": 0.8,
	"music_vol": 0.7,
	"sfx_vol": 0.85,
	"screen_shake": 1.0,      # 0~1 倍率（0 = 无震屏，无障碍选项）
	"rumble": 1.0,            # 0~1 倍率
	"fullscreen": false,
}

var values := {}

signal changed(key: String, value: Variant)


func _ready() -> void:
	load_settings()
	apply_all()


func load_settings() -> void:
	values = DEFAULTS.duplicate()
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for k in DEFAULTS:
			values[k] = cfg.get_value("settings", k, DEFAULTS[k])


func set_value(key: String, v: Variant) -> void:
	if not values.has(key):
		push_warning("[SETTINGS] 未知设置项: " + key)
		return
	values[key] = v
	apply_key(key)
	var cfg := ConfigFile.new()
	cfg.load(PATH)   # 读入旧值防丢
	for k in values:
		cfg.set_value("settings", k, values[k])
	cfg.save(PATH)
	changed.emit(key, v)


func get_value(key: String) -> Variant:
	return values.get(key, DEFAULTS.get(key))


func apply_all() -> void:
	for k in values:
		apply_key(k)


func apply_key(key: String) -> void:
	match key:
		"master_vol", "music_vol", "sfx_vol":
			var bus := "Master" if key == "master_vol" else ("Music" if key == "music_vol" else "SFX")
			var idx := AudioServer.get_bus_index(bus)
			if idx >= 0:
				var v := float(values[key])
				AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(v, 0.0001)))
				AudioServer.set_bus_mute(idx, v <= 0.001)
		"fullscreen":
			if DisplayServer.get_name() != "headless":
				var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if bool(values[key]) else DisplayServer.WINDOW_MODE_WINDOWED
				DisplayServer.window_set_mode(mode)
		_:
			pass   # screen_shake / rumble 由 main 使用时读取
