extends SceneTree

var failed := false
var scratch: DirAccess
var directory := ""
var checkpoint := ""


func _initialize() -> void:
	call_deferred("run_check")


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func saved_episodes() -> int:
	return int(JSON.parse_string(FileAccess.get_file_as_string(checkpoint)).training_episodes)


func wait_for_pause(panel: Node) -> void:
	var deadline := Time.get_ticks_msec() + 15000
	while panel.process_id > 0 and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	if panel.process_id > 0:
		OS.kill(panel.process_id)
		check(false, "worker must finish its chunk")
		await create_timer(1.1).timeout


func finish_preview(menu: Control, outcome: String) -> void:
	var level: Node2D = menu._check_in_level
	check(is_instance_valid(level), "scheduled check-in exists")
	if not is_instance_valid(level):
		return
	level.set_physics_process(false)
	var panel := menu.get_node("%SessionInfo")
	check(panel.process_id == -1 and panel.active, "worker stopped while batch remains active")
	check(not menu.visible and menu.get_node("%ControllerSelect").disabled, "menu stays locked during check-in")
	check(not level.agent.training and Engine.time_scale == 1.0 and Engine.physics_ticks_per_second == 60, "check-in evaluates at normal speed")
	check(level.stuck_detection_enabled and panel.latest_status.get("stuck_detection", false), "worker and check-in preserve the stuck-detection option")
	check(level.player.show_rays and level.player.visible_ray_indices.size() == 6, "six observation rays remain visible")
	check(not level.get_node("%CheckpointControls").visible and level.get_node("%SpeedSelect").is_visible_in_tree() and not level.get_node("%SpeedSelect").disabled, "check-in hides save controls and exposes viewing speed")
	level.get_node("%SpeedSelect").item_selected.emit(0)
	await physics_frame
	await physics_frame
	check(Engine.time_scale == 0.5 and is_equal_approx(root.get_physics_process_delta_time(), 1.0 / 60.0), "check-in supports half speed with unchanged simulation steps")
	level.get_node("%SpeedSelect").item_selected.emit(level.NORMAL_SPEED_INDEX)
	var agent: RefCounted = level.agent
	var table: Dictionary = agent.q_table.duplicate(true)
	var episodes: int = agent.training_episodes
	var updates: int = agent.updates
	var epsilon: float = agent.epsilon
	var saved := FileAccess.get_file_as_string(checkpoint)
	level.episode_completed.connect(func():
		check(FileAccess.get_file_as_string(checkpoint) == saved, "evaluation does not write the checkpoint")
	)
	for tick in 12:
		await physics_frame
		var delta := root.get_physics_process_delta_time()
		check(is_equal_approx(delta, 1.0 / 60.0), "check-in physics stays at 1/60")
		level._physics_process(delta)
	match outcome:
		"death": level.player.position.y = level.death_y + 10
		"orb": level.player.global_position = level.orb.global_position
		"timeout": level.episode_limit_seconds = 0.01
	await physics_frame
	level._physics_process(1.0 / 60.0)
	check(level.done and agent.evaluation_episodes == 1, "exactly one evaluation episode completes")
	check(level.deaths == int(outcome == "death") and level.orb_collections == int(outcome == "orb") and level.timeouts == int(outcome == "timeout"), "requested outcome ends check-in")
	check(agent.q_table == table and agent.training_episodes == episodes and agent.updates == updates and agent.epsilon == epsilon, "check-in preserves training data and exploration schedule")
	check(menu._check_in_level == null and menu.visible, "check-in returns to progress panel")
	await process_frame


