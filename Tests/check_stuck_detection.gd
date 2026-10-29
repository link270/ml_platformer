extends SceneTree

const Course := preload("res://Game/Levels/LargeTemplate.tscn")
const QLearning := preload("res://Agents/QLearningAgent.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const Recording := preload("res://Training/EpisodeRecording.gd")
const DT := 1.0 / 60.0
var failed := false
var scratch: DirAccess

class IdleAgent extends "res://Agents/QLearningAgent.gd":
	func choose_action(_state: Dictionary) -> int:
		return Action.DO_NOTHING


func _initialize() -> void:
	call_deferred("run_check")


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func make_level(enabled: bool, headless: bool = false) -> Node2D:
	var level := Course.instantiate()
	level.control_mode = level.ControlMode.Q_LEARNING
	level.stuck_detection_enabled = enabled
	level.headless_training = headless
	level.agent = IdleAgent.new()
	root.add_child(level)
	level.set_physics_process(false)
	return level


func advance(level: Node2D, ticks: int, action: int = 0) -> void:
	for tick in ticks:
		await physics_frame
		level.step(DT, action)


func check_deadline(speed: float, headless: bool) -> void:
	var level := make_level(true, headless)
	if not headless:
		level._set_training_speed(level.TRAINING_SPEEDS.find(speed))
	await physics_frame
	await physics_frame
	check(is_equal_approx(root.get_physics_process_delta_time(), DT), "viewing speed preserves simulated time")
	for tick in 480:
		await physics_frame
		level._physics_process(DT)
		if tick < 479:
			check(not level.done, "stationary agent retains the full eight seconds")
	check(level.stuck and level.done and level.player.tick == 480 and level.stuck_count == 1, "stationary agent stops exactly at eight simulation seconds")
	check(level.reward == -1.0 and level.deaths == 0 and level.timeouts == 0, "stuck uses one ordinary failure reward and separate counters")
	check(level.agent.training_episodes == 1 and level.agent.updates == 80, "stuck completes one episode with normal six-tick learning")
	if not headless:
		check(level.get_node("%StatsLabel").text.contains("Stuck  1"), "HUD reports the separate stuck count")
	level.step(DT, 0)
	check(level.stuck_count == 1, "repeated terminal steps cannot count stuck twice")
	var table: Dictionary = level.agent.q_table.duplicate(true)
	level.reset_episode()
	check(not level.stuck and not level.done and level.stuck_count == 1 and level.agent.q_table == table, "reset clears patience and outcome while retaining counts and learned data")
	await advance(level, 479)
	check(not level.done, "reset grants another full patience window")
	await advance(level, 1)
	check(level.stuck and level.stuck_count == 2, "new attempt counts stuck once again")
	level.queue_free()
	await process_frame


func check_progress() -> void:
	var level := make_level(true)
	await advance(level, 450)
	await advance(level, 12, level.Action.MOVE_RIGHT)
	var refreshed: int = level._last_progress_tick
	check(refreshed > 450, "small forward steps accumulate a block of meaningful progress")
	await advance(level, 12, level.Action.MOVE_LEFT)
	while level.player.tick < refreshed + 480:
		var action: int = level.Action.MOVE_RIGHT if int(level.player.tick / 6) % 2 == 0 else level.Action.MOVE_LEFT
		await advance(level, 1, action)
	check(level.stuck and level.player.tick == refreshed + 480 and level._last_progress_tick == refreshed, "back-and-forth movement through old positions does not refresh patience")
	level.reset_episode()
	await advance(level, 480, level.Action.JUMP)
	check(level.stuck and level._last_progress_tick == 0, "jumping in place cannot prolong a distant-goal attempt")
	level.reset_episode()
	await advance(level, 700, level.Action.MOVE_RIGHT)
	check(not level.done and level._last_progress_tick > 650, "continuing to make new progress survives beyond eight seconds")
	level.reset_episode()
	level.episode_limit_seconds = 8.0
	await advance(level, 480)
	check(level.timed_out and not level.stuck and level.timeouts == 1, "overall timeout retains priority and a separate outcome")
	level.reset_episode()
	level._last_progress_tick = -480
	level.player.position.y = level.death_y + 10
	await advance(level, 1)
	check(level.deaths == 1 and not level.stuck, "death is not misclassified as stuck")
	level.reset_episode()
	level._last_progress_tick = -480
	level.player.position = level.orb.position
	await advance(level, 1)
	check(level.orb_collected and not level.stuck, "reaching the orb takes priority over an expired patience timer")
	level.queue_free()
	await process_frame
	level = make_level(false)
	await advance(level, 480)
	check(not level.done and level.stuck_count == 0, "disabled detection leaves the original timeout behavior intact")
	level.episode_limit_seconds = 481.0 * DT
	await advance(level, 1)
	check(level.timed_out and not level.stuck, "disabled detection still respects the course timeout")
	level.queue_free()
	await process_frame


func check_worker_and_recording() -> void:
	var directory := scratch.get_current_dir()
	# Save only the idle policy's observed states, then evaluate it unchanged in
	# the real worker. This makes stuck counts deterministic without a benchmark.
	var level := make_level(false, true)
	var policy := QLearning.new()
	for tick in 7:
		policy.q_table[policy.State.encode(level.get_state())] = [10.0, 0.0, 0.0, 0.0, 0.0, 0.0]
		await advance(level, 1)
	var source := directory.path_join("idle.json")
	check(Checkpoint.save_checkpoint(policy, source).is_empty(), "idle evaluation fixture saves")
	level.queue_free()
	await process_frame
	var original := FileAccess.get_file_as_bytes(source)
	var menu := preload("res://UI/MainMenu.tscn").instantiate()
	menu.checkpoint_directory = directory
	menu.checkpoint_path = source
	menu.recording_directory = directory.path_join("recordings")
	root.add_child(menu)
	current_scene = menu
	menu.get_node("%LevelSelect").select(1)
	menu._select_level(1)
	menu.get_node("%StuckToggle").button_pressed = true
	var options: OptionButton = menu.get_node("%DataSelect")
	for i in options.item_count:
		if options.get_item_metadata(i) == source:
			options.select(i)
	menu.get_node("%ModeSelect").select(1)
	menu.get_node("%HeadlessToggle").button_pressed = true
	menu.get_node("%BatchEpisodes").value = 2
	menu.get_node("%RecordEvery").value = 1
	menu._refresh_form()
	var panel := menu.get_node("%SessionInfo")
	panel.session_directory = directory
	menu.get_node("%BatchStart").pressed.emit()
	check(panel.process_id > 0 and menu.get_node("%StuckToggle").disabled, "headless launch locks the selected stuck option")
	var deadline := Time.get_ticks_msec() + 15000
	while panel.process_id > 0 and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	if panel.process_id > 0:
		OS.kill(panel.process_id)
		check(false, "stuck evaluation worker finishes")
	check(panel.completed_episodes == 2 and panel.completed_stuck == 2 and panel.latest_status.get("stuck_detection", false), "worker reports both stuck episodes and the selected setting")
	check(menu.get_node("%BatchStatus").text.contains("Stuck 2"), "headless completion displays the stuck count")
	var path: String = panel.latest_status.get("recording_path", "")
	var recording := Recording.new()
	check(recording.open(path), "stuck recording is readable")
	check(recording.header.get("stuck_detection", false) and recording.header.get("stuck_patience_seconds") == 8, "recording identifies the on/off condition and patience")
	check(recording.episodes.size() == 2, "recording contains both completed stuck attempts")
	for episode in recording.episodes:
		check(episode.metadata.outcome == "stuck" and episode.metadata.ticks == 480, "recording preserves the distinct outcome and exact duration")
	recording.close()
	check(FileAccess.get_file_as_bytes(source) == original, "stuck evaluation does not modify the policy checkpoint")
	menu.queue_free()
	await process_frame
	var viewer := preload("res://UI/ReplayViewer.tscn").instantiate()
	root.add_child(viewer)
	viewer.set_process(false)
	check(viewer.load_recordings(PackedStringArray([path])), "stuck episodes load in playback")
	viewer.advance(17.0)
	check(viewer.finished and viewer.completed == 2 and viewer.history.history[-1].outcome == "stuck", "playback retains the stuck outcome")
	viewer.queue_free()
	await process_frame


func run_check() -> void:
	for speed in [0.5, 1.0, 4.0, 128.0]:
		await check_deadline(speed, false)
	await check_deadline(1.0, true)
	await check_progress()
	scratch = DirAccess.create_temp("ml-platformer-stuck")
	if scratch != null:
		await check_worker_and_recording()
	else:
		check(false, "scratch directory opens")
	scratch = null
	if not failed:
		print("Stuck detection check passed")
	quit(1 if failed else 0)
