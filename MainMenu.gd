extends Control

const LEVEL_SCENE := preload("res://Level.tscn")
const Level := preload("res://Level.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
var checkpoint_path := Checkpoint.DEFAULT_PATH
var _check_in_level: Node2D


func _ready() -> void:
	%HumanButton.pressed.connect(_start_game.bind(Level.ControlMode.HUMAN))
	%RandomButton.pressed.connect(_start_game.bind(Level.ControlMode.RANDOM))
	%QLearningButton.pressed.connect(_start_game.bind(Level.ControlMode.Q_LEARNING))
	%ResumeButton.pressed.connect(_start_saved.bind(false))
	%LoadEvaluationButton.pressed.connect(_start_saved.bind(true))
	%SessionInfo.setup(checkpoint_path)
	%SessionInfo.busy_changed.connect(_set_training_busy)
	%SessionInfo.check_in_requested.connect(_show_check_in)
	_set_training_busy(false)
	%HumanButton.grab_focus()


func _set_training_busy(busy: bool) -> void:
	for button in [%HumanButton, %RandomButton, %QLearningButton]:
		button.disabled = busy
	var has_checkpoint := FileAccess.file_exists(checkpoint_path)
	%ResumeButton.disabled = busy or not has_checkpoint
	%LoadEvaluationButton.disabled = busy or not has_checkpoint
	%CheckpointInfo.text = "Saved checkpoint available." if has_checkpoint else "No saved checkpoint yet."
	%CheckpointInfo.tooltip_text = ProjectSettings.globalize_path(checkpoint_path)


func _start_saved(evaluate: bool) -> void:
	if %SessionInfo.active:
		return
	var saved_agent := Level.QLearningAgent.new()
	var error := Checkpoint.load_checkpoint(saved_agent, checkpoint_path)
	if not error.is_empty():
		%CheckpointInfo.text = error
		return
	saved_agent.training = not evaluate
	_start_game(Level.ControlMode.Q_LEARNING, saved_agent)


func _start_game(mode: int, saved_agent: RefCounted = null) -> void:
	if %SessionInfo.active:
		return
	var level := LEVEL_SCENE.instantiate()
	level.control_mode = mode
	level.agent = saved_agent
	level.checkpoint_path = checkpoint_path
	if saved_agent != null:
		level.checkpoint_status = "Loaded checkpoint."
	get_tree().root.add_child(level)
	get_tree().current_scene = level
	queue_free()


func _show_check_in(completed: int, total: int) -> void:
	var saved_agent := Level.QLearningAgent.new()
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
	_check_in_level.get_node("%ModeLabel").text = "Check-in  |  %d / %d trained  |  Resumes automatically" % [completed, total]
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
