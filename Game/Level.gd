extends Node2D

signal episode_completed
signal check_in_cancelled

const Player := preload("res://Game/Player.gd")
const Agent := preload("res://Agents/Agent.gd")
const RandomAgent := preload("res://Agents/RandomAgent.gd")
const QLearningAgent := preload("res://Agents/QLearningAgent.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const EpisodeRecorder := preload("res://Training/EpisodeRecorder.gd")
const PathTrails := preload("res://Game/PathTrails.gd")
const PathHeatMap := preload("res://Game/PathHeatMap.gd")
const CourseBackground := preload("res://Game/CourseBackground.gd")
const Action = Agent.Action
const TICKS_PER_DECISION := Agent.TICKS_PER_DECISION
const TIME_PENALTY_PER_DECISION := 0.001
const ACTION_INPUTS := Agent.ACTION_INPUTS
const TRAINING_SPEEDS := [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0]
const NORMAL_SPEED_INDEX := 1
const STUCK_PATIENCE_SECONDS := 8.0
static var whole_level_view := false

enum ControlMode { HUMAN, RANDOM, Q_LEARNING }
@export var control_mode := ControlMode.RANDOM
@export var death_y := 600.0
@export var episode_limit_seconds := 20.0
@export var world_bounds := Rect2(0, 0, 960, 540)
@export var stuck_detection_enabled := false

@onready var player: Player = $Player
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
var stuck := false
var stuck_count := 0
var _last_progress_tick := 0
var _progress_checkpoint_distance := 0.0
var agent: RefCounted
var checkpoint_path := Checkpoint.DEFAULT_PATH
var checkpoint_status := "Save before leaving to keep this training."
var time_penalty_per_decision := TIME_PENALTY_PER_DECISION
var episode_return := 0.0
var last_episode_return := 0.0
var _decision_state: Dictionary = {}
var _decision_reward := 0.0
var _previous_proximity := 0.0
var _previous_orb_distance := 0.0
var record_every := 0
var recording_path := ""
var recording_episode_offset := 0
var recording_error := ""
var episode_recorder: RefCounted
var show_path_trails := false
var path_trails: Node2D
var heat_map: Node2D
var _record_this_episode := false

var _held_action_id := Action.DO_NOTHING
var _normal_tick_rate := Engine.physics_ticks_per_second
var _normal_max_steps := Engine.max_physics_steps_per_frame
var _normal_time_scale := Engine.time_scale
var _view_camera: Camera2D


func _ready() -> void:
	_previous_proximity = _orb_proximity()
	_previous_orb_distance = player.global_position.distance_to(orb.global_position)
	_progress_checkpoint_distance = _previous_orb_distance
	if control_mode != ControlMode.HUMAN and agent == null:
		agent = QLearningAgent.new() if control_mode == ControlMode.Q_LEARNING else RandomAgent.new()
	if control_mode == ControlMode.Q_LEARNING:
		time_penalty_per_decision = QLearningAgent.Presets.time_penalty(agent.preset_id)
	_setup_capture()
	if headless_training:
		hide()
		$HUD.hide()
		player.show_rays = false
		var camera := player.get_node_or_null("Camera2D") as Camera2D
		if camera != null:
			camera.enabled = false
		set_process(false)
		return
	_setup_view()
	if control_mode != ControlMode.HUMAN:
		for speed in TRAINING_SPEEDS:
			%SpeedSelect.add_item("%.1fx" % speed if speed < 1.0 else "%dx" % int(speed))
		%SpeedSelect.select(NORMAL_SPEED_INDEX)
	if control_mode == ControlMode.Q_LEARNING:
		player.show_rays = true
		player.visible_ray_indices = QLearningAgent.State.RAY_INDICES
		%ModeLabel.tooltip_text = QLearningAgent.Presets.PRESETS[agent.preset_id].description
		%SaveStatus.text = checkpoint_status
		%SaveStatus.tooltip_text = ProjectSettings.globalize_path(checkpoint_path)
		_update_agent_panel()
	else:
		%SpeedRow.visible = control_mode != ControlMode.HUMAN
		%DetailsButton.hide()
		%ModeLabel.text = "Human playable" if control_mode == ControlMode.HUMAN else "Random agent · Evaluation"
	if control_mode == ControlMode.HUMAN:
		%ControlsHint.text = "A / D  move     Space  jump     R  restart     V  sensors     Esc  menu"
	if check_in_mode:
		%EvaluationButton.hide()
		%SaveButton.hide()
		%CheckpointControls.hide()
		%MenuButton.text = "Stop check-in"
		%MenuButton.tooltip_text = "Stop the batch. Training was saved before this check-in."
	_update_stats()


func _setup_view() -> void:
	var background := CourseBackground.new()
	background.bounds = world_bounds
	add_child(background)
	_view_camera = player.get_node_or_null("Camera2D") as Camera2D
	if _view_camera == null:
		_view_camera = Camera2D.new()
		_view_camera.name = "Camera2D"
		player.add_child(_view_camera)
	_view_camera.top_level = true
	var zoom_button := Button.new()
	zoom_button.name = "WholeLevelView"
	zoom_button.text = "Whole level"
	zoom_button.toggle_mode = true
	zoom_button.focus_mode = Control.FOCUS_NONE
	zoom_button.tooltip_text = "Fit the whole level, or follow the player. Remembered for this app session."
	zoom_button.set_pressed_no_signal(whole_level_view)
	zoom_button.toggled.connect(_set_whole_level_view)
	var top_bar := $HUD/TopBar
	top_bar.add_child(zoom_button)
	top_bar.move_child(zoom_button, %MenuButton.get_index())
	_update_view_camera()


func _set_whole_level_view(enabled: bool) -> void:
	whole_level_view = enabled
	_update_view_camera()


func _process(_delta: float) -> void:
	_update_view_camera()
	_update_episode_timer()


func _update_episode_timer() -> void:
	if headless_training:
		return
	%EpisodeTimer.visible = control_mode != ControlMode.HUMAN
	%EpisodeTimer.text = "Time  %.1f / %.1f s" % [player.tick / float(_normal_tick_rate), episode_limit_seconds]
	if stuck_detection_enabled and control_mode != ControlMode.HUMAN:
		var remaining := maxf(0.0, STUCK_PATIENCE_SECONDS - (player.tick - _last_progress_tick) / float(_normal_tick_rate))
		%EpisodeTimer.text += "\nPatience  %.1f s left" % remaining


func _update_view_camera() -> void:
	if _view_camera == null:
		return
	var viewport_size := get_viewport_rect().size
	var zoom_factor := minf(1.0, minf(viewport_size.x / world_bounds.size.x, viewport_size.y / world_bounds.size.y)) if whole_level_view else 1.0
	_view_camera.zoom = Vector2.ONE * zoom_factor
	var half_view := viewport_size / (2.0 * zoom_factor)
	var center := world_bounds.get_center()
	if not whole_level_view and world_bounds.size.x > viewport_size.x:
		center.x = clampf(player.global_position.x, world_bounds.position.x + half_view.x, world_bounds.end.x - half_view.x)
	_view_camera.global_position = center
	# Pad camera limits when the view is taller than the course, so the overview
	# remains centered instead of clamping to one edge of the level.
	var course_center := world_bounds.get_center()
	_view_camera.limit_left = floori(minf(world_bounds.position.x, course_center.x - half_view.x))
	_view_camera.limit_right = ceili(maxf(world_bounds.end.x, course_center.x + half_view.x))
	_view_camera.limit_top = floori(minf(world_bounds.position.y, course_center.y - half_view.y))
	_view_camera.limit_bottom = ceili(maxf(world_bounds.end.y, course_center.y + half_view.y))


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
	if control_mode == ControlMode.HUMAN or headless_training:
		return
	var speed: float = TRAINING_SPEEDS[index]
	# Scale both so each physics step still advances 1/60 of a game second.
	Engine.physics_ticks_per_second = maxi(1, roundi(_normal_tick_rate * speed))
	Engine.max_physics_steps_per_frame = maxi(1, ceili(_normal_max_steps * speed))
	Engine.time_scale = _normal_time_scale * speed
	%SpeedSelect.select(index)


func _exit_tree() -> void:
	if episode_recorder != null:
		episode_recorder.close()
	if control_mode != ControlMode.HUMAN:
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
	_set_training_speed(NORMAL_SPEED_INDEX)
	%SpeedSelect.disabled = true
	if control_mode == ControlMode.Q_LEARNING:
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
	if heat_map != null:
		heat_map.sample(0, player.position)
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
	stuck_count = 0
	agent.training = not agent.training
	if path_trails != null:
		path_trails.clear()
	if heat_map != null:
		heat_map.clear()
	# A mode change starts another batch using the same selected data.
	if run_limit > 0:
		autosave_training = agent.training
	agent.exploring = false
	if not agent.training:
		_set_training_speed(NORMAL_SPEED_INDEX)
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
		%SpeedSelect.disabled = session_finished
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
	var distance := player.global_position.distance_to(orb.global_position)
	var proximity := _orb_proximity(distance)
	var progress_reward := 0.1 * (proximity - _previous_proximity)
	if control_mode == ControlMode.Q_LEARNING and agent.preset_id == "fixed_reward_per_block":
		progress_reward = QLearningAgent.Presets.FIXED_REWARD_PER_BLOCK * (_previous_orb_distance - distance) / player.UNIT
		_previous_orb_distance = distance
	# Spread the time cost across physics ticks, including partial decisions.
	# Terminal rewards below remain exactly +1 / -1.
	reward = progress_reward - time_penalty_per_decision / TICKS_PER_DECISION
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
	elif stuck_detection_enabled and control_mode != ControlMode.HUMAN:
		# Anchor to the last full block of best progress, so small advances add up
		# and revisiting old positions never refreshes patience.
		if distance <= _progress_checkpoint_distance - player.UNIT:
			_progress_checkpoint_distance = distance
			_last_progress_tick = player.tick
		if player.tick - _last_progress_tick >= roundi(STUCK_PATIENCE_SECONDS * _normal_tick_rate):
			done = true
			stuck = true
			reward = -1.0
			stuck_count += 1
			_update_stats()


func reset_episode() -> Dictionary:
	player.reset_to(spawn.global_position)
	orb.show()
	done = false
	reward = 0.0
	orb_collected = false
	timed_out = false
	stuck = false
	_last_progress_tick = 0
	episode_return = 0.0
	_decision_state = {}
	_decision_reward = 0.0
	_held_action_id = Action.DO_NOTHING
	_previous_proximity = _orb_proximity()
	_previous_orb_distance = player.global_position.distance_to(orb.global_position)
	_progress_checkpoint_distance = _previous_orb_distance
	_begin_capture()
	_update_episode_timer()
	return get_state()


func _setup_capture() -> void:
	if control_mode == ControlMode.HUMAN:
		return
	if not headless_training:
		heat_map = PathHeatMap.new()
		heat_map.bounds = world_bounds
		add_child(heat_map)
		%HeatMapControls.bind_heat_map(heat_map)
	if show_path_trails and not headless_training:
		path_trails = PathTrails.new()
		path_trails.z_index = 1
		add_child(path_trails)
	if record_every > 0:
		episode_recorder = EpisodeRecorder.new()
		if recording_path.is_empty():
			recording_path = EpisodeRecorder.new_path()
		var fingerprints := {}
		for source in [scene_file_path, "res://Game/Level.gd", "res://Game/Player.gd", "res://Agents/QLearningAgent.gd", "res://Agents/QState.gd", "res://Agents/QPresets.gd"]:
			fingerprints[source] = FileAccess.get_sha256(source)
		if scene_file_path != "res://Game/Level.tscn":
			fingerprints["res://Game/Levels/CourseBase.tscn"] = FileAccess.get_sha256("res://Game/Levels/CourseBase.tscn")
		var metadata := {"physics_hz": _normal_tick_rate, "ticks_per_decision": TICKS_PER_DECISION,
			"record_every": record_every, "episode_offset": recording_episode_offset,
			"controller": ControlMode.keys()[control_mode], "engine": Engine.get_version_info().string,
			"source_sha256": fingerprints, "checkpoint": checkpoint_path, "level_scene": scene_file_path,
			"stuck_detection": stuck_detection_enabled, "stuck_patience_seconds": STUCK_PATIENCE_SECONDS,
			"stuck_progress_blocks": 1.0}
		if control_mode == ControlMode.Q_LEARNING:
			metadata.preset_id = agent.preset_id
			metadata.starting_training_episodes = agent.training_episodes
		if not episode_recorder.open(recording_path, metadata):
			recording_error = episode_recorder.error
			session_finished = true
	_begin_capture()


func _begin_capture() -> void:
	_record_this_episode = false
	if heat_map != null:
		heat_map.begin_episode(0, player.position)
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
	var outcome := "success" if orb_collected else ("stuck" if stuck else ("timeout" if timed_out else "death"))
	if _record_this_episode:
		if not episode_recorder.finish_episode(outcome, episode_return):
			recording_error = episode_recorder.error
		_record_this_episode = false
	if path_trails != null:
		path_trails.finish_episode(outcome)
	if heat_map != null:
		heat_map.finish_episode(0)
	_update_recording_status()


func _update_recording_status() -> void:
	if headless_training:
		return
	%RecordingStatus.visible = record_every > 0 or path_trails != null
	var text := "Trails · last 50 attempts" if path_trails != null else ""
	if record_every > 0:
		text += ("\n" if not text.is_empty() else "") + ("Recording error: " + recording_error if not recording_error.is_empty() else "Recording every %d · %d saved" % [record_every, episode_recorder.recorded_episodes])
	%RecordingStatus.text = text
	%RecordingStatus.tooltip_text = ProjectSettings.globalize_path(recording_path) if record_every > 0 else "Green: success · Red: death · Amber: timeout · Purple: stuck. Older paths fade each episode."


func get_state(ray_indices: Array = [0, 1, 2, 3, 4, 5, 6, 7]) -> Dictionary:
	var state: Dictionary = player.get_state(ray_indices)
	state["action_id"] = _held_action_id
	state["decision_required"] = _decision_required()
	state["done"] = done
	state["reward"] = reward
	state["orb_collected"] = orb_collected
	state["timed_out"] = timed_out
	state["stuck"] = stuck
	state["orb_offset"] = (orb.global_position - player.global_position) / player.UNIT
	state["orb_proximity"] = _orb_proximity()
	return state


func get_state_string() -> String:
	var state := get_state()
	return player.get_state_string() + "\naction_id: %s\ndecision_required: %s\ndone: %s\nreward: %s\norb_collected: %s\norb_proximity: %s" % [state.action_id, state.decision_required, done, reward, orb_collected, _orb_proximity()]


func _orb_proximity(distance: float = -1.0) -> float:
	if distance < 0.0:
		distance = player.global_position.distance_to(orb.global_position)
	var start_distance := maxf(spawn.global_position.distance_to(orb.global_position), 1.0)
	return clampf(1.0 - distance / start_distance, 0.0, 1.0)


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
	_update_episode_timer()
	var total := deaths + orb_collections + timeouts + stuck_count
	var success := "—" if total == 0 else "%.0f%%" % (100.0 * orb_collections / total)
	%StatsLabel.text = "Success  %s  ·  Wins  %d\nDeaths  %d  ·  Timeouts  %d" % [success, orb_collections, deaths, timeouts]
	if stuck_detection_enabled or stuck_count > 0:
		%StatsLabel.text += "\nStuck  %d" % stuck_count
	if control_mode == ControlMode.HUMAN:
		%RunLabel.text = "Free play"
	else:
		var count := "%d / %d" % [session_runs, run_limit] if run_limit > 0 else str(total)
		%RunLabel.text = ("Finished · " if session_finished else "Runs  ") + count
