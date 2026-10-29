extends SceneTree

const Presets := preload("res://Agents/QPresets.gd")
const QLearning := preload("res://Agents/QLearningAgent.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const Menu := preload("res://UI/MainMenu.tscn")
var failed := false
var scratch: DirAccess
var directory := ""


func _initialize() -> void:
	call_deferred("run_check")


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func make_menu(id: String, source: String = "") -> Control:
	var menu := Menu.instantiate()
	menu.checkpoint_directory = directory
	menu.checkpoint_path = directory.path_join(id + ".json")
	root.add_child(menu)
	current_scene = menu
	var index: int = Presets.IDS.find(id)
	menu.get_node("%ExperimentSelect").select(index)
	menu._select_experiment(index)
	menu._refresh_data(source)
	var selector: OptionButton = menu.get_node("%DataSelect")
	for i in selector.item_count:
		if selector.get_item_metadata(i) == source:
			selector.select(i)
	menu._refresh_form()
	return menu


func replay(id: String, seed_value: int, episode: int, expected: Dictionary) -> void:
	var menu := make_menu(id, Presets.archive_path(id, seed_value, episode))
	menu.get_node("%ModeSelect").select(1)
	menu._refresh_form()
	menu.get_node("%BatchStart").pressed.emit()
	var level := current_scene
	if level == menu:
		check(false, "could not load %s / %d / %d" % [id, seed_value, episode])
		menu.queue_free()
		await process_frame
		return
	level.set_physics_process(false)
	check(not level.agent.training, "archived table opens in evaluation")
	check(level.time_penalty_per_decision == Presets.time_penalty(id), "reward matches selected preset")
	check(level.get_node("%ModeLabel").text.contains(Presets.PRESETS[id].label), "filming label shows preset")
	check(level.player.show_rays and level.player.visible_ray_indices.size() == 6, "six rays remain visible")
	var table_before := var_to_bytes(level.agent.q_table)
	var actions := [0, 0, 0, 0, 0, 0]
	while not level.done:
		await physics_frame
		var decision: bool = level._decision_required()
		level._physics_process(1.0 / 60.0)
		if decision:
			actions[level._held_action_id] += 1
	var description := "%s seed %d episode %d" % [id, seed_value, episode]
	check(level.orb_collected == expected.win and level.timed_out == expected.timeout, description + " outcome matches archive")
	check(level.player.tick == int(expected.ticks), description + " timing matches archive")
	for action in actions.size():
		check(actions[action] == int(expected.actions[action]), description + " action count matches archive")
	check(absf(level.player.position.x - expected.end_x) < 0.001 and absf(level.player.position.y - expected.end_y) < 0.001, description + " final position matches archive")
	if expected.has("return"):
		check(absf(level.last_episode_return - expected["return"]) < 1e-10, description + " reward matches archive")
	check(var_to_bytes(level.agent.q_table) == table_before, "evaluation freezes Q-values")
	level.queue_free()
	await process_frame


func run_check() -> void:
	scratch = DirAccess.create_temp("ml-platformer-presets")
	if scratch == null:
		quit(1)
		return
	directory = scratch.get_current_dir()
	var saves := {}
	var loaded := 0
	for id in Presets.IDS:
		check(not saves.has(Presets.save_path(id)), "presets have separate save destinations")
		saves[Presets.save_path(id)] = true
		if not Presets.PRESETS[id].has("archive"):
			continue
		for seed_value in Presets.SEEDS:
			for episode in Presets.MILESTONES:
				var agent := QLearning.new()
				Presets.configure(agent, id)
				var error := Checkpoint.load_checkpoint(agent, Presets.archive_path(id, seed_value, episode))
				check(error.is_empty(), "%s / %d / %d loads: %s" % [id, seed_value, episode, error])
				check(agent.training_episodes == episode, "archived milestone matches")
				loaded += 1
			var result_path := "res://Experiments/%s/raw-data/results-%d.json" % [Presets.PRESETS[id].archive, seed_value]
			var results: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(result_path))
			await replay(id, seed_value, 10000, results.evaluations[-1].runs[0])

		# Resume an archive through the real worker and check-in path.
		var source := Presets.archive_path(id, 12345, 5000)
		var archive_before := FileAccess.get_file_as_bytes(source)
		var menu := make_menu(id, source)
		var panel := menu.get_node("%SessionInfo")
		panel.session_directory = directory
		menu.get_node("%HeadlessToggle").button_pressed = true
		menu.get_node("%BatchEpisodes").value = 1
		menu.get_node("%BatchCheckEvery").value = 1
		menu.get_node("%BatchStart").pressed.emit()
		check(menu.get_node("%ExperimentSelect").disabled and menu.get_node("%DataSelect").disabled, "mode and table locked during batch")
		var deadline := Time.get_ticks_msec() + 15000
		while panel.process_id > 0 and Time.get_ticks_msec() < deadline:
			await create_timer(0.05).timeout
		if panel.process_id > 0:
			OS.kill(panel.process_id)
			check(false, "worker finishes")
		var preview: Node2D = menu._check_in_level
		check(is_instance_valid(preview), "worker launches preset check-in: " + menu.get_node("%BatchStatus").text)
		if is_instance_valid(preview):
			check(preview.agent.preset_id == id and preview.agent.training_episodes == 5001, "worker resumes selected archive in matching mode")
			check(preview.time_penalty_per_decision == Presets.time_penalty(id), "check-in reward uses preset")
			if id == "late_learning_rate":
				check(is_equal_approx(preview.agent.learning_rate, 0.1 - 0.08 * 2001.0 / 7000.0), "learning schedule continues after load")
			preview.get_node("%MenuButton").pressed.emit()
		check(FileAccess.get_file_as_bytes(source) == archive_before, "training preserves source archive")
		check(menu.get_node("%DataSelect").get_selected_metadata() == menu.checkpoint_path, "completed batch selects new session save")
		var wrong_agent := QLearning.new()
		Presets.configure(wrong_agent, "baseline" if id != "baseline" else Presets.DEFAULT_ID)
		check(not Checkpoint.load_checkpoint(wrong_agent, menu.checkpoint_path).is_empty(), "new save rejects wrong experiment")
		check(wrong_agent.q_table.is_empty(), "rejected load is atomic")
		menu.queue_free()
		await process_frame

	# Switching an archived evaluation to training must save a personal copy.
	var source := Presets.archive_path("baseline", 12345, 10000)
	var archive_before := FileAccess.get_file_as_bytes(source)
	var menu := make_menu("baseline", source)
	menu.get_node("%ModeSelect").select(1)
	menu._refresh_form()
	menu.get_node("%BatchStart").pressed.emit()
	var level := current_scene
	level.set_physics_process(false)
	level._toggle_evaluation()
	check(level.agent.training and level.checkpoint_path.begins_with(directory), "evaluation-to-training uses a personal destination")
	check(level._save_checkpoint(), "archive evaluation can save a training copy")
	check(FileAccess.get_file_as_bytes(source) == archive_before, "viewport training preserves archive")
	level.queue_free()
	await process_frame

	# Include interesting early failures and recoveries used in the video report.
	var candidates: Array = JSON.parse_string(FileAccess.get_file_as_string("res://Experiments/2026-10-19-q-learning-followups/video-candidates.json"))
	for candidate in candidates:
		await replay(candidate.condition, int(candidate.seed), int(candidate.episode), candidate.first_run)
	var agent := QLearning.new()
	Presets.configure(agent, "late_learning_rate")
	agent.training_episodes = 2999
	agent.finish_episode(false)
	check(agent.learning_rate == 0.1, "early learning rate stays unchanged through 3000")
	agent.finish_episode(false)
	check(is_equal_approx(agent.learning_rate, 0.1 - 0.08 / 7000.0), "schedule begins after 3000")
	agent.training_episodes = 10000
	agent.finish_episode(false)
	check(agent.learning_rate == 0.02, "late learning rate floor holds")
	scratch = null
	if not failed:
		print("Q-presets check passed: %d archives loaded; 18 final + %d video replays; 6 worker/check-in round trips." % [loaded, candidates.size()])
	quit(1 if failed else 0)
