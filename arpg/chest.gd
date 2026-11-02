class_name ArpgChest
extends Node2D
## 宝箱：E 键交互开启。有概率是陷阱箱（麻痹 / 召唤 / 传送），见 main.open_chest()。

var main: Node
var world: Node
var opened := false
var t := 0.0


func setup(m: Node, w: Node) -> void:
	main = m
	world = w
	z_index = 5


func _process(delta: float) -> void:
	t += delta
	if not opened:
		queue_redraw()


func _draw() -> void:
	var glow := 0.16 + sin(t * 3.0) * 0.08 if not opened else 0.0
	draw_circle(Vector2(0, -6), 15.0, Color(1, 0.85, 0.4, glow))
	# 箱体
	draw_rect(Rect2(-11, -6, 22, 15), Color(0.45, 0.28, 0.14), true)
	if opened:
		draw_rect(Rect2(-11, -6, 22, 6), Color(0.15, 0.1, 0.06), true)
		draw_rect(Rect2(-13, -16, 26, 7), Color(0.35, 0.22, 0.11), true)
	else:
		draw_rect(Rect2(-13, -12, 26, 7), Color(0.55, 0.36, 0.18), true)
		draw_rect(Rect2(-3, -12, 6, 8), Color(1, 0.85, 0.35), true)
	draw_rect(Rect2(-11, -6, 22, 15), Color(0.2, 0.12, 0.05), false, 1.5)
	draw_circle(Vector2(0, 10), 5.0, Color(0, 0, 0, 0.22))
