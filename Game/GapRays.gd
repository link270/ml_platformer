extends RefCounted

const SAMPLE_STEP := 16.0
const EDGE_RANGE := 96.0
const LANDING_RANGE := 160.0
const PROBE_HEIGHT := 64.0
const HIGH_LANDING := 16.0
const KEY_SUFFIX := "\\|(00|[1-3][0-6])"
const MEMORY_KEY_SUFFIX := "\\|(00|[1-3][0-6]|a[1-4][12])"
const MEMORY_SIDE := 16.0
const MEMORY_NEAR := 48.0
const MEMORY_ABOVE := 4.0
const SCHEMA := {
	"sample_px": SAMPLE_STEP, "edge_range_px": EDGE_RANGE,
	"landing_range_px": LANDING_RANGE, "height_range_each_way_px": PROBE_HEIGHT,
	"higher_landing_px": HIGH_LANDING, "edge_bins_px": [32, 64, 96],
	"gap_width_bins_px": [32, 64], "airborne": "00",
}
const MEMORY_SCHEMA := {
	"source": "last_visible_far_lip_until_touchdown",
	"horizontal_bounds_px": [-MEMORY_SIDE, MEMORY_SIDE, MEMORY_NEAR],
	"feet_above_px": MEMORY_ABOVE,
}

var tracks_landing: bool
var _query := PhysicsRayQueryParameters2D.new()
var _tick := -1
var _direction := 0
var _observation := Vector2i.ZERO
var _visible_rays: Array[Vector2] = []
var _surface_hits := PackedByteArray()
var _has_landing := false
var _landing := Vector2.ZERO
var _landing_direction := 0


func _init(track_landing := false) -> void:
	tracks_landing = track_landing


func reset() -> void:
	_tick = -1
	clear_landing()
	_observation = Vector2i.ZERO
	_visible_rays.clear()
	_surface_hits.clear()


func clear_landing() -> void:
	_has_landing = false
	_tick = -1


func sample(player: CharacterBody2D, tick: int, grounded: bool, direction: int, draw_rays: bool) -> Vector2i:
	if _tick == tick and _direction == direction:
		return _observation
	_observation = Vector2i.ZERO
	_visible_rays.clear()
	_surface_hits.clear()
	_tick = tick
	_direction = direction
	var foot := player.global_position + Vector2(0.0, 16.0)
	if not grounded:
		if _has_landing:
			var ahead := (_landing.x - foot.x) * _landing_direction
			# Behind, aligned, near ahead, or far ahead of the last visible lip.
			_observation.x = 1 + int(ahead >= -MEMORY_SIDE) + int(ahead > MEMORY_SIDE) + int(ahead > MEMORY_NEAR)
			_observation.y = 1 if _landing.y - foot.y > MEMORY_ABOVE else 2
		return _observation

	_has_landing = false
	var space := player.get_world_2d().direct_space_state
	_query.collision_mask = player.collision_mask
	_query.hit_from_inside = true
	var first_missing := 0.0
	var distance := SAMPLE_STEP
	while distance <= LANDING_RANGE:
		var x := foot.x + direction * distance
		_query.from = Vector2(x, foot.y - PROBE_HEIGHT)
		_query.to = Vector2(x, foot.y + PROBE_HEIGHT)
		var hit := space.intersect_ray(_query)
		var has_surface := not hit.is_empty()
		if draw_rays:
			_visible_rays.append(_query.from)
			_visible_rays.append(hit.position if has_surface else _query.to)
			_surface_hits.append(int(has_surface))
		if first_missing == 0.0:
			if not has_surface:
				first_missing = distance
				_observation.x = ceili(first_missing / 32.0)
			elif distance == EDGE_RANGE:
				break
		elif has_surface:
			var width_bin := mini(3, ceili((distance - first_missing) / 32.0))
			var higher := foot.y - float(hit.position.y) > HIGH_LANDING
			_observation.y = (width_bin - 1) * 2 + (2 if higher else 1)
			if tracks_landing:
				_has_landing = true
				_landing = hit.position
				_landing_direction = direction
			break
		distance += SAMPLE_STEP
	return _observation


func draw(player: CharacterBody2D) -> void:
	for index in _surface_hits.size():
		var color := Color(1.0, 0.79, 0.34, 0.8) if _surface_hits[index] else Color(0.92, 0.29, 0.39, 0.7)
		var from := player.to_local(_visible_rays[index * 2])
		var to := player.to_local(_visible_rays[index * 2 + 1])
		player.draw_line(from, to, color, 1.0)
		player.draw_circle(to, 2.0, color)
	if _has_landing and not player.is_on_floor():
		var target := player.to_local(_landing)
		var memory_color := Color(0.45, 0.88, 1.0, 0.85)
		player.draw_dashed_line(Vector2.ZERO, target, memory_color, 1.0, 5.0)
		player.draw_arc(target, 5.0, 0.0, TAU, 20, memory_color, 1.5, true)
