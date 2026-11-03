class_name ArpgPxfx
extends RefCounted
## pixelfx 序列帧特效库。
##
## 资源来源：https://github.com/patch-gg/pixelfx （MIT）。原库是**代码驱动**的 JS 特效，
## 不能在 GDScript 里直接跑，所以走「离线渲染成 sprite sheet」这条路：
##   1. vendor/pixelfx 里用 `node tools/render.mjs <id> --sheet --no-actor` 出 PNG + json；
##   2. `tools/build_pixelfx_fx.py` 负责缩放与合并元数据，产出 assets/fx/pxfx/fx_atlas.json；
##   3. 运行时只读这一个 atlas，用 Sprite2D 的 hframes/vframes 切帧。
##
## 为什么用 hframes/vframes 而不是 region_rect：
## pixelfx 的 sprite sheet 是**均匀网格**（meta.pixelfx.columns 给了列数），
## 用网格切帧可以直接吃引擎的帧动画机制，也不用每帧算矩形。
##
## 为什么 pivot 要换算成 offset：
## pixelfx 的 pivot 是「特效的作用点」（比如斩击的挥砍原点），不一定在图片中心。
## Sprite2D 的 centered=true 会把**帧中心**对齐到节点原点，所以要补一个
## `帧尺寸/2 - pivot` 的偏移，才能让作用点落在 position 上。

const ATLAS_PATH := "res://assets/fx/pxfx/fx_atlas.json"

static var _atlas := {}
static var _ok := false


static func _ensure() -> void:
	if _ok:
		return
	_ok = true
	if not FileAccess.file_exists(ATLAS_PATH):
		push_warning("[pxfx] 缺少 %s —— 先运行 python tools/build_pixelfx_fx.py" % ATLAS_PATH)
		return
	var f := FileAccess.open(ATLAS_PATH, FileAccess.READ)
	if f == null:
		push_warning("[pxfx] 无法打开 atlas")
		return
	var txt := f.get_as_text()
	f.close()
	var d = JSON.parse_string(txt)
	if d is Dictionary:
		var e = d.get("effects", {})
		if e is Dictionary:
			_atlas = e


static func has(n: String) -> bool:
	_ensure()
	return _atlas.has(n)


static func names() -> Array:
	_ensure()
	var out: Array = _atlas.keys()
	out.sort()
	return out


static func meta(n: String) -> Dictionary:
	_ensure()
	var d = _atlas.get(n, {})
	return d if d is Dictionary else {}


## 序列帧播放器：按 atlas 的 fps 推进，非循环特效播完自毁。
## 用 Sprite2D 而不是自绘：引擎已经处理了批处理与可见性，比自己算矩形省事且更快。
class Player extends Sprite2D:
	var fps := 30.0
	var total := 1
	var loop := false
	var speed := 1.0          # 播放倍速：>1 更快，用于把长特效压到合适的时长

	var _t := 0.0
	var _i := 0
	var _live := true

	## 元数据从外部传进来，而不是在这里查 ArpgPxfx 的静态表：
	## 内部类在脚本自身加载阶段还解析不到外层 class_name（会报 Identifier not found）。
	func setup(d: Dictionary) -> bool:
		if d.is_empty():
			return false
		var path := str(d.get("file", ""))
		var tex: Texture2D = ArpgTex.tex(path)
		if tex == null:
			push_warning("[pxfx] 纹理加载失败：%s" % path)
			return false
		texture = tex
		hframes = maxi(1, int(d.get("cols", 1)))
		vframes = maxi(1, int(d.get("rows", 1)))
		total = maxi(1, int(d.get("frames", 1)))
		fps = maxf(1.0, float(d.get("fps", 30)))
		loop = bool(d.get("loop", false))
		frame = 0
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var fw := float(d.get("frame_w", 0))
		var fh := float(d.get("frame_h", 0))
		var pv = d.get("pivot", null)
		var px := fw * 0.5
		var py := fh * 0.5
		if pv is Array and (pv as Array).size() >= 2:
			px = float(pv[0])
			py = float(pv[1])
		centered = true
		offset = Vector2(fw, fh) * 0.5 - Vector2(px, py)
		return true

	func _process(delta: float) -> void:
		if not _live:
			return
		_t += delta * maxf(speed, 0.05)
		var step := 1.0 / fps
		while _t >= step:
			_t -= step
			_i += 1
			if _i >= total:
				if loop:
					_i = 0
				else:
					_live = false
					queue_free()
					return
			frame = _i


## 造一个播放器，不负责挂载 —— 父节点与层级由调用方决定（特效要走 fx_root 的 z_index）
static func make(n: String) -> Player:
	_ensure()
	if not _atlas.has(n):
		return null
	var p := Player.new()
	if not p.setup(_atlas[n]):
		p.free()
		return null
	return p
