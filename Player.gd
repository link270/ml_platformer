extends CharacterBody2D

const UNIT := 32.0
# Clockwise from up; clearances are in units beyond the player's edge.
const DIRECTIONS := [Vector2.UP, Vector2(1, -1), Vector2.RIGHT, Vector2(1, 1), Vector2.DOWN, Vector2(-1, 1), Vector2.LEFT, Vector2(-1, -1)]

@export var max_horizontal_speed := 6.0
@export var horizontal_acceleration := 60.0
@export var braking_acceleration := 90.0
@export var max_upward_speed := 12.0
@export var upward_acceleration := 240.0
@export var gravity := 40.0
@export var max_fall_speed := 14.0
@export_range(2.0, 20.0) var ray_range_units := 2.0
@export var show_rays := false

var _move_axis := 0.0
var _jump_requested := false
var _launch_remaining := 0.0
var _grounded_ready := false
var _tick := 0
var _state: Dictionary
@onready var _rays := $Rays.get_children()


func _ready() -> void:
	for i in DIRECTIONS.size():
		var direction: Vector2 = DIRECTIONS[i].normalized()
		var boundary := 0.5 / maxf(absf(direction.x), absf(direction.y))
		_rays[i].target_position = direction * (boundary + ray_range_units) * UNIT
	_sample(0.0, false)


func set_action(move_axis: float, jump_pressed: bool) -> void:
	if not is_finite(move_axis):
		push_error("move_axis must be finite")
		return
	_move_axis = clampf(move_axis, -1.0, 1.0)
	_jump_requested = jump_pressed


func physics_step(delta: float) -> void:
	var applied_axis := _move_axis
	var applied_jump := _jump_requested
	var target := _move_axis * max_horizontal_speed * UNIT
	var acceleration := braking_acceleration if target == 0.0 or velocity.x * target < 0.0 else horizontal_acceleration
	velocity.x = move_toward(velocity.x, target, acceleration * UNIT * delta)

	if _jump_requested and _grounded_ready and is_on_floor():
		velocity.y = 0.0
		_launch_remaining = max_upward_speed / upward_acceleration
	_move_axis = 0.0
	_jump_requested = false

	if _launch_remaining > 0.0:
		var launch_time := minf(delta, _launch_remaining)
		velocity.y = maxf(velocity.y - upward_acceleration * UNIT * launch_time, -max_upward_speed * UNIT)
		_launch_remaining -= launch_time
	elif not is_on_floor():
		velocity.y = minf(velocity.y + gravity * UNIT * delta, max_fall_speed * UNIT)

	move_and_slide()
	_grounded_ready = true
	if is_on_floor():
		_launch_remaining = 0.0
		if velocity.y > 0.0:
			velocity.y = 0.0
	if is_on_ceiling():
		_launch_remaining = 0.0
		if velocity.y < 0.0:
			velocity.y = 0.0
	if is_on_wall():
		velocity.x = 0.0
	_tick += 1
	_sample(applied_axis, applied_jump)


func reset_to(spawn_position: Vector2) -> void:
	global_position = spawn_position
	velocity = Vector2.ZERO
	_move_axis = 0.0
	_jump_requested = false
	_launch_remaining = 0.0
	_grounded_ready = false
	_tick = 0
	_sample(0.0, false)


func get_state() -> Dictionary:
	return _state.duplicate(true)


func _sample(applied_axis: float, applied_jump: bool) -> void:
	var hits: Array[bool] = []
	var clearances: Array[float] = []
	for i in _rays.size():
		var ray: RayCast2D = _rays[i]
		ray.force_raycast_update()
		var hit := ray.is_colliding()
		hits.append(hit)
		var clearance := ray_range_units
		if hit:
			var direction: Vector2 = DIRECTIONS[i].normalized()
			var boundary := 0.5 / maxf(absf(direction.x), absf(direction.y))
			clearance = clampf(global_position.distance_to(ray.get_collision_point()) / UNIT - boundary, 0.0, ray_range_units)
		clearances.append(clearance)
	_state = {
		"tick": _tick,
		"action": {"move_axis": applied_axis, "jump_pressed": applied_jump},
		"position": position / UNIT,
		"velocity": velocity / UNIT,
		"grounded": _grounded_ready and is_on_floor(),
		"wall_contact": is_on_wall() if _grounded_ready else false,
		"ceiling_contact": is_on_ceiling() if _grounded_ready else false,
		"jump_allowed": _grounded_ready and is_on_floor(),
		"launch_active": _launch_remaining > 0.0,
		"launch_remaining": _launch_remaining,
		"ray_hits": hits,
		"ray_clearances": clearances,
	}
	if show_rays:
		queue_redraw()


func _draw() -> void:
	if not show_rays or _state.is_empty():
		return
	for i in _rays.size():
		var ray: RayCast2D = _rays[i]
		var hit: bool = _state.ray_hits[i]
		var color := Color.ORANGE_RED if hit else Color.LIME_GREEN
		var endpoint := to_local(ray.get_collision_point()) if hit else ray.target_position
		draw_line(Vector2.ZERO, endpoint, color, 1.0)
		draw_circle(endpoint, 3.0, color)
