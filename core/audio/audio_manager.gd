class_name ArpgAudioManager
extends Node
## 音频架构（商业地基）：
## · 总线：Master / Music / SFX（运行时确保存在，音量由 ArpgSettings 驱动）
## · BGM：双播放器交叉淡入淡出切轨；按 key 播（theme/dungeon/town/boss）
## · SFX：10 池化播放器轮转 + 音源懒加载（从 main.play_sfx 迁入）
## · 曲目表来自 balance.audio，换曲=改 JSON

const BGM_PATHS := {
	"title": "res://assets/bgm/theme_title.ogg",
	"dungeon": "res://assets/bgm/bgm_dungeon.ogg",
	"town": "res://assets/bgm/bgm_town.ogg",
	"boss": "res://assets/bgm/bgm_boss.ogg",
}

var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _music_use_a := true
var _current_track := ""
var _sfx_pool: Array = []
var _sfx_i := 0
var _sfx_cache := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_bus("Music", 1)
	_ensure_bus("SFX", 2)
	_music_a = _make_player("Music")
	_music_b = _make_player("Music")
	for i in 10:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_sfx_pool.append(p)


func _ensure_bus(bus_name: String, idx: int) -> void:
	if AudioServer.get_bus_index(bus_name) == -1:
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")


func _make_player(bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus
	add_child(p)
	return p


## BGM 切轨：同名跳过；异名交叉淡入淡出（0.8s）
func play_music(track: String) -> void:
	if track == _current_track:
		return
	_current_track = track
	if not BGM_PATHS.has(track):
		return
	var stream: AudioStream = load(BGM_PATHS[track])
	var fade_out := _music_b if _music_use_a else _music_a
	var fade_in := _music_a if _music_use_a else _music_b
	_music_use_a = not _music_use_a
	if fade_out.playing:
		var tw := create_tween()
		tw.tween_property(fade_out, "volume_db", -40.0, 0.8)
		tw.tween_callback(fade_out.stop)
	fade_in.stream = stream
	fade_in.volume_db = -40.0
	fade_in.play()
	var tw2 := create_tween()
	tw2.tween_property(fade_in, "volume_db", -6.0, 0.8)


func stop_music() -> void:
	_current_track = ""
	for p in [_music_a, _music_b]:
		if p.playing:
			var tw := create_tween()
			tw.tween_property(p, "volume_db", -40.0, 0.5)
			tw.tween_callback(p.stop)


func play_sfx(sname: String, db: float = -6.0) -> void:
	if not _sfx_cache.has(sname):
		var path: String = main_sfx_path(sname)
		if path == "":
			return
		_sfx_cache[sname] = load(path)
	var p: AudioStreamPlayer = _sfx_pool[_sfx_i]
	_sfx_i = (_sfx_i + 1) % _sfx_pool.size()
	p.stop()
	p.stream = _sfx_cache[sname]
	p.volume_db = db
	p.play()


var _main_ref: Node
func setup(m: Node) -> void:
	_main_ref = m


func main_sfx_path(sname: String) -> String:
	return _main_ref.SFX[sname] if _main_ref != null and _main_ref.SFX.has(sname) else ""
