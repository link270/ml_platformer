extends Node

signal busy_changed(busy: bool)
signal check_in_requested(completed: int, total: int)

var checkpoint_path := ""
var load_path := ""
var preset_id := "long_exploration"
var session_directory := OS.get_user_data_dir()
var process_id := -1
var status_path := ""
var latest_status: Dictionary = {}
var active := false
var completed_episodes := 0
var completed_wins := 0
var total_episodes := 0
var check_in_every := 0
var stopping := false
var controller := 2
var evaluating := false
var _exit_polls := 0


func _ready() -> void:
	%BatchStop.pressed.connect(_stop)
	%BatchPoll.timeout.connect(_poll)


func start_run(selected_controller: int, evaluation: bool, path: String, resume: bool, experiment: String = "long_exploration", source: String = "") -> void:
	if active:
		return
	preset_id = experiment
	load_path = ProjectSettings.globalize_path(source) if not source.is_empty() else ProjectSettings.globalize_path(path)
	controller = selected_controller
	evaluating = evaluation
	checkpoint_path = ProjectSettings.globalize_path(path) if not path.is_empty() else ""
	active = true
	stopping = false
	completed_episodes = 0
	completed_wins = 0
	total_episodes = int(%BatchEpisodes.value)
	check_in_every = int(%BatchCheckEvery.value) if controller == 2 and not evaluating else 0
	%BatchProgress.max_value = total_episodes
	%BatchProgress.value = 0
	%BatchStop.disabled = false
	busy_changed.emit(true)
	_launch_worker(resume)


func _launch_worker(resume: bool) -> void:
	var remaining := total_episodes - completed_episodes
	var count := mini(check_in_every, remaining) if check_in_every > 0 else remaining
	status_path = session_directory.path_join("headless-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_usec()])
	latest_status = {}
	_exit_polls = 0
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--fixed-fps", "60", "--disable-render-loop", "--log-file", status_path + ".log",
		"--script", "res://Training/train.gd", "--", "--episodes", str(count),
		"--agent", "random" if controller == 1 else "q-learning",
		"--mode", "evaluation" if evaluating else "training", "--status", status_path,
	])
	if controller == 2:
		args.append_array(["--save", checkpoint_path, "--preset", preset_id])
		if resume:
			args.append_array(["--load", load_path if completed_episodes == 0 else checkpoint_path])
	process_id = OS.create_process(OS.get_executable_path(), args)
	if process_id <= 0:
		_finish("Could not start the worker.")
		return
	%BatchStatus.text = "Starting · %d / %d runs" % [completed_episodes, total_episodes]
	%BatchPoll.start()


func _stop(update_ui: bool = true) -> void:
	if process_id <= 0:
		return
	var file := FileAccess.open(status_path + ".stop", FileAccess.WRITE)
	if file == null:
		if update_ui:
			%BatchStatus.text = "Could not stop the worker. Try again."
		return
	file.close()
	stopping = true
	if update_ui:
		%BatchStop.disabled = true
		%BatchStatus.text = "Finishing this run…"


func _read_status() -> void:
	# A Windows rename can briefly make the file unavailable. Keep the last valid snapshot.
	var file := FileAccess.open(status_path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	var text := file.get_as_text()
	file.close()
	if json.parse(text) == OK and json.data is Dictionary:
		latest_status = json.data


func _poll() -> void:
	var running := OS.is_process_running(process_id)
	_read_status()
	if not latest_status.is_empty():
		var count: int = completed_episodes + latest_status.completed
		var success := 100.0 * (completed_wins + int(latest_status.get("wins", 0))) / maxi(count, 1)
		%BatchProgress.value = count
		%BatchStatus.text = "%d / %d runs · %.1f runs/s · %.1f%% success" % [count, total_episodes, latest_status.episodes_per_second, success]
	if running:
		return
	# Read again after exit: the final snapshot may have arrived during the poll.
	_read_status()
	if latest_status.get("status", "") not in ["completed", "stopped", "error"] and _exit_polls < 3:
		_exit_polls += 1
		return
	process_id = -1
	%BatchPoll.stop()
	%BatchStatus.tooltip_text = "Log: " + status_path + ".log"
	for suffix in ["", ".tmp", ".stop"]:
		DirAccess.remove_absolute(status_path + suffix)
	match latest_status.get("status", ""):
		"completed", "stopped":
			completed_episodes += int(latest_status.completed)
			completed_wins += int(latest_status.get("wins", 0))
			%BatchProgress.value = completed_episodes
			if stopping or latest_status.status == "stopped":
				_finish("Stopped · %d / %d runs%s" % [completed_episodes, total_episodes, " · Saved" if controller == 2 and not evaluating else ""])
			elif check_in_every > 0 and completed_episodes % check_in_every == 0:
				%BatchStatus.text = "Watching one evaluation run…"
				check_in_requested.emit(completed_episodes, total_episodes)
			else:
				complete_check_in()
		"error": _finish(latest_status.message)
		_: _finish("Worker exited unexpectedly. See log.")


func complete_check_in(cancelled: bool = false, error: String = "") -> void:
	if not active:
		return
	if not error.is_empty():
		_finish(error)
	elif cancelled:
		_finish("Stopped · %d / %d runs · Saved" % [completed_episodes, total_episodes])
	elif completed_episodes == total_episodes:
		_finish("Finished · %d runs · %.1f%% success%s" % [total_episodes, 100.0 * completed_wins / maxi(completed_episodes, 1), " · Saved" if controller == 2 and not evaluating else ""])
	else:
		_launch_worker(true)


func _finish(message: String) -> void:
	active = false
	%BatchStatus.text = message
	%BatchStop.disabled = true
	busy_changed.emit(false)


func _exit_tree() -> void:
	_stop(false)
