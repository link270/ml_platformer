extends SceneTree

const LevelScene := preload("res://Level.tscn")
const QLearning := preload("res://Agents/QLearningAgent.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const Presets := preload("res://Agents/QPresets.gd")

var episodes := 10_000
var save_every := 100
var save_path := Checkpoint.DEFAULT_PATH
var load_path := ""
var status_path := ""
var agent := QLearning.new()
var starting_episodes := 0
var starting_wins := 0
var started_at := 0
var last_report_at := 0
var preset_id := Presets.DEFAULT_ID


func _initialize() -> void:
	call_deferred("start_training")


func start_training() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--help"):
		print("Usage: ./train.sh [--episodes 10000] [--load PATH] [--save PATH] [--save-every 100]")
		print("Optional --preset: ", ", ".join(Presets.IDS))
		print("Episodes are additional episodes this run. Paths accept user:// or absolute paths.")
		print("Default save: ", ProjectSettings.globalize_path(save_path))
		quit()
		return
	var error := parse_options(args)
	if not error.is_empty():
		fail(error)
		return
	Presets.configure(agent, preset_id)
	if not args.has("--save"):
		save_path = Presets.save_path(preset_id)
	if not load_path.is_empty():
		error = Checkpoint.load_checkpoint(agent, load_path)
		if not error.is_empty():
			fail(error)
			return
	starting_episodes = agent.training_episodes
	starting_wins = agent.training_wins
	var level := LevelScene.instantiate()
	level.control_mode = level.ControlMode.Q_LEARNING
	level.headless_training = true
	level.agent = agent
	level.episode_completed.connect(on_episode_completed)
	started_at = Time.get_ticks_msec()
	last_report_at = started_at
	root.add_child(level)
	current_scene = level
	print("Training %d additional episodes; %d previously trained." % [episodes, starting_episodes])
	print("Checkpoint every %d episodes and at completion: %s" % [save_every, ProjectSettings.globalize_path(save_path)])
	report_progress()


func parse_options(args: PackedStringArray) -> String:
	if args.size() % 2 != 0:
		return "Each option needs a value. Use ./train.sh --help."
	for i in range(0, args.size(), 2):
		var option := args[i]
		var value := args[i + 1]
		match option:
			"--preset":
				if not Presets.PRESETS.has(value):
					return "Unknown experiment preset: " + value
				preset_id = value
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
	return ""


func on_episode_completed() -> void:
	var completed := agent.training_episodes - starting_episodes
	var stop_requested := not status_path.is_empty() and FileAccess.file_exists(status_path + ".stop")
	if completed % save_every == 0 or completed == episodes or stop_requested:
		var error := Checkpoint.save_checkpoint(agent, save_path)
		if not error.is_empty():
			fail(error)
			return
	if completed == episodes or stop_requested:
		report_progress("completed" if completed == episodes else "stopped")
		print("Finished. Final checkpoint saved; ready to evaluate in the game.")
		quit()
	elif Time.get_ticks_msec() - last_report_at >= 2000:
		report_progress()


func report_progress(status: String = "running", message: String = "") -> void:
	last_report_at = Time.get_ticks_msec()
	var completed := agent.training_episodes - starting_episodes
	var elapsed := maxf((last_report_at - started_at) / 1000.0, 0.001)
	var success := 100.0 * (agent.training_wins - starting_wins) / maxi(completed, 1)
	print("%d / %d episodes | %.1f episodes/s | success %.1f%% | exploration %.0f%%" % [completed, episodes, completed / elapsed, success, agent.epsilon * 100.0])
	if status_path.is_empty():
		return
	var data := {"status": status, "message": message, "completed": completed, "target": episodes,
		"episodes_per_second": completed / elapsed, "success": success}
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
		error = DirAccess.rename_absolute(status_path + ".tmp", status_path)
	if error != OK:
		printerr("Cannot update training progress: ", error_string(error))
		quit(1)


func fail(message: String) -> void:
	printerr("Training stopped: ", message)
	report_progress("error", message)
	quit(1)
