extends SceneTree

var failed := false
var directory := "/tmp/platformer-menu-%d" % OS.get_process_id()
var checkpoint := directory + "/table.json"


func _initialize() -> void:
	call_deferred("run_check")


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func make_menu(path: String) -> Control:
	var menu := preload("res://MainMenu.tscn").instantiate()
	menu.checkpoint_path = path
	root.add_child(menu)
	current_scene = menu
	menu.get_node("%SessionInfo").session_directory = directory
	return menu


func wait_for_worker(panel: Node) -> void:
	var deadline := Time.get_ticks_msec() + 15000
	while panel.process_id > 0 and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	if panel.process_id > 0:
		OS.kill(panel.process_id)
		check(false, "worker must exit and release the menu")
		await create_timer(1.1).timeout


func saved_episodes() -> int:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint))
	return int(data.training_episodes) if data is Dictionary else -1


func run_check() -> void:
	DirAccess.make_dir_absolute(directory)
	var menu := make_menu(checkpoint)
	var panel := menu.get_node("%SessionInfo")
	check(menu.get_node("%BatchResume").disabled, "resume disabled without a checkpoint")
	menu.get_node("%BatchEpisodes").value = 12
	menu.get_node("%BatchStart").pressed.emit()
	check(panel.process_id > 0 and menu.get_node("%HumanButton").disabled and menu.get_node("%LoadEvaluationButton").disabled, "training launches and locks other play modes")
	var worker: int = panel.process_id
	menu.get_node("%BatchStart").pressed.emit()
	check(panel.process_id == worker, "cannot launch a duplicate worker")
	await wait_for_worker(panel)
	check(saved_episodes() == 12, "menu trains exactly the requested count")
	check(menu.get_node("%BatchStatus").text.contains("12 / 12") and menu.get_node("%BatchProgress").value == 12, "final progress reaches the target")
	check(not menu.get_node("%LoadEvaluationButton").disabled and menu.get_node("%BatchResume").button_pressed, "completed checkpoint ready for evaluation or continuation")
	menu.get_node("%BatchEpisodes").value = 3
	menu.get_node("%BatchStart").pressed.emit()
	await wait_for_worker(panel)
	check(saved_episodes() == 15, "resume adds episodes to the saved table")
	menu.get_node("%BatchEpisodes").value = 100000
	menu.get_node("%BatchStart").pressed.emit()
	await create_timer(0.4).timeout
	menu.get_node("%BatchStop").pressed.emit()
	await wait_for_worker(panel)
	check(saved_episodes() > 15 and saved_episodes() < 100015, "Stop and save persists a partial batch")
	check(panel.latest_status.get("status") == "stopped", "stop reports successful saved exit")
	var before := FileAccess.get_file_as_string(checkpoint)
	menu.get_node("%LoadEvaluationButton").pressed.emit()
	var level := current_scene
	check(level != menu and not level.agent.training, "completed batch loads through Evaluate saved")
	level.queue_free()
	await process_frame
	check(FileAccess.get_file_as_string(checkpoint) == before, "evaluation does not overwrite the checkpoint")

	menu = make_menu(directory + "/missing/table.json")
	panel = menu.get_node("%SessionInfo")
	menu.get_node("%BatchEpisodes").value = 1
	menu.get_node("%BatchStart").pressed.emit()
	await wait_for_worker(panel)
	check(menu.get_node("%BatchStatus").text.contains("Cannot write checkpoint"), "save failure shown in panel")
	check(not menu.get_node("%HumanButton").disabled, "failed worker unlocks menu")
	menu.queue_free()
	await process_frame

	var corrupt := directory + "/corrupt.json"
	var file := FileAccess.open(corrupt, FileAccess.WRITE)
	file.store_string("{broken")
	file.close()
	menu = make_menu(corrupt)
	panel = menu.get_node("%SessionInfo")
	menu.get_node("%BatchStart").pressed.emit()
	await wait_for_worker(panel)
	check(menu.get_node("%BatchStatus").text.contains("not valid JSON"), "invalid checkpoint shown in panel")
	check(FileAccess.get_file_as_string(corrupt) == "{broken", "failed load preserves checkpoint")
	menu.queue_free()
	await process_frame

	menu = make_menu(checkpoint)
	panel = menu.get_node("%SessionInfo")
	menu.get_node("%BatchEpisodes").value = 100000
	menu.get_node("%BatchStart").pressed.emit()
	worker = panel.process_id
	var status_path: String = panel.status_path
	await create_timer(0.3).timeout
	menu.queue_free()
	await process_frame
	var deadline := Time.get_ticks_msec() + 10000
	while OS.is_process_running(worker) and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	check(not OS.is_process_running(worker), "closing menu stops the worker")
	if OS.is_process_running(worker):
		OS.kill(worker)
	var status: Variant = JSON.parse_string(FileAccess.get_file_as_string(status_path))
	check(status is Dictionary and status.status == "stopped", "closing menu saves before stopping")
	for name in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(name))
	DirAccess.remove_absolute(directory)
	if not failed:
		print("Headless menu check passed")
	quit(1 if failed else 0)
