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


func make_menu(path: String) -> Control:
	var menu := preload("res://UI/MainMenu.tscn").instantiate()
	menu.checkpoint_path = path
	menu.checkpoint_directory = directory
	root.add_child(menu)
	current_scene = menu
	menu.get_node("%SessionInfo").session_directory = directory
	menu.get_node("%HeadlessToggle").button_pressed = true
	return menu


func wait_for_worker(panel: Node) -> void:
	var deadline := Time.get_ticks_msec() + 20000
	while panel.process_id > 0 and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	if panel.process_id > 0:
		OS.kill(panel.process_id)
		check(false, "worker must exit and release the menu")
		await create_timer(0.5).timeout


func saved_episodes() -> int:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint))
	return int(data.training_episodes) if data is Dictionary else -1


func run_check() -> void:
	scratch = DirAccess.create_temp("ml-platformer-menu")
	if scratch == null:
		push_error("Cannot create test scratch directory")
		quit(1)
		return
	directory = scratch.get_current_dir()
	var menu := make_menu(directory.path_join("unused.json"))
	var panel := menu.get_node("%SessionInfo")
	menu.get_node("%BatchEpisodes").value = 12
	menu.get_node("%BatchStart").pressed.emit()
	checkpoint = menu.checkpoint_path
	check(panel.process_id > 0 and menu.get_node("%ControllerSelect").disabled and menu.get_node("%DataSelect").disabled, "training launches and locks settings")
	var worker: int = panel.process_id
	menu.get_node("%BatchStart").pressed.emit()
	check(panel.process_id == worker, "cannot launch a duplicate worker")
	await wait_for_worker(panel)
	check(saved_episodes() == 12, "menu trains exactly the requested count")
	check(menu.get_node("%BatchStatus").text.contains("12 runs") and menu.get_node("%BatchProgress").value == 12, "final progress reaches the target")
	check(menu.get_node("%DataSelect").get_selected_metadata() == checkpoint, "new save selected after training")
	menu.get_node("%BatchEpisodes").value = 3
	menu.get_node("%BatchStart").pressed.emit()
	await wait_for_worker(panel)
	check(saved_episodes() == 15, "resume adds episodes to the selected data")
	menu.get_node("%BatchEpisodes").value = 100000
	menu.get_node("%BatchStart").pressed.emit()
	await create_timer(0.5).timeout
	menu.get_node("%BatchStop").pressed.emit()
	await wait_for_worker(panel)
	check(saved_episodes() > 15 and saved_episodes() < 100015, "Stop and save persists a partial batch")
	check(panel.latest_status.get("status") == "stopped", "stop reports successful saved exit: " + JSON.stringify(panel.latest_status))
	var before := FileAccess.get_file_as_string(checkpoint)
	menu.get_node("%ModeSelect").select(1)
	menu._refresh_form()
	menu.get_node("%BatchEpisodes").value = 3
	menu.get_node("%BatchStart").pressed.emit()
	await wait_for_worker(panel)
	check(panel.completed_episodes == 3 and panel.latest_status.get("status") == "completed", "headless evaluation runs exact count")
	check(FileAccess.get_file_as_string(checkpoint) == before, "headless evaluation preserves source data byte for byte")
	menu.get_node("%HeadlessToggle").button_pressed = false
	menu.get_node("%BatchStart").pressed.emit()
	var level := current_scene
	check(level != menu and not level.agent.training and level.run_limit == 3, "saved data launches visible evaluation")
	level.queue_free()
	await process_frame
	check(FileAccess.get_file_as_string(checkpoint) == before, "visible evaluation does not overwrite data")

	menu = make_menu(checkpoint)
	panel = menu.get_node("%SessionInfo")
	menu.get_node("%ControllerSelect").select(1)
	menu.get_node("%ControllerSelect").item_selected.emit(1)
	menu.get_node("%BatchEpisodes").value = 4
	menu.get_node("%BatchStart").pressed.emit()
	await wait_for_worker(panel)
	check(panel.completed_episodes == 4 and panel.latest_status.get("status") == "completed", "random policy supports headless evaluation")
	check(FileAccess.get_file_as_string(checkpoint) == before, "random evaluation preserves selected Q-learning data")
	menu.queue_free()
	await process_frame

	menu = make_menu(checkpoint)
	panel = menu.get_node("%SessionInfo")
	menu.get_node("%BatchEpisodes").value = 1
	panel.start_run(2, false, directory.path_join("missing/table.json"), false)
	await wait_for_worker(panel)
	check(menu.get_node("%BatchStatus").text.contains("Cannot write checkpoint"), "worker save failure shown in panel")
	check(not menu.get_node("%ControllerSelect").disabled, "failed worker unlocks menu")
	menu.queue_free()
	await process_frame

	var corrupt := directory.path_join("corrupt.json")
	var file := FileAccess.open(corrupt, FileAccess.WRITE)
	file.store_string("{broken")
	file.close()
	menu = make_menu(corrupt)
	panel = menu.get_node("%SessionInfo")
	menu.get_node("%BatchStart").pressed.emit()
	check(panel.process_id == -1 and menu.get_node("%CheckpointInfo").text.contains("not valid JSON"), "invalid data is rejected before launching")
	check(FileAccess.get_file_as_string(corrupt) == "{broken", "failed load preserves data")
	menu.queue_free()
	await process_frame

	menu = make_menu(checkpoint)
	panel = menu.get_node("%SessionInfo")
	menu.get_node("%BatchEpisodes").value = 100000
	menu.get_node("%BatchStart").pressed.emit()
	worker = panel.process_id
	var status_path: String = panel.status_path
	await create_timer(0.4).timeout
	menu.queue_free()
	await process_frame
	var deadline := Time.get_ticks_msec() + 10000
	while OS.is_process_running(worker) and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	check(not OS.is_process_running(worker), "closing menu stops the worker")
	if OS.is_process_running(worker):
		OS.kill(worker)
	var status: Variant = JSON.parse_string(FileAccess.get_file_as_string(status_path))
	check(status is Dictionary and status.status == "stopped", "closing menu saves before stopping")
	scratch = null
	if not failed:
		print("Headless menu check passed")
	quit(1 if failed else 0)
