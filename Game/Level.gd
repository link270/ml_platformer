extends Node2D

signal episode_completed
signal check_in_cancelled

const Agent := preload("res://Agents/Agent.gd")
const RandomAgent := preload("res://Agents/RandomAgent.gd")
const QLearningAgent := preload("res://Agents/QLearningAgent.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const EpisodeRecorder := preload("res://Training/EpisodeRecorder.gd")
const PathTrails := preload("res://Game/PathTrails.gd")
const Action = Agent.Action
const TICKS_PER_DECISION := Agent.TICKS_PER_DECISION
const TIME_PENALTY_PER_DECISION := 0.001
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
var run_limit := 0
var session_runs := 0
var session_finished := false
var autosave_training := false
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
var time_penalty_per_decision := TIME_PENALTY_PER_DECISION
var episode_return := 0.0
var last_episode_return := 0.0
var _decision_state: Dictionary = {}
var _decision_reward := 0.0
var _previous_proximity := 0.0
var record_every := 0
var recording_path := ""
var recording_episode_offset := 0
var recording_error := ""
var episode_recorder: RefCounted
var show_path_trails := false
var path_trails: Node2D
var _record_this_episode := false

var _held_action_id := Action.DO_NOTHING
var _normal_tick_rate := Engine.physics_ticks_per_second
var _normal_max_steps := Engine.max_physics_steps_per_frame
var _normal_time_scale := Engine.time_scale


func _ready() -> void:
	_previous_proximity = _orb_proximity()
	if control_mode != ControlMode.HUMAN and agent == null:
		agent = QLearningAgent.new() if control_mode == ControlMode.Q_LEARNING else RandomAgent.new()
	if control_mode == ControlMode.Q_LEARNING:
		time_penalty_per_decision = QLearningAgent.Presets.time_penalty(agent.preset_id)
	_setup_capture()
	if headless_training:
		hide()
		$HUD.hide()
		player.show_rays = false
		return
	if control_mode == ControlMode.Q_LEARNING:
		player.show_rays = true
		player.visible_ray_indices = QLearningAgent.State.RAY_INDICES
		for speed in TRAINING_SPEEDS:
			%SpeedSelect.add_item("%dx" % speed)
		%SpeedSelect.select(0)
		%ModeLabel.tooltip_text = QLearningAgent.Presets.PRESETS[agent.preset_id].description
		%SaveStatus.text = checkpoint_status
		%SaveStatus.tooltip_text = ProjectSettings.globalize_path(checkpoint_path)
		_update_agent_panel()
	else:
		%SpeedRow.hide()
		%DetailsButton.hide()
		%ModeLabel.text = "Human playable" if control_mode == ControlMode.HUMAN else "Random agent · Evaluation"
	if control_mode == ControlMode.HUMAN:
		%ControlsHint.text = "A / D  move     Space  jump     R  restart     V  sensors     Esc  menu"
	if check_in_mode:
		%EvaluationButton.hide()
		%SaveButton.hide()
		%CheckpointControls.hide()
		%SpeedRow.hide()
		%MenuButton.text = "Stop check-in"
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
	if autosave_training and agent != null and agent.training and not _save_checkpoint():
		return
	get_tree().change_scene_to_file("res://UI/MainMenu.tscn")


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
	if episode_recorder != null:
		episode_recorder.close()
	if control_mode == ControlMode.Q_LEARNING:
		Engine.physics_ticks_per_second = _normal_tick_rate
		Engine.max_physics_steps_per_frame = _normal_max_steps
		Engine.time_scale = _normal_time_scale


func _save_checkpoint() -> bool:
	if control_mode != ControlMode.Q_LEARNING or check_in_mode or not agent.training:
		return false
	var error := Checkpoint.save_checkpoint(agent, checkpoint_path)
	%SaveStatus.text = "Saved: %d training runs." % agent.training_episodes if error.is_empty() else error
	if not error.is_empty():
		%DetailsButton.button_pressed = true
		_show_details(true)
	return error.is_empty()


func _show_details(expanded: bool) -> void:
	%Details.visible = expanded
	%DetailsButton.text = "Less" if expanded else "More"


func _finish_session() -> void:
	session_finished = true
	if control_mode == ControlMode.Q_LEARNING:
		_set_training_speed(0)
		if autosave_training and agent.training:
			_save_checkpoint()
	_update_stats()


func _physics_process(delta: float) -> void:
	if session_finished:
		return
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
	if Input.is_action_just_pressed("toggle_rays"):
		player.show_rays = not player.show_rays
		player.queue_redraw()
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
	if _record_this_episode:
		episode_recorder.sample(player.position, action_id, agent.exploring if control_mode == ControlMode.Q_LEARNING else false, reward)
	if path_trails != null:
		path_trails.sample(player.position, done)
	if done or _decision_required():
		var next_state := get_state(agent.observation_rays)
		agent.learn(_decision_state, next_state.action_id, _decision_reward, next_state)
		_decision_state = {}
	if done:
		_finish_capture()
		agent.finish_episode(orb_collected)
		last_episode_return = episode_return
		session_runs += 1
		episode_completed.emit()
		if not recording_error.is_empty() or (run_limit > 0 and session_runs >= run_limit):
			_finish_session()
		elif not headless_training:
			_update_stats()


func _toggle_evaluation() -> void:
	if control_mode != ControlMode.Q_LEARNING or check_in_mode:
		return
	if autosave_training and agent.training and not _save_checkpoint():
		return
	recording_episode_offset += session_runs
	session_runs = 0
	session_finished = false
	deaths = 0
	orb_collections = 0
	timeouts = 0
	agent.training = not agent.training
	if path_trails != null:
		path_trails.clear()
	# A mode change starts another batch using the same selected data.
	if run_limit > 0:
		autosave_training = agent.training
	agent.exploring = false
	if not agent.training:
		_set_training_speed(0)
		agent.evaluation_episodes = 0
		agent.evaluation_wins = 0
	# Discard the partial episode so one transition never spans training modes.
	reset_episode()
	_update_agent_panel()
	_update_stats()


func _update_agent_panel() -> void:
	if control_mode == ControlMode.Q_LEARNING:
		%AgentPanel.update_display(agent, last_episode_return)
		%ModeLabel.text = QLearningAgent.Presets.PRESETS[agent.preset_id].label + " · " + ("Training" if agent.training else "Evaluation")
		%SpeedSelect.disabled = not agent.training or session_finished
		%SaveButton.disabled = not agent.training


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
	# Spread the time cost across physics ticks, including partial decisions.
	# Terminal rewards below remain exactly +1 / -1.
	reward = 0.1 * (proximity - _previous_proximity) - time_penalty_per_decision / TICKS_PER_DECISION
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
	_begin_capture()
	return get_state()


func _setup_capture() -> void:
	if control_mode == ControlMode.HUMAN:
		return
	if show_path_trails and not headless_training:
		path_trails = PathTrails.new()
		path_trails.z_index = 1
		add_child(path_trails)
	if record_every > 0:
		episode_recorder = EpisodeRecorder.new()
		if recording_path.is_empty():
			recording_path = EpisodeRecorder.new_path()
		var fingerprints := {}
		for source in ["res://Game/Level.tscn", "res://Game/Level.gd", "res://Game/Player.gd", "res://Agents/QLearningAgent.gd", "res://Agents/QState.gd", "res://Agents/QPresets.gd"]:
			fingerprints[source] = FileAccess.get_sha256(source)
		var metadata := {"physics_hz": _normal_tick_rate, "ticks_per_decision": TICKS_PER_DECISION,
			"record_every": record_every, "episode_offset": recording_episode_offset,
			"controller": ControlMode.keys()[control_mode], "engine": Engine.get_version_info().string,
			"source_sha256": fingerprints, "checkpoint": checkpoint_path}
		if control_mode == ControlMode.Q_LEARNING:
			metadata.preset_id = agent.preset_id
			metadata.starting_training_episodes = agent.training_episodes
		if not episode_recorder.open(recording_path, metadata):
			recording_error = episode_recorder.error
			session_finished = true
	_begin_capture()


func _begin_capture() -> void:
	_record_this_episode = false
	if path_trails != null:
		path_trails.begin_episode(player.position)
	var ordinal := recording_episode_offset + session_runs + 1
	if record_every > 0 and recording_error.is_empty() and ordinal % record_every == 0:
		var metadata := {"episode": ordinal, "training": control_mode == ControlMode.Q_LEARNING and agent.training}
		if control_mode == ControlMode.Q_LEARNING:
			metadata.training_episodes_before = agent.training_episodes
			metadata.epsilon = agent.epsilon
			metadata.rng_state_before = str(agent.rng.state)
		episode_recorder.begin_episode(metadata, player.position, roundi(episode_limit_seconds * _normal_tick_rate))
		_record_this_episode = true
	_update_recording_status()


func _finish_capture() -> void:
	var outcome := "success" if orb_collected else ("timeout" if timed_out else "death")
	if _record_this_episode:
		if not episode_recorder.finish_episode(outcome, episode_return):
			recording_error = episode_recorder.error
		_record_this_episode = false
	if path_trails != null:
		path_trails.finish_episode(outcome)
	_update_recording_status()


func _update_recording_status() -> void:
	if headless_training:
		return
	%RecordingStatus.visible = record_every > 0 or path_trails != null
	var text := "Trails · last 50 attempts" if path_trails != null else ""
	if record_every > 0:
		text += ("\n" if not text.is_empty() else "") + ("Recording error: " + recording_error if not recording_error.is_empty() else "Recording every %d · %d saved" % [record_every, episode_recorder.recorded_episodes])
	%RecordingStatus.text = text
	%RecordingStatus.tooltip_text = ProjectSettings.globalize_path(recording_path) if record_every > 0 else "Green: success · Red: death · Amber: timeout. Older paths fade each episode."


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
	var total := deaths + orb_collections + timeouts
	var success := "—" if total == 0 else "%.0f%%" % (100.0 * orb_collections / total)
	%StatsLabel.text = "Success  %s  ·  Wins  %d\nDeaths  %d  ·  Timeouts  %d" % [success, orb_collections, deaths, timeouts]
	if control_mode == ControlMode.HUMAN:
		%RunLabel.text = "Free play"
	else:
		var count := "%d / %d" % [session_runs, run_limit] if run_limit > 0 else str(total)
		%RunLabel.text = ("Finished · " if session_finished else "Runs  ") + count
