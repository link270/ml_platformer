extends Node2D

# Count episodes visiting each character-center cell, never time spent there.
signal totals_changed

const CELL_SIZE := 16.0
const COLORS := [Color(0.18, 0.3, 1.0), Color(0.0, 0.9, 1.0), Color(1.0, 0.9, 0.1), Color(1.0, 0.18, 0.08)]
var bounds := Rect2(0, 0, 960, 540)
var counts: Dictionary = {}
var completed_episodes := 0
var active_episodes: Dictionary = {}
var _dirty := false


func _init() -> void:
	visible = false
	z_index = -1


func begin_episode(id: int, position: Vector2) -> void:
	# Reusing an ID restarts a partial attempt, removing its earlier contribution.
	abort_episode(id)
	active_episodes[id] = {}
	sample(id, position)
	_dirty = true
	totals_changed.emit()


func sample(id: int, position: Vector2) -> void:
	if not active_episodes.has(id) or not position.is_finite() or not bounds.has_point(position):
		return
	var cell := Vector2i(floori((position.x - bounds.position.x) / CELL_SIZE), floori((position.y - bounds.position.y) / CELL_SIZE))
	var visited: Dictionary = active_episodes[id]
	if visited.has(cell):
		return
	visited[cell] = true
	counts[cell] = int(counts.get(cell, 0)) + 1
	_dirty = true


func finish_episode(id: int) -> void:
	if not active_episodes.has(id):
		return
	active_episodes.erase(id)
	completed_episodes += 1
	totals_changed.emit()


func abort_episode(id: int) -> void:
	if not active_episodes.has(id):
		return
	for cell in active_episodes[id]:
		var remaining := int(counts[cell]) - 1
		if remaining == 0:
			counts.erase(cell)
		else:
			counts[cell] = remaining
	active_episodes.erase(id)
	_dirty = true
	totals_changed.emit()


func clear() -> void:
	counts.clear()
	active_episodes.clear()
	completed_episodes = 0
	_dirty = true
	totals_changed.emit()


func episode_count() -> int:
	return completed_episodes + active_episodes.size()


func frequency(cell: Vector2i) -> float:
	return float(counts.get(cell, 0)) / maxi(episode_count(), 1)


static func color_for_fraction(fraction: float) -> Color:
	var scaled := clampf(fraction, 0.0, 1.0) * (COLORS.size() - 1)
	var index := mini(int(scaled), COLORS.size() - 2)
	return COLORS[index].lerp(COLORS[index + 1], scaled - index)


func _process(_delta: float) -> void:
	if _dirty and visible:
		queue_redraw()
		_dirty = false


func _draw() -> void:
	for cell in counts:
		var fraction := frequency(cell)
		var color := color_for_fraction(fraction)
		color.a = lerpf(0.2, 0.7, fraction)
		var rect := Rect2(bounds.position + Vector2(cell) * CELL_SIZE, Vector2.ONE * CELL_SIZE)
		draw_rect(rect.intersection(bounds), color)
