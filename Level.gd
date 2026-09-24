extends Node2D

@export var death_y := 600.0

@onready var player: CharacterBody2D = $Player
@onready var spawn: Marker2D = $Spawn
@onready var orb: Area2D = $Orb
@onready var state_label: Label = %StateLabel
@onready var player_half_size: Vector2 = ($Player/CollisionShape2D.shape as RectangleShape2D).size * 0.5
@onready var orb_radius: float = ($Orb/CollisionShape2D.shape as CircleShape2D).radius

var display_state := false
var done := false
var reward := 0.0
var orb_collected := false
var _previous_proximity := 0.0

var ticks_to_hold_action: int = 6
var agent_dir := 0.0
var agent_jump := false

enum movement { LEFT, RIGHT, NEUTRAL }
var directions := { movement.RIGHT: 1.0, movement.LEFT: -1.0, movement.NEUTRAL: 0.0 }


func _ready() -> void:
	_previous_proximity = _orb_proximity()


func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("toggle_rays"):
		player.show_rays = not player.show_rays
		player.queue_redraw()
		display_state = not display_state
	if Input.is_action_just_pressed("reset"):
		reset_episode()
	elif not done:
		var state := get_state()
		if state.tick % ticks_to_hold_action == 0:
			agent_dir = directions[directions.keys().pick_random()]
			agent_jump = state.jump_allowed and randf() < 0.1
		step(delta, agent_dir, agent_jump)
		agent_jump = false
	state_label.text = get_state_string() if display_state else ""


func step(delta: float, move_axis: float, jump_pressed: bool) -> Dictionary:
	if done:
		return get_state()
	player.set_action(move_axis, jump_pressed)
	player.physics_step(delta)
	var offset := orb.global_position - player.global_position
	var closest := Vector2(clampf(offset.x, -player_half_size.x, player_half_size.x), clampf(offset.y, -player_half_size.y, player_half_size.y))
	if offset.distance_squared_to(closest) <= orb_radius * orb_radius:
		_on_orb_body_entered(player)
	if done:
		return get_state()
	var proximity := _orb_proximity()
	reward = 0.1 * (proximity - _previous_proximity)
	_previous_proximity = proximity
	if player.position.y > death_y:
		done = true
		reward = -1.0
	return get_state()


func reset_episode() -> Dictionary:
	player.reset_to(spawn.global_position)
	orb.show()
	done = false
	reward = 0.0
	orb_collected = false
	agent_dir = 0.0
	agent_jump = false
	_previous_proximity = _orb_proximity()
	return get_state()


func get_state() -> Dictionary:
	var state: Dictionary = player.get_state()
	state["done"] = done
	state["reward"] = reward
	state["orb_collected"] = orb_collected
	state["orb_proximity"] = _orb_proximity()
	return state


func get_state_string() -> String:
	return player.get_state_string() + "\ndone: %s\nreward: %s\norb_collected: %s\norb_proximity: %s" % [done, reward, orb_collected, _orb_proximity()]


func _orb_proximity() -> float:
	var start_distance := maxf(spawn.global_position.distance_to(orb.global_position), 1.0)
	return clampf(1.0 - player.global_position.distance_to(orb.global_position) / start_distance, 0.0, 1.0)


func _on_orb_body_entered(body: Node2D) -> void:
	if body != player or done:
		return
	orb_collected = true
	done = true
	reward = 1.0
	orb.hide()
