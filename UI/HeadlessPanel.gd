extends VBoxContainer

signal busy_changed(busy: bool)
signal check_in_requested(completed: int, total: int)

var checkpoint_path := ""
var session_directory := OS.get_user_data_dir()
var process_id := -1
var status_path := ""
var latest_status: Dictionary = {}
var active := false
var completed_episodes := 0
var total_episodes := 0
var check_in_every := 0
var stopping := false


func _ready() -> void:
	%BatchStart.pressed.connect(_start)
	%BatchStop.pressed.connect(_stop)
	%BatchPoll.timeout.connect(_poll)


func setup(path: String) -> void:
	checkpoint_path = ProjectSettings.globalize_path(path)
	%BatchResume.disabled = not FileAccess.file_exists(checkpoint_path)
	%BatchResume.button_pressed = not %BatchResume.disabled


func _start() -> void:
	if active:
		return
	active = true
	stopping = false
	completed_episodes = 0
	total_episodes = int(%BatchEpisodes.value)
	check_in_every = int(%BatchCheckEvery.value)
	%BatchProgress.max_value = total_episodes
	%BatchProgress.value = 0
	%BatchStart.disabled = true
	%BatchEpisodes.editable = false
	%BatchCheckEvery.editable = false
	%BatchStop.disabled = false
	busy_changed.emit(true)
	var resume: bool = %BatchResume.button_pressed
	%BatchResume.disabled = true
	_launch_worker(resume)


func _launch_worker(resume: bool) -> void:
	var remaining := total_episodes - completed_episodes
	var count := mini(check_in_every, remaining) if check_in_every > 0 else remaining
	status_path = session_directory.path_join("headless-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_usec()])
	latest_status = {}
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--fixed-fps", "60", "--disable-render-loop", "--log-file", status_path + ".log",
		"--script", "res://Training/train.gd", "--", "--episodes", str(count),
		"--save", checkpoint_path, "--status", status_path,
	])
	if resume:
		args.append_array(["--load", checkpoint_path])
	process_id = OS.create_process(OS.get_executable_path(), args)
	if process_id <= 0:
		_finish("Could not start training.")
		return
	%BatchStatus.text = "%d / %d episodes\nStarting training…" % [completed_episodes, total_episodes]
	%BatchPoll.start()


func _stop(update_ui: bool = true) -> void:
	if process_id <= 0:
		return
	var file := FileAccess.open(status_path + ".stop", FileAccess.WRITE)
	if file == null:
		if update_ui:
			%BatchStatus.text = "Could not request stop. Training continues."
		return
	file.close()
	stopping = true
	if update_ui:
		%BatchStop.disabled = true
		%BatchStatus.text = "Finishing episode and saving…"


func _poll() -> void:
	var running := OS.is_process_running(process_id)
	if FileAccess.file_exists(status_path):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(status_path))
		if data is Dictionary:
			latest_status = data
			%BatchProgress.value = completed_episodes + data.completed
			%BatchStatus.text = "%d / %d episodes\n%.1f episodes/s · %.1f%% segment success" % [completed_episodes + data.completed, total_episodes, data.episodes_per_second, data.success]
	if running:
		return
	process_id = -1
	%BatchPoll.stop()
	%BatchStatus.tooltip_text = "Log: " + status_path + ".log"
	for suffix in ["", ".tmp", ".stop"]:
		DirAccess.remove_absolute(status_path + suffix)
	match latest_status.get("status", ""):
		"completed", "stopped":
			completed_episodes += int(latest_status.completed)
			if stopping or latest_status.status == "stopped":
				_finish("Stopped at %d / %d. Saved." % [completed_episodes, total_episodes])
			elif check_in_every > 0 and completed_episodes % check_in_every == 0:
				%BatchStatus.text = "Showing one evaluation episode…"
				check_in_requested.emit(completed_episodes, total_episodes)
			else:
				complete_check_in()
		"error": _finish(latest_status.message)
		_: _finish("Training exited unexpectedly. See log.")


func complete_check_in(cancelled: bool = false, error: String = "") -> void:
	if not active:
		return
	if not error.is_empty():
		_finish(error)
	elif cancelled:
		_finish("Stopped at %d / %d. Saved." % [completed_episodes, total_episodes])
	elif completed_episodes == total_episodes:
		_finish("%d / %d episodes\nSaved. Ready to evaluate." % [completed_episodes, total_episodes])
	else:
		_launch_worker(true)


func _finish(message: String) -> void:
	active = false
	%BatchStatus.text = message
	%BatchStart.disabled = false
	%BatchEpisodes.editable = true
	%BatchCheckEvery.editable = true
	%BatchStop.disabled = true
	setup(checkpoint_path)
	busy_changed.emit(false)


func _exit_tree() -> void:
	# Closing the menu requests a saved stop rather than orphaning the worker.
	_stop(false)
