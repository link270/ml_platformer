extends SceneTree

const LevelScene := preload("res://Game/Level.tscn")
const QLearning := preload("res://Agents/QLearningAgent.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const Presets := preload("res://Agents/QPresets.gd")

var episodes := 10_000
var save_every := 100
var save_path := Checkpoint.DEFAULT_PATH
var load_path := ""
var status_path := ""
var agent: RefCounted = QLearning.new()
var agent_name := "q-learning"
var run_mode := "training"
var completed_runs := 0
var successful_runs := 0
var starting_episodes := 0
var starting_wins := 0
var started_at := 0
var last_report_at := 0
var preset_id := Presets.DEFAULT_ID
var record_every := 0
var recording_path := ""
var recording_episode_offset := 0


func _initialize() -> void:
	call_deferred("start_training")


func start_training() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--help"):
		print("Usage: ./train.sh [--episodes 10000] [--load PATH] [--save PATH] [--save-every 100]")
		print("Optional --preset: ", ", ".join(Presets.IDS))
		print("Episodes are additional episodes this run. Paths accept user:// or absolute paths.")
		print("Options: --agent q-learning|random --mode training|evaluation")
		print("Recording: --record-every 0 (off), 1 (all), or X; optional --record-to PATH.mlpaths")
		print("--record-offset N preserves session-relative sampling across worker chunks.")
		print("Default save: ", ProjectSettings.globalize_path(save_path))
		quit()
		return
	var error := parse_options(args)
	if not error.is_empty():
		fail(error)
		return
	if agent_name == "random":
		agent = preload("res://Agents/RandomAgent.gd").new()
	else:
		Presets.configure(agent, preset_id)
		agent.training = run_mode == "training"
		if not args.has("--save"):
			save_path = Presets.save_path(preset_id)
	if not load_path.is_empty():
		error = Checkpoint.load_checkpoint(agent, load_path)
		if not error.is_empty():
			fail(error)
			return
	if agent_name == "q-learning":
		starting_episodes = agent.training_episodes
		starting_wins = agent.training_wins
	var level := LevelScene.instantiate()
	level.control_mode = level.ControlMode.RANDOM if agent_name == "random" else level.ControlMode.Q_LEARNING
	level.headless_training = true
	level.agent = agent
	level.record_every = record_every
	level.recording_path = recording_path
	level.recording_episode_offset = recording_episode_offset
	level.checkpoint_path = save_path
	level.episode_completed.connect(on_episode_completed)
	started_at = Time.get_ticks_msec()
	last_report_at = started_at
	root.add_child(level)
	current_scene = level
	if not level.recording_error.is_empty():
		fail(level.recording_error)
		return
	if record_every > 0:
		print("Recording every %d episodes: %s" % [record_every, ProjectSettings.globalize_path(level.recording_path)])
	print("%s: %d runs with %s." % [run_mode.capitalize(), episodes, agent_name])
	if _saves_training():
		print("Checkpoint every %d runs and at completion: %s" % [save_every, ProjectSettings.globalize_path(save_path)])
	report_progress()


func parse_options(args: PackedStringArray) -> String:
	if args.size() % 2 != 0:
		return "Each option needs a value. Use ./train.sh --help."
	for i in range(0, args.size(), 2):
		var option := args[i]
		var value := args[i + 1]
		match option:
			"--record-every", "--record-offset":
				if not value.is_valid_int() or value.to_int() < 0:
					return option + " must be a non-negative integer."
				if option == "--record-every":
					record_every = value.to_int()
				else:
					recording_episode_offset = value.to_int()
			"--record-to":
				if value.is_empty():
					return option + " needs a file path."
				recording_path = value
			"--preset":
				if not Presets.PRESETS.has(value):
					return "Unknown experiment preset: " + value
				preset_id = value
			"--agent":
				if value not in ["q-learning", "random"]:
					return "Unknown agent: " + value
				agent_name = value
			"--mode":
				if value not in ["training", "evaluation"]:
					return "Unknown mode: " + value
				run_mode = value
			"--episodes", "--save-every":
				if not value.is_valid_int() or value.to_int() <= 0:
					return option + " must be a positive integer."
				if option == "--episodes":
					episodes = value.to_int()
				else:
					save_every = value.to_int()
			"--load", "--save", "--status":
				if value.is_empty():
					return option + " needs a file path."
				if option == "--load":
					load_path = value
				elif option == "--status":
					status_path = value
				else:
					save_path = value
			_:
				return "Unknown option: " + option
	if agent_name == "random" and (run_mode != "evaluation" or not load_path.is_empty()):
		return "Random agents support evaluation without training data."
	if run_mode == "evaluation" and agent_name == "q-learning" and load_path.is_empty():
		return "Choose saved data for Q-learning evaluation."
	if not recording_path.is_empty() and record_every == 0:
		return "--record-to requires --record-every greater than zero."
	return ""


func _saves_training() -> bool:
	return agent_name == "q-learning" and run_mode == "training"


func on_episode_completed() -> void:
	if not current_scene.recording_error.is_empty():
		fail(current_scene.recording_error)
		return
	completed_runs += 1
	successful_runs += int(current_scene.orb_collected)
	var completed := completed_runs
	var stop_requested := not status_path.is_empty() and FileAccess.file_exists(status_path + ".stop")
	if _saves_training() and (completed % save_every == 0 or completed == episodes or stop_requested):
		var error := Checkpoint.save_checkpoint(agent, save_path)
		if not error.is_empty():
			fail(error)
			return
	if completed == episodes or stop_requested:
		if current_scene.episode_recorder != null:
			current_scene.episode_recorder.close()
		report_progress("completed" if completed == episodes else "stopped")
		print("Finished. Checkpoint saved." if _saves_training() else "Finished evaluation. Saved data unchanged.")
		quit()
	elif Time.get_ticks_msec() - last_report_at >= 2000:
		report_progress()


func report_progress(status: String = "running", message: String = "") -> void:
	last_report_at = Time.get_ticks_msec()
	var completed := completed_runs
	var elapsed := maxf((last_report_at - started_at) / 1000.0, 0.001)
	var success := 100.0 * successful_runs / maxi(completed, 1)
	print("%d / %d runs | %.1f runs/s | success %.1f%%" % [completed, episodes, completed / elapsed, success])
	if status_path.is_empty():
		return
	var data := {"status": status, "message": message, "completed": completed, "target": episodes,
		"episodes_per_second": completed / elapsed, "success": success, "wins": successful_runs}
	if is_instance_valid(current_scene) and current_scene.get("episode_recorder") != null:
		data.recording_path = current_scene.recording_path
		data.recorded_episodes = current_scene.episode_recorder.recorded_episodes
		data.recording_bytes = current_scene.episode_recorder.bytes_written
	# Replace a complete snapshot so the menu never reads half-written JSON.
	var file := FileAccess.open(status_path + ".tmp", FileAccess.WRITE)
	if file == null:
		printerr("Cannot write training progress: ", error_string(FileAccess.get_open_error()))
		quit(1)
		return
	file.store_string(JSON.stringify(data))
	file.flush()
	var error := file.get_error()
	file.close()
	if error == OK:
		# A Windows reader can briefly hold the destination open during polling.
		for attempt in 20:
			error = DirAccess.rename_absolute(status_path + ".tmp", status_path)
			if error == OK:
				break
			OS.delay_msec(5)
	if error != OK:
		printerr("Cannot update training progress: ", error_string(error))
		quit(1)


func fail(message: String) -> void:
	printerr("Training stopped: ", message)
	report_progress("error", message)
	quit(1)
