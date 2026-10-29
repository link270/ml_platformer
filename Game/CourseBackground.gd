extends Node2D

# Quiet world-space landmarks: block coordinates increase from left to right.
var bounds := Rect2(0, 0, 960, 540)


func _init() -> void:
	z_index = -10


func _draw() -> void:
	var dot_color := Color(0.4, 0.45, 0.48, 0.18)
	var text_color := Color(0.5, 0.55, 0.58, 0.35)
	for x in range(int(bounds.position.x), int(bounds.end.x), 128):
		for y in range(int(bounds.position.y) + 192, int(bounds.end.y), 128):
			draw_circle(Vector2(x, y), 1.5, dot_color)
		if (x - int(bounds.position.x)) % 256 == 0:
			var label := str(roundi((x - bounds.position.x) / 32.0))
			draw_string(ThemeDB.fallback_font, Vector2(x + 6, bounds.position.y + 292), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, text_color)
