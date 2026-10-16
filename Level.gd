extends Node2D

signal episode_completed
signal check_in_cancelled

const Agent := preload("res://Agents/Agent.gd")
const RandomAgent := preload("res://Agents/RandomAgent.gd")
const QLearningAgent := preload("res://Agents/QLearningAgent.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const Action = Agent.Action
const TICKS_PER_DECISION := Agent.TICKS_PER_DECISION
const ACTION_INPUTS := Agent.ACTION_INPUTS
const TRAINING_SPEEDS := [1, 2, 4, 8]

enum ControlMode { HUMAN, RANDOM, Q_LEARNING }
@export var control_mode := ControlMode.RANDOM
@export var death_y := 600.0
@export var episode_limit_seconds := 20.0

@onready var player: CharacterBody2D = $Player
@onready var spawn: Marker2D = $Spawn
@onready var orb: Area2D = $Orb
@onready var state_label: Label = %StateLabel
@onready var player_half_size: Vector2 = ($Player/CollisionShape2D.shape as RectangleShape2D).size * 0.5
@onready var orb_radius: float = ($Orb/CollisionShape2D.shape as CircleShape2D).radius

var headless_training := false
var check_in_mode := false
var display_state := false
var done := false
var reward := 0.0
var orb_collected := false
var deaths := 0
var orb_collections := 0
var timeouts := 0
var timed_out := false
var agent: RefCounted
var checkpoint_path := Checkpoint.DEFAULT_PATH
var checkpoint_status := "Save before leaving to keep this training."
var episode_return := 0.0
var last_episode_return := 0.0
var _decision_state: Dictionary = {}
var _decision_reward := 0.0
var _previous_proximity := 0.0

var _held_action_id := Action.DO_NOTHING
var _normal_tick_rate := Engine.physics_ticks_per_second
var _normal_max_steps := Engine.max_physics_steps_per_frame
var _normal_time_scale := Engine.time_scale


func _ready() -> void:
	_previous_proximity = _orb_proximity()
	if control_mode != ControlMode.HUMAN and agent == null:
		agent = QLearningAgent.new() if control_mode == ControlMode.Q_LEARNING else RandomAgent.new()
	if headless_training:
		hide()
		$HUD.hide()
		player.show_rays = false
		return
	if control_mode == ControlMode.Q_LEARNING:
		player.show_rays = true
		player.z_index = 1
		player.visible_ray_indices = QLearningAgent.State.RAY_INDICES
		%AgentPanel.show()
		for speed in TRAINING_SPEEDS:
			%SpeedSelect.add_item("%dx" % speed)
		%SpeedSelect.select(0)
		%ModeLabel.text = "Q-learning  |  10 decisions/game sec  |  R: restart episode"
		%MenuButton.tooltip_text = "Save Q-table before leaving to keep your latest training."
		%CheckpointControls.show()
		%SaveStatus.text = checkpoint_status
		%SaveStatus.tooltip_text = ProjectSettings.globalize_path(checkpoint_path)
		_update_agent_panel()
	else:
		%ModeLabel.text = "Human  |  A/D or arrows: move  |  Space: jump  |  R: reset" if control_mode == ControlMode.HUMAN else "Random agent  |  10 decisions/sec  |  R: reset"
	if check_in_mode:
		%EvaluationButton.hide()
		%SaveButton.hide()
		%CheckpointControls.hide()
		%SpeedSelect.get_parent().hide()
		%MenuButton.text = "Stop (Esc)"
		%MenuButton.tooltip_text = "Stop the batch. Training was saved before this check-in."
	_update_stats()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_return_to_menu()


func _return_to_menu() -> void:
	if check_in_mode:
		check_in_cancelled.emit()
		return
	get_tree().change_scene_to_file("res://MainMenu.tscn")


func _set_training_speed(index: int) -> void:
	if control_mode != ControlMode.Q_LEARNING or check_in_mode:
		return
	var speed: int = TRAINING_SPEEDS[index]
	# Scale both so each physics step still advances 1/60 of a game second.
	Engine.physics_ticks_per_second = _normal_tick_rate * speed
	Engine.max_physics_steps_per_frame = _normal_max_steps * speed
	Engine.time_scale = _normal_time_scale * speed
	%SpeedSelect.select(index)


func _exit_tree() -> void:
	if control_mode == ControlMode.Q_LEARNING:
		Engine.physics_ticks_per_second = _normal_tick_rate
		Engine.max_physics_steps_per_frame = _normal_max_steps
		Engine.time_scale = _normal_time_scale


func _save_checkpoint() -> void:
	if control_mode != ControlMode.Q_LEARNING or check_in_mode:
		return
	var error := Checkpoint.save_checkpoint(agent, checkpoint_path)
	%SaveStatus.text = "Saved: %d training episodes, %d updates." % [agent.training_episodes, agent.updates] if error.is_empty() else error


func _physics_process(delta: float) -> void:
	if check_in_mode:
		if not done:
			_step_agent(delta)
			_update_agent_panel()
		return
	if headless_training:
		if done:
			reset_episode()
		else:
			_step_agent(delta)
		return
	if Input.is_action_just_pressed("toggle_rays") and control_mode != ControlMode.Q_LEARNING:
		player.show_rays = not player.show_rays
		player.queue_redraw()
		display_state = not display_state
	if Input.is_action_just_pressed("reset") or done:
		reset_episode()
	elif control_mode == ControlMode.HUMAN:
		var axis := Input.get_axis("move_left", "move_right")
		var action_id := Action.MOVE_LEFT if axis < 0.0 else (Action.MOVE_RIGHT if axis > 0.0 else Action.DO_NOTHING)
		if Input.is_action_just_pressed("jump"):
			action_id += Action.JUMP
		_advance_tick(delta, action_id)
	else:
		_step_agent(delta)
	state_label.text = get_state_string() if display_state else ""
	_update_agent_panel()


func _step_agent(delta: float) -> void:
	var action_id := _held_action_id
	if _decision_required():
		_decision_state = get_state(agent.observation_rays)
		_decision_reward = 0.0
		action_id = agent.choose_action(_decision_state)
		if action_id < 0 or action_id >= ACTION_INPUTS.size():
			push_error("action_id must be between 0 and 5")
			return
	_advance_tick(delta, action_id)
	_decision_reward += reward
	episode_return += reward
	if done or _decision_required():
		var next_state := get_state(agent.observation_rays)
		agent.learn(_decision_state, next_state.action_id, _decision_reward, next_state)
		_decision_state = {}
	if done:
		agent.finish_episode(orb_collected)
		last_episode_return = episode_return
		episode_completed.emit()


func _toggle_evaluation() -> void:
	if control_mode != ControlMode.Q_LEARNING or check_in_mode:
		return
	agent.training = not agent.training
	agent.exploring = false
	if not agent.training:
		_set_training_speed(0)
		agent.evaluation_episodes = 0
		agent.evaluation_wins = 0
	# Discard the partial episode so one transition never spans training modes.
	reset_episode()
	_update_agent_panel()


func _update_agent_panel() -> void:
	if control_mode == ControlMode.Q_LEARNING:
		%AgentPanel.update_display(agent, last_episode_return)


func _decision_required() -> bool:
	return not done and player.tick % TICKS_PER_DECISION == 0


func step(delta: float, action_id: int) -> Dictionary:
	if done:
		return get_state()
	if action_id < 0 or action_id >= ACTION_INPUTS.size():
		push_error("action_id must be between 0 and 5")
		return get_state()
	if _decision_required():
		_held_action_id = action_id
	_advance_tick(delta, _held_action_id)
	return get_state()


func _advance_tick(delta: float, action_id: int) -> void:
	_held_action_id = action_id
	var action: Dictionary = ACTION_INPUTS[_held_action_id]
	player.set_action(action.move_axis, action.jump_pressed)
	player.physics_step(delta)
	_on_orb_body_entered(player)
	if done:
		return
	var proximity := _orb_proximity()
	reward = 0.1 * (proximity - _previous_proximity)
	_previous_proximity = proximity
	if player.position.y > death_y:
		done = true
		reward = -1.0
		deaths += 1
		_update_stats()
	elif control_mode != ControlMode.HUMAN and player.tick >= roundi(episode_limit_seconds * _normal_tick_rate):
		done = true
		timed_out = true
		reward = -1.0
		timeouts += 1
		_update_stats()


func reset_episode() -> Dictionary:
	player.reset_to(spawn.global_position)
	orb.show()
	done = false
	reward = 0.0
	orb_collected = false
	timed_out = false
	episode_return = 0.0
	_decision_state = {}
	_decision_reward = 0.0
	_held_action_id = Action.DO_NOTHING
	_previous_proximity = _orb_proximity()
	return get_state()


func get_state(ray_indices: Array = [0, 1, 2, 3, 4, 5, 6, 7]) -> Dictionary:
	var state: Dictionary = player.get_state(ray_indices)
	state["action_id"] = _held_action_id
	state["decision_required"] = _decision_required()
	state["done"] = done
	state["reward"] = reward
	state["orb_collected"] = orb_collected
	state["timed_out"] = timed_out
	state["orb_offset"] = (orb.global_position - player.global_position) / player.UNIT
	state["orb_proximity"] = _orb_proximity()
	return state


func get_state_string() -> String:
	var state := get_state()
	return player.get_state_string() + "\naction_id: %s\ndecision_required: %s\ndone: %s\nreward: %s\norb_collected: %s\norb_proximity: %s" % [state.action_id, state.decision_required, done, reward, orb_collected, _orb_proximity()]


func _orb_proximity() -> float:
	var start_distance := maxf(spawn.global_position.distance_to(orb.global_position), 1.0)
	return clampf(1.0 - player.global_position.distance_to(orb.global_position) / start_distance, 0.0, 1.0)


func _on_orb_body_entered(body: Node2D) -> void:
	if body != player or done:
		return
	# Signals can arrive after a reset, so confirm the player still touches the orb.
	var offset := orb.global_position - player.global_position
	var closest := Vector2(clampf(offset.x, -player_half_size.x, player_half_size.x), clampf(offset.y, -player_half_size.y, player_half_size.y))
	if offset.distance_squared_to(closest) > orb_radius * orb_radius:
		return
	orb_collected = true
	done = true
	reward = 1.0
	orb.hide()
	orb_collections += 1
	_update_stats()


func _update_stats() -> void:
	if headless_training:
		return
	%StatsLabel.text = "Episodes completed: %d\nDeaths: %d\nOrb collections: %d\nTimeouts: %d" % [deaths + orb_collections + timeouts, deaths, orb_collections, timeouts]