func run_check() -> void:
	scratch = DirAccess.create_temp("ml-platformer-checkins")
	if scratch == null:
		push_error("Cannot create test scratch directory: %s" % error_string(DirAccess.get_open_error()))
		quit(1)
		return
	directory = scratch.get_current_dir()
	checkpoint = directory.path_join("table.json")
	var menu := preload("res://UI/MainMenu.tscn").instantiate()
	menu.checkpoint_path = checkpoint
	menu.checkpoint_directory = directory
	menu.recording_directory = directory.path_join("recordings")
	root.add_child(menu)
	current_scene = menu
	var panel := menu.get_node("%SessionInfo")
	panel.session_directory = directory
	menu.get_node("%HeadlessToggle").button_pressed = true
	menu.get_node("%StuckToggle").button_pressed = true
	menu.get_node("%BatchEpisodes").value = 5
	menu.get_node("%BatchCheckEvery").value = 2
	menu.get_node("%RecordEvery").value = 3
	menu.get_node("%BatchStart").pressed.emit()
	checkpoint = menu.checkpoint_path
	await wait_for_pause(panel)
	check(saved_episodes() == 2 and panel.completed_episodes == 2, "first pause after two saved training episodes")
	await finish_preview(menu, "death")
	check(panel.process_id > 0, "training resumes automatically after death")
	await wait_for_pause(panel)
	check(saved_episodes() == 4 and panel.completed_episodes == 4, "second pause after four training episodes")
	await finish_preview(menu, "orb")
	check(panel.process_id > 0, "training resumes automatically after orb collection")
	await wait_for_pause(panel)
	check(not panel.active and menu._check_in_level == null and saved_episodes() == 5, "partial final chunk finishes at target without extra evaluation")
	check(menu.get_node("%BatchProgress").value == 5, "progress reaches requested total")
	var recorded_ordinals: Array = []
	for filename in DirAccess.get_files_at(menu.recording_directory):
		var recording := FileAccess.open(menu.recording_directory.path_join(filename), FileAccess.READ)
		recording.get_buffer(8)
		recording.get_buffer(recording.get_32())
		while recording.get_position() < recording.get_length():
			var json_length := recording.get_32()
			var count := recording.get_32()
			var metadata: Dictionary = JSON.parse_string(recording.get_buffer(json_length).get_string_from_utf8())
			recorded_ordinals.append(int(metadata.episode))
			recording.seek(recording.get_position() + count * 13)
		recording.close()
	check(recorded_ordinals == [3], "recording samples across worker boundaries and excludes evaluation check-ins")

	menu.get_node("%BatchEpisodes").value = 2
	menu.get_node("%BatchStart").pressed.emit()
	await wait_for_pause(panel)
	check(saved_episodes() == 7 and panel.completed_episodes == 2, "continuation counts interval relative to this batch")
	await finish_preview(menu, "timeout")
	check(not panel.active and saved_episodes() == 7, "final scheduled check-in completes batch without adding training")

	menu.get_node("%BatchEpisodes").value = 4
	menu.get_node("%BatchStart").pressed.emit()
	await wait_for_pause(panel)
	check(saved_episodes() == 9, "training saved before cancellation")
	var saved := FileAccess.get_file_as_string(checkpoint)
	menu.get_node("%BatchStart").pressed.emit()
	check(panel.process_id == -1, "cannot start duplicate worker during evaluation")
	menu._check_in_level.get_node("%MenuButton").pressed.emit()
	await process_frame
	check(not panel.active and panel.process_id == -1 and menu.visible, "Stop cancels batch during evaluation")
	check(FileAccess.get_file_as_string(checkpoint) == saved, "Stop keeps pre-evaluation checkpoint")
	check(not menu.get_node("%BatchStart").disabled and menu.get_node("%DataSelect").get_selected_metadata() == checkpoint, "saved data available after stop")

	menu.get_node("%BatchEpisodes").value = 1
	menu.get_node("%BatchCheckEvery").value = 1
	menu.get_node("%BatchStart").pressed.emit()
	await wait_for_pause(panel)
	var preview: Node2D = menu._check_in_level
	menu.queue_free()
	await process_frame
	await process_frame
	check(not is_instance_valid(preview), "closing menu removes visible check-in")
	scratch = null
	if not failed:
		print("Training check-ins check passed")
	quit(1 if failed else 0)
