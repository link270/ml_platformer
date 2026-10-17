extends Control

const LEVEL_SCENE := preload("res://Game/Level.tscn")
const Level := preload("res://Game/Level.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const CHECKPOINT_DIRECTORY := "user://checkpoints"
# These can be overridden by tests without touching the player's saved data.
var checkpoint_directory := CHECKPOINT_DIRECTORY
var checkpoint_path := Checkpoint.DEFAULT_PATH
var _check_in_level: Node2D
var _busy := false


func _ready() -> void:
	%ControllerSelect.add_item("Human playable", Level.ControlMode.HUMAN)
	%ControllerSelect.add_item("Random agent", Level.ControlMode.RANDOM)
	%ControllerSelect.add_item("Q-learning", Level.ControlMode.Q_LEARNING)
	%ControllerSelect.select(Level.ControlMode.Q_LEARNING)
	%ModeSelect.add_item("Training", 0)
	%ModeSelect.add_item("Evaluation", 1)
	%ControllerSelect.item_selected.connect(_controller_changed)
	%ModeSelect.item_selected.connect(_refresh_form.unbind(1))
	%DataSelect.item_selected.connect(_refresh_form.unbind(1))
	%HeadlessToggle.toggled.connect(_refresh_form.unbind(1))
	%RefreshData.pressed.connect(_refresh_data)
	%OpenFolder.pressed.connect(_open_data_folder)
	%BatchStart.pressed.connect(_start_selected)
	%SessionInfo.busy_changed.connect(_set_training_busy)
	%SessionInfo.check_in_requested.connect(_show_check_in)
	_refresh_data(checkpoint_path)
	%ControllerSelect.grab_focus()


func _refresh_data(preferred: String = "") -> void:
	if _busy:
		return
	if preferred.is_empty() and %DataSelect.item_count > 0:
		preferred = str(%DataSelect.get_selected_metadata())
	%DataSelect.clear()
	%DataSelect.add_item("New training data")
	%DataSelect.set_item_metadata(0, "")
	var paths: Array[String] = []
	for filename in DirAccess.get_files_at(checkpoint_directory) if DirAccess.dir_exists_absolute(checkpoint_directory) else PackedStringArray():
		if filename.get_extension().to_lower() == "json":
			paths.append(checkpoint_directory.path_join(filename))
	# Keep the original single-save checkpoint available without moving it.
	if FileAccess.file_exists(checkpoint_path) and not paths.has(checkpoint_path):
		paths.append(checkpoint_path)
	paths.sort()
	for path in paths:
		var label := "Original saved data" if path == Checkpoint.DEFAULT_PATH else path.get_file().get_basename().replace("_", " ")
		%DataSelect.add_item(label)
		var index: int = %DataSelect.item_count - 1
		%DataSelect.set_item_metadata(index, path)
		if path == preferred:
			%DataSelect.select(index)
	_refresh_form()


func _controller_changed(_index: int) -> void:
	if %ControllerSelect.get_selected_id() != Level.ControlMode.Q_LEARNING:
		%ModeSelect.select(1)
	else:
		%ModeSelect.select(0)
	_refresh_form()


func _refresh_form() -> void:
	var controller: int = %ControllerSelect.get_selected_id()
	var human := controller == Level.ControlMode.HUMAN
	var learning := controller == Level.ControlMode.Q_LEARNING
	var evaluating: bool = %ModeSelect.selected == 1
	var selected_path := str(%DataSelect.get_selected_metadata())
	%ControllerSelect.disabled = _busy
	%ModeRow.visible = not human
	%ModeSelect.disabled = _busy or not learning
	%DataRow.visible = learning
	%DataSelect.disabled = _busy
	%RefreshData.disabled = _busy
	%OpenFolder.disabled = _busy
	%RunsRow.visible = not human
	%BatchEpisodes.editable = not _busy
	%HeadlessToggle.visible = not human
	%HeadlessToggle.disabled = _busy
	%CheckInRow.visible = not human and learning and not evaluating and %HeadlessToggle.button_pressed
	%BatchCheckEvery.editable = not _busy
	%BatchStart.disabled = _busy or (learning and evaluating and selected_path.is_empty())
	%BatchStart.text = "Play" if human else ("Start evaluation" if evaluating else "Start training")
	%BatchStop.visible = _busy
	%BatchProgress.visible = _busy or %BatchProgress.value > 0
	%BatchStop.text = "Stop & save" if learning and not evaluating else "Stop"
	if _busy:
		return
	if human:
		%CheckpointInfo.text = "A / D or arrows to move. Space to jump."
	elif not learning:
		%CheckpointInfo.text = "Random actions. No learning or saved data."
	elif evaluating:
		%CheckpointInfo.text = "Choose saved data to evaluate." if selected_path.is_empty() else "Watch the learned policy. Saved data stays unchanged."
	elif selected_path.is_empty():
		%CheckpointInfo.text = "Starts fresh. Saves to a new file automatically."
	else:
		%CheckpointInfo.text = "Continues learning and updates the selected file."
	%DataSelect.tooltip_text = ProjectSettings.globalize_path(selected_path if not selected_path.is_empty() else checkpoint_directory)


func _set_training_busy(busy: bool) -> void:
	_busy = busy
	if not busy:
		_refresh_data(checkpoint_path)
	_refresh_form()


func _open_data_folder() -> void:
	var error := DirAccess.make_dir_recursive_absolute(checkpoint_directory)
	if error != OK:
		%CheckpointInfo.text = "Cannot create data folder: " + error_string(error)
		return
	OS.shell_open(ProjectSettings.globalize_path(checkpoint_directory))


func _new_checkpoint_path() -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var base := checkpoint_directory.path_join("q-learning_" + stamp)
	var path := base + ".json"
	var suffix := 2
	while FileAccess.file_exists(path):
		path = "%s_%d.json" % [base, suffix]
		suffix += 1
	return path


func _start_selected() -> void:
	if _busy or %BatchStart.disabled:
		return
	var controller: int = %ControllerSelect.get_selected_id()
	var evaluating: bool = %ModeSelect.selected == 1
	var saved_agent: RefCounted
	var selected_path := str(%DataSelect.get_selected_metadata())
	if controller == Level.ControlMode.Q_LEARNING:
		saved_agent = Level.QLearningAgent.new()
		if not selected_path.is_empty():
			var error := Checkpoint.load_checkpoint(saved_agent, selected_path)
			if not error.is_empty():
				%CheckpointInfo.text = error
				return
		else:
			var error := DirAccess.make_dir_recursive_absolute(checkpoint_directory)
			if error != OK:
				%CheckpointInfo.text = "Cannot create data folder: " + error_string(error)
				return
			selected_path = _new_checkpoint_path()
		saved_agent.training = not evaluating
		checkpoint_path = selected_path
	%BatchStatus.text = ""
	if controller != Level.ControlMode.HUMAN and %HeadlessToggle.button_pressed:
		%SessionInfo.start_run(controller, evaluating, selected_path, FileAccess.file_exists(selected_path))
		return
	var level := LEVEL_SCENE.instantiate()
	level.control_mode = controller
	level.agent = saved_agent
	level.checkpoint_path = checkpoint_path
	level.run_limit = 0 if controller == Level.ControlMode.HUMAN else int(%BatchEpisodes.value)
	level.autosave_training = controller == Level.ControlMode.Q_LEARNING and not evaluating
	level.checkpoint_status = "Saves automatically." if level.autosave_training else "Evaluation leaves saved data unchanged."
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
	_check_in_level.get_node("%ModeLabel").text = "Check-in · %d / %d trained" % [completed, total]
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
