extends Node2D

const HISTORY_LIMIT := 50
const ACTIVE_COLOR := Color(0.3, 0.95, 1.0, 0.95)
var history: Array[Dictionary] = []
var current := PackedVector2Array()
var _dirty := false
var active_color := ACTIVE_COLOR


func begin_episode(position: Vector2) -> void:
	current = PackedVector2Array([position])
	_dirty = true


func sample(position: Vector2, terminal: bool = false) -> void:
	if current.is_empty():
		begin_episode(position)
		return
	var last := current.size() - 1
	if not terminal and current[last].distance_squared_to(position) < 9.0:
		return
	# Straight sections need only their endpoints; retain the shape of jumps.
	if last > 0:
		var previous := current[last] - current[last - 1]
		var next := position - current[last]
		if previous.dot(next) >= 0.0 and absf(previous.cross(next)) < 0.25 * previous.length():
			current[last] = position
		else:
			current.append(position)
	else:
		current.append(position)
	_dirty = true


func finish_episode(outcome: String) -> void:
	remember(current, outcome)
	current = PackedVector2Array()


func remember(points: PackedVector2Array, outcome: String) -> void:
	history.append({"points": points, "outcome": outcome})
	if history.size() > HISTORY_LIMIT:
		history.pop_front()
	_dirty = true


func clear() -> void:
	history.clear()
	current = PackedVector2Array()
	_dirty = true


func _process(_delta: float) -> void:
	if _dirty:
		queue_redraw()
		_dirty = false


func _draw() -> void:
	for i in history.size():
		var points: PackedVector2Array = history[i].points
		var alpha := lerpf(0.035, 0.3, float(i + 1) / history.size())
		if points.size() > 1:
			draw_polyline(points, Color(0.55, 0.7, 0.75, alpha), 1.5, true)
		if not points.is_empty():
			var color := Color(0.3, 1.0, 0.5) if history[i].outcome == "success" else Color(1.0, 0.4, 0.3)
			if history[i].outcome == "timeout":
				color = Color(1.0, 0.75, 0.25)
			elif history[i].outcome == "stuck":
				color = Color(0.7, 0.5, 1.0)
			color.a = alpha + 0.15
			draw_circle(points[-1], 3.0, color)
	if current.size() > 1:
		draw_polyline(current, active_color, 2.0, true)
