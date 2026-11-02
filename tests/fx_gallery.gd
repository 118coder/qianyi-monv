extends SceneTree
## 特效陈列室：把所有新特效定格渲染成一帧，验证贴图 / 旋转 / 色调。
## godot --write-movie ... -s res://tests/fx_gallery.gd

func _initialize() -> void:
	_run()


func _run() -> void:
	var ps: PackedScene = load("res://arpg/main.tscn")
	var main: Node = ps.instantiate()
	root.add_child(main)
	for i in 6:
		await process_frame
	main.start_run("fencer")
	for i in 3:
		await process_frame
	var w: ArpgWorld = main.world
	var p: Vector2 = main.player.position + Vector2(0, -4)

	# —— 上排：剑气（我方白 / 敌方红）、箭矢、法弹、弹幕、冲击波环 ——
	w.fx_tex(p + Vector2(-170, -80), ArpgTex.tex(ArpgWorld.FX_SLASH_PATH), -0.7, 0.85, 0.85, 99.0, Color(1, 1, 1, 0.95))
	w.fx_tex(p + Vector2(-100, -80), ArpgTex.tex(ArpgWorld.FX_SLASH_PATH), 0.9, 0.85, 0.85, 99.0, Color(1, 0.42, 0.36, 0.95))
	w.spawn_projectile(p + Vector2(-40, -80), Vector2.RIGHT, 0.0, 1, "player", Color(1, 0.92, 0.55), "arrow")
	w.spawn_projectile(p + Vector2(20, -80), Vector2.RIGHT, 0.0, 1, "player", Color(0.85, 0.55, 1.0), "orb")
	w.spawn_projectile(p + Vector2(80, -80), Vector2.RIGHT, 0.0, 1, "enemy", Color(1, 0.45, 0.2), "bullet")
	w.fx_tex(p + Vector2(160, -80), ArpgTex.tex(ArpgTex.tex(ArpgWorld.FX_SHOCKWAVE_PATH)_RING_PATH), 0.4, 1.0, 1.0, 99.0, Color(1, 0.6, 0.3, 0.95), 0.0, true)

	# —— 下排：命中火花、死亡烟尘、光环、法环、粒子爆发 ——
	w.fx_tex(p + Vector2(-170, 50), ArpgTex.tex(ArpgWorld.FX_SHOCKWAVE_PATH), 0.0, 0.42, 0.42, 99.0, Color(1, 0.95, 0.75, 0.95), 0.0, true)
	w.fx_tex(p + Vector2(-100, 50), ArpgWorld.FX_FOG, 0.3, 0.8, 0.8, 99.0, Color(0.92, 0.88, 0.85, 0.85))
	w.fx_tex(p + Vector2(-30, 50), ArpgTex.tex(ArpgWorld.FX_LIGHT_RING_PATH), 0.0, 0.7, 0.7, 99.0, Color(1, 0.85, 0.4, 0.95), 0.0, true)
	w.fx_tex(p + Vector2(50, 50), ArpgTex.tex(ArpgWorld.FX_RING_PATH), 0.0, 0.85, 0.85, 99.0, Color(0.6, 0.8, 1, 0.9), 0.0, true)
	w.burst(p + Vector2(130, 50), ArpgTex.tex(ArpgWorld.FX_PARTICLE_PATH), Color(1, 0.9, 0.5), 16, 170.0, 3.0, 0.1)

	_tag(w, p + Vector2(-170, -120), "Slash1白/红")
	_tag(w, p + Vector2(80, -120), "弹幕")
	_tag(w, p + Vector2(160, -120), "ShockRing")
	_tag(w, p + Vector2(-170, 14), "火花/烟/光环/法环")

	for i in 6:
		await process_frame
	print("GALLERY DONE")
	quit(0)


func _tag(w: ArpgWorld, pos: Vector2, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", w.ui_font)
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(1, 1, 0.7))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 3)
	l.position = pos
	l.z_index = 70
	w.add_child(l)
