extends CharacterBody2D

const UNIT := 32.0
# Clockwise from up; clearances are in units beyond the player's edge.
const DIRECTIONS := [Vector2.UP, Vector2(1, -1), Vector2.RIGHT, Vector2(1, 1), Vector2.DOWN, Vector2(-1, 1), Vector2.LEFT, Vector2(-1, -1)]

@export var horizontal_speed := 6.0
@export var jump_speed := 12.0
@export var gravity := 40.0
@export var max_fall_speed := 14.0
@export_range(2.0, 20.0) var ray_range_units := 2.0
@export var show_rays := false
var visible_ray_indices := [0, 1, 2, 3, 4, 5, 6, 7]

var _move_axis := 0.0
var _jump_requested := false
var _grounded_ready := false
var _tick := 0
var tick: int:
	get: return _tick
var _applied_axis := 0.0
var _applied_jump := false
var _sampled_rays := 0
var _ray_hits: Array[bool] = []
var _ray_clearances: Array[float] = []
var _ray_boundaries: Array[float] = []
@onready var _rays := $Rays.get_children()


func _ready() -> void:
	_ray_boundaries.resize(DIRECTIONS.size())
	_ray_hits.resize(DIRECTIONS.size())
	_ray_clearances.resize(DIRECTIONS.size())
	_ray_clearances.fill(ray_range_units)
	for i in DIRECTIONS.size():
		# Observations and drawing refresh rays explicitly after movement.
		_rays[i].enabled = false
		var direction: Vector2 = DIRECTIONS[i].normalized()
		var boundary := 0.5 / maxf(absf(direction.x), absf(direction.y))
		_ray_boundaries[i] = boundary
		_rays[i].target_position = direction * (boundary + ray_range_units) * UNIT
	# Preserve the spawn observation before the first physics step.
	_sample_rays([0, 1, 2, 3, 4, 5, 6, 7])


func set_action(move_axis: float, jump_pressed: bool) -> void:
	if not is_finite(move_axis):
		push_error("move_axis must be finite")
		return
	_move_axis = signf(move_axis)
	_jump_requested = jump_pressed


func physics_step(delta: float) -> void:
	_applied_axis = _move_axis
	_applied_jump = _jump_requested
	velocity.x = _move_axis * horizontal_speed * UNIT

	if _jump_requested and _grounded_ready and is_on_floor():
		velocity.y = -jump_speed * UNIT
	elif not is_on_floor():
		velocity.y = minf(velocity.y + gravity * UNIT * delta, max_fall_speed * UNIT)
	_move_axis = 0.0
	_jump_requested = false

	move_and_slide()
	_grounded_ready = true
	if is_on_floor():
		if velocity.y > 0.0:
			velocity.y = 0.0
	if is_on_ceiling():
		if velocity.y < 0.0:
			velocity.y = 0.0
	if is_on_wall():
		velocity.x = 0.0
	_tick += 1
	_sampled_rays = 0
	if show_rays:
		_sample_rays(visible_ray_indices)
		queue_redraw()


func reset_to(spawn_position: Vector2) -> void:
	global_position = spawn_position
	velocity = Vector2.ZERO
	_move_axis = 0.0
	_jump_requested = false
	_grounded_ready = false
	_tick = 0
	_applied_axis = 0.0
	_applied_jump = false
	_sampled_rays = 0
	if show_rays:
		_sample_rays(visible_ray_indices)
		queue_redraw()


func get_state(ray_indices: Array = [0, 1, 2, 3, 4, 5, 6, 7]) -> Dictionary:
	_sample_rays(ray_indices)
	var grounded := _grounded_ready and is_on_floor()
	# Fresh snapshots keep agents/callers from changing live or earlier observations.
	return {
		"tick": _tick,
		"action": {"move_axis": _applied_axis, "jump_pressed": _applied_jump},
		"position": position / UNIT,
		"velocity": velocity / UNIT,
		"grounded": grounded,
		"wall_contact": is_on_wall() if _grounded_ready else false,
		"ceiling_contact": is_on_ceiling() if _grounded_ready else false,
		"jump_allowed": grounded,
		"ray_hits": _ray_hits.duplicate(),
		"ray_clearances": _ray_clearances.duplicate(),
	}


func get_state_string() -> String:
	var lines := PackedStringArray()
	var state := get_state()
	for key in state:
		lines.append("%s: %s" % [key, state[key]])
	return "\n".join(lines)


func _sample_rays(ray_indices: Array) -> void:
	var origin := global_position
	# Only requested indices are current; the default get_state() requests all eight.
	for i in ray_indices:
		if _sampled_rays & (1 << i):
			continue
		var ray: RayCast2D = _rays[i]
		ray.force_raycast_update()
		var hit := ray.is_colliding()
		_ray_hits[i] = hit
		var clearance := ray_range_units
		if hit:
			clearance = clampf(origin.distance_to(ray.get_collision_point()) / UNIT - _ray_boundaries[i], 0.0, ray_range_units)
		_ray_clearances[i] = clearance
		_sampled_rays |= 1 << i


func _draw() -> void:
	if not show_rays:
		return
	_sample_rays(visible_ray_indices)
	for i in visible_ray_indices:
		var ray: RayCast2D = _rays[i]
		var hit: bool = _ray_hits[i]
		var color := Color.ORANGE_RED if hit else Color.LIME_GREEN
		var endpoint := to_local(ray.get_collision_point()) if hit else ray.target_position
		draw_line(Vector2.ZERO, endpoint, color, 1.0)
		draw_circle(endpoint, 3.0, color)
