extends CharacterBody2D

const UNIT := 32.0

@export var max_horizontal_speed := 6.0
@export var horizontal_acceleration := 60.0
@export var braking_acceleration := 90.0
@export var max_upward_speed := 12.0
@export var upward_acceleration := 240.0
@export var gravity := 40.0
@export var max_fall_speed := 14.0

var _move_axis := 0.0
var _jump_requested := false
var _launch_remaining := 0.0
var _grounded_ready := false


func set_action(move_axis: float, jump_pressed: bool) -> void:
	if not is_finite(move_axis):
		push_error("move_axis must be finite")
		return
	_move_axis = clampf(move_axis, -1.0, 1.0)
	_jump_requested = jump_pressed


func physics_step(delta: float) -> void:
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


func reset_to(spawn_position: Vector2) -> void:
	global_position = spawn_position
	velocity = Vector2.ZERO
	_move_axis = 0.0
	_jump_requested = false
	_launch_remaining = 0.0
	_grounded_ready = false
