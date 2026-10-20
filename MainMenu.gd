extends Control

const LEVEL_SCENE := preload("res://Level.tscn")
const Level := preload("res://Level.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const Presets := preload("res://Agents/QPresets.gd")
# Remember the filming selection when returning from the level.
static var last_preset := Presets.DEFAULT_ID
static var last_checkpoint := 0
var preset_id := Presets.DEFAULT_ID
var checkpoint_path := Checkpoint.DEFAULT_PATH
var _check_in_level: Node2D
var _was_training := false


func _ready() -> void:
	%HumanButton.pressed.connect(_start_game.bind(Level.ControlMode.HUMAN))
	%RandomButton.pressed.connect(_start_game.bind(Level.ControlMode.RANDOM))
	%QLearningButton.pressed.connect(_start_game.bind(Level.ControlMode.Q_LEARNING))
	%ResumeButton.pressed.connect(_start_saved.bind(false))
	%LoadEvaluationButton.pressed.connect(_start_saved.bind(true))
	%SessionInfo.busy_changed.connect(_set_training_busy)
	%SessionInfo.check_in_requested.connect(_show_check_in)
	for id in Presets.IDS:
		%ExperimentSelect.add_item(Presets.PRESETS[id].label)
	if checkpoint_path == Checkpoint.DEFAULT_PATH:
		preset_id = last_preset
		checkpoint_path = Presets.save_path(preset_id)
	%ExperimentSelect.select(Presets.IDS.find(preset_id))
	%ExperimentSelect.item_selected.connect(_select_experiment)
	%CheckpointSelect.item_selected.connect(_select_checkpoint)
	_populate_checkpoints(last_checkpoint)
	_set_training_busy(false)
	%HumanButton.grab_focus()


func _select_experiment(index: int) -> void:
	preset_id = Presets.IDS[index]
	last_preset = preset_id
	checkpoint_path = Presets.save_path(preset_id)
	# If there is no personal save yet, offer the final archived table.
	_populate_checkpoints(0 if FileAccess.file_exists(checkpoint_path) else 1)
	_set_training_busy(false)


func _populate_checkpoints(selected: int) -> void:
	%ExperimentDescription.text = Presets.PRESETS[preset_id].description
	%CheckpointSelect.clear()
	%CheckpointSelect.add_item("My saved session")
	%CheckpointSelect.set_item_metadata(0, {"path": checkpoint_path, "seed": -1})
	for seed_value in Presets.SEEDS:
		for episodes in Presets.MILESTONES:
			var path := Presets.archive_path(preset_id, seed_value, episodes)
			if not FileAccess.file_exists(path):
				continue
			var index: int = %CheckpointSelect.item_count
			%CheckpointSelect.add_item("Archive · seed %d · %d episodes" % [seed_value, episodes])
			%CheckpointSelect.set_item_metadata(index, {"path": path, "seed": seed_value})
	%CheckpointSelect.select(clampi(selected, 0, %CheckpointSelect.item_count - 1))
	_select_checkpoint(%CheckpointSelect.selected)


func _load_path() -> String:
	return %CheckpointSelect.get_selected_metadata().path


func _select_checkpoint(index: int) -> void:
	last_checkpoint = index
	%SessionInfo.setup(checkpoint_path, preset_id, _load_path())
	_set_training_busy(false)


func _new_agent() -> RefCounted:
	var learner := Level.QLearningAgent.new()
	Presets.configure(learner, preset_id)
	return learner


func _set_training_busy(busy: bool) -> void:
	if _was_training and not busy:
		# A completed batch has a new personal save; evaluate that next.
		%CheckpointSelect.select(0)
		last_checkpoint = 0
		%SessionInfo.setup(checkpoint_path, preset_id)
	_was_training = busy
	for button in [%HumanButton, %RandomButton, %QLearningButton]:
		button.disabled = busy
	%ExperimentSelect.disabled = busy
	%CheckpointSelect.disabled = busy
	var has_checkpoint := FileAccess.file_exists(_load_path())
	%ResumeButton.disabled = busy or not has_checkpoint
	%LoadEvaluationButton.disabled = busy or not has_checkpoint
	%CheckpointInfo.text = "Selected table ready. Saves go to this mode’s session." if has_checkpoint else "No session save yet. Choose an archive or train."
	%CheckpointInfo.tooltip_text = "Load: %s\nSave: %s" % [ProjectSettings.globalize_path(_load_path()), ProjectSettings.globalize_path(checkpoint_path)]


func _start_saved(evaluate: bool) -> void:
	if %SessionInfo.active:
		return
	var saved_agent := _new_agent()
	var error := Checkpoint.load_checkpoint(saved_agent, _load_path())
	if not error.is_empty():
		%CheckpointInfo.text = error
		return
	saved_agent.training = not evaluate
	var seed_value: int = %CheckpointSelect.get_selected_metadata().seed
	if evaluate and seed_value >= 0:
		# Match the saved diagnostic evaluations, including random tie breaks.
		saved_agent.rng.seed = seed_value + 1_000_000
	_start_game(Level.ControlMode.Q_LEARNING, saved_agent)


func _start_game(mode: int, saved_agent: RefCounted = null) -> void:
	if %SessionInfo.active:
		return
	var level := LEVEL_SCENE.instantiate()
	level.control_mode = mode
	level.agent = saved_agent
	if mode == Level.ControlMode.Q_LEARNING and saved_agent == null:
		level.agent = _new_agent()
	level.checkpoint_path = checkpoint_path
	if saved_agent != null:
		level.checkpoint_status = %CheckpointSelect.get_item_text(%CheckpointSelect.selected)
	get_tree().root.add_child(level)
	get_tree().current_scene = level
	queue_free()


func _show_check_in(completed: int, total: int) -> void:
	var saved_agent := _new_agent()
	var error := Checkpoint.load_checkpoint(saved_agent, checkpoint_path)
	if not error.is_empty():
		%SessionInfo.complete_check_in(false, error)
		return
	saved_agent.training = false
	_check_in_level = LEVEL_SCENE.instantiate()
	_check_in_level.control_mode = Level.ControlMode.Q_LEARNING
	_check_in_level.agent = saved_agent
	_check_in_level.check_in_mode = true
	_check_in_level.episode_completed.connect(_finish_check_in.bind(false))
	_check_in_level.check_in_cancelled.connect(_finish_check_in.bind(true))
	get_tree().root.add_child(_check_in_level)
	_check_in_level.get_node("%ModeLabel").text = "%s  |  Check-in %d / %d" % [Presets.PRESETS[preset_id].label, completed, total]
	hide()


func _finish_check_in(cancelled: bool) -> void:
	if not is_instance_valid(_check_in_level):
		return
	_check_in_level.set_physics_process(false)
	_check_in_level.queue_free()
	_check_in_level = null
	show()
	%SessionInfo.complete_check_in(cancelled)


func _exit_tree() -> void:
	if is_instance_valid(_check_in_level):
		_check_in_level.queue_free()
