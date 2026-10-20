extends SceneTree

const Menu := preload("res://UI/MainMenu.tscn")
const QLearning := preload("res://Agents/QLearningAgent.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const DT := 1.0 / 60.0
var failed := false
var scratch: DirAccess
var directory := ""


func _initialize() -> void:
	call_deferred("run_check")


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func make_menu() -> Control:
	var menu := Menu.instantiate()
	menu.checkpoint_directory = directory.path_join("checkpoints")
	menu.checkpoint_path = directory.path_join("original.json")
	root.add_child(menu)
	current_scene = menu
	return menu


func choose(menu: Control, controller: int, evaluate: bool, data: String = "") -> void:
	menu.get_node("%ControllerSelect").select(controller)
	menu.get_node("%ControllerSelect").item_selected.emit(controller)
	menu.get_node("%ModeSelect").select(1 if evaluate else 0)
	var options: OptionButton = menu.get_node("%DataSelect")
	options.select(0)
	for i in options.item_count:
		if options.get_item_metadata(i) == data:
			options.select(i)
	menu._refresh_form()


func run_batch(level: Node2D) -> void:
	level.set_physics_process(false)
	level.episode_limit_seconds = DT * 2
	for tick in 20:
		await physics_frame
		level._physics_process(DT)
		if level.session_finished:
			break
	check(level.session_finished and level.session_runs == 3, "visible session stops at exactly three runs")
	var last_tick: int = level.player.tick
	for tick in 4:
		await physics_frame
		level._physics_process(DT)
	check(level.session_runs == 3 and level.player.tick == last_tick, "finished session remains stopped")
	check(level.get_node("%RunLabel").text == "Finished · 3 / 3", "completion is visible in HUD")


func run_check() -> void:
	scratch = DirAccess.create_temp("ml-platformer-run-setup")
	if scratch == null:
		quit(1)
		return
	directory = scratch.get_current_dir()
	var data_dir := directory.path_join("checkpoints")
	DirAccess.make_dir_absolute(data_dir)
	var original := directory.path_join("original.json")
	var selected := data_dir.path_join("a training sample.json")
	var other := data_dir.path_join("b.json")
	check(Checkpoint.save_checkpoint(QLearning.new(), original).is_empty(), "legacy fixture saves")
	check(Checkpoint.save_checkpoint(QLearning.new(), selected).is_empty(), "named fixture saves")
	check(Checkpoint.save_checkpoint(QLearning.new(), other).is_empty(), "second fixture saves")
	var file := FileAccess.open(data_dir.path_join("notes.txt"), FileAccess.WRITE)
	file.store_string("Not training data")
	file.close()
	var menu := make_menu()
	check(menu.get_node("%DataSelect").item_count == 31, "dropdown lists personal saves and 27 matching archives, excluding other files")
	choose(menu, 2, true)
	check(menu.get_node("%BatchStart").disabled, "evaluation requires saved data")
	choose(menu, 0, false)
	menu.get_node("%HeadlessToggle").button_pressed = true
	check(not menu.get_node("%ModeRow").visible and not menu.get_node("%RunsRow").visible and not menu.get_node("%HeadlessToggle").visible, "human mode hides irrelevant controls")
	menu.get_node("%BatchStart").pressed.emit()
	var level := current_scene
	check(level.control_mode == 0 and level.run_limit == 0 and not level.headless_training, "human mode always starts free play")
	level.queue_free()
	await process_frame

	menu = make_menu()
	choose(menu, 2, false)
	menu.get_node("%BatchEpisodes").value = 3
	menu.get_node("%BatchStart").pressed.emit()
	level = current_scene
	var fresh_path: String = level.checkpoint_path
	check(fresh_path.get_base_dir() == data_dir and fresh_path != selected, "fresh training gets a separate file in the data folder")
	check(not level.get_node("%Details").visible, "HUD starts with details collapsed")
	level.get_node("%DetailsButton").button_pressed = true
	check(level.get_node("%Details").visible, "details can be expanded")
	level.get_node("%DetailsButton").button_pressed = false
	await run_batch(level)
	var trained := QLearning.new()
	check(Checkpoint.load_checkpoint(trained, fresh_path).is_empty() and trained.training_episodes == 3, "visible training saves at its run limit")
	check(level.get_node("%SaveStatus").text.begins_with("Saved:"), "automatic save reports success")
	level.queue_free()
	await process_frame
	var saved_text := FileAccess.get_file_as_string(fresh_path)

	menu = make_menu()
	choose(menu, 2, true, fresh_path)
	menu.get_node("%BatchEpisodes").value = 3
	menu.get_node("%BatchStart").pressed.emit()
	level = current_scene
	var table: Dictionary = level.agent.q_table.duplicate(true)
	var updates: int = level.agent.updates
	await run_batch(level)
	check(not level.agent.training and level.agent.evaluation_episodes == 3 and level.agent.training_episodes == 3, "visible evaluation uses separate run counts")
	check(level.agent.q_table == table and level.agent.updates == updates, "visible evaluation leaves learned data unchanged")
	check(FileAccess.get_file_as_string(fresh_path) == saved_text, "visible evaluation leaves the selected file unchanged")
	level.queue_free()
	await process_frame

	menu = make_menu()
	choose(menu, 1, true)
	check(menu.get_node("%ModeSelect").disabled and not menu.get_node("%DataRow").visible, "random agent clearly uses evaluation without data")
	menu.get_node("%BatchEpisodes").value = 3
	menu.get_node("%BatchStart").pressed.emit()
	level = current_scene
	await run_batch(level)
	level.queue_free()
	await process_frame

	menu = make_menu()
	choose(menu, 2, false, fresh_path)
	menu.get_node("%BatchEpisodes").value = 3
	menu.get_node("%BatchStart").pressed.emit()
	level = current_scene
	await run_batch(level)
	check(level.agent.training_episodes == 6, "visible continuation adds runs to the selected data")
	level.queue_free()
	await process_frame
	menu = make_menu()
	choose(menu, 2, false, fresh_path)
	menu.get_node("%BatchStart").pressed.emit()
	level = current_scene
	level.set_physics_process(false)
	for tick in 6:
		await physics_frame
		level._physics_process(DT)
	var expected_updates: int = level.agent.updates
	level.get_node("%MenuButton").pressed.emit()
	await scene_changed
	var continued := QLearning.new()
	check(Checkpoint.load_checkpoint(continued, fresh_path).is_empty() and continued.updates == expected_updates, "returning to setup saves unfinished training")
	current_scene.queue_free()
	await process_frame

	var untouched := QLearning.new()
	check(Checkpoint.load_checkpoint(untouched, selected).is_empty() and untouched.training_episodes == 0, "other data files stay unchanged")
	check(Checkpoint.load_checkpoint(untouched, original).is_empty() and untouched.training_episodes == 0, "original save stays unchanged")

	menu = make_menu()
	var count: int = menu.get_node("%DataSelect").item_count
	var added := data_dir.path_join("added.json")
	Checkpoint.save_checkpoint(QLearning.new(), added)
	menu.get_node("%RefreshData").pressed.emit()
	check(menu.get_node("%DataSelect").item_count == count + 1, "refresh discovers newly added data")
	menu.queue_free()
	await process_frame
	scratch = null
	if not failed:
		print("Run setup check passed")
	quit(1 if failed else 0)
