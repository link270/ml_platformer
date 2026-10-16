extends SceneTree

const QLearning := preload("res://Agents/QLearningAgent.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const DT := 1.0 / 60.0
var failed := false
var path := "/tmp/ml-platformer-checkpoint-%d.json" % OS.get_process_id()


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func write_text(text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _initialize() -> void:
	call_deferred("run_check")


func run_check() -> void:
	var source := QLearning.new()
	source.q_table = {"010101|1|-1|0": [0.123456789012345, -0.4, 0.0, 0.8, 0.2, -1.0]}
	source.epsilon = 0.6
	source.learning_rate = 0.2
	source.discount = 0.9
	source.epsilon_decay = 0.99
	source.minimum_epsilon = 0.02
	source.updates = 83
	source.training_episodes = 12
	source.training_wins = 3
	check(Checkpoint.save_checkpoint(source, path).is_empty(), "checkpoint saves")
	var original := FileAccess.get_file_as_string(path)
	var restored := QLearning.new()
	check(Checkpoint.load_checkpoint(restored, path).is_empty(), "checkpoint loads")
	if failed:
		quit(1)
		return
	check(restored.q_table == source.q_table, "all Q-values round trip at full precision")
	for field in Checkpoint.SETTINGS + Checkpoint.COUNTERS:
		check(restored.get(field) == source.get(field), "checkpoint restores " + field)
	var before: Dictionary = restored.q_table.duplicate(true)
	for malformed in ["{broken json", "[]", "{}"]:
		write_text(malformed)
		check(not Checkpoint.load_checkpoint(restored, path).is_empty(), "malformed checkpoint is rejected")
		check(restored.q_table == before and restored.updates == 83, "bad load preserves current agent")
	for damage in ["version", "schema", "key", "row", "score", "setting", "counter", "wins"]:
		var data: Dictionary = JSON.parse_string(original)
		match damage:
			"version": data.format_version = 999
			"schema": data.schema.near_distance = 0.5
			"key": data.q_table = {"not a state": [0, 0, 0, 0, 0, 0]}
			"row": data.q_table["010101|1|-1|0"] = [0, 0]
			"score": data.q_table["010101|1|-1|0"][0] = "oops"
			"setting": data.epsilon = 2.0
			"counter": data.training_episodes = 1.5
			"wins": data.training_wins = 100
		write_text(JSON.stringify(data))
		check(not Checkpoint.load_checkpoint(restored, path).is_empty(), "invalid " + damage + " rejected")
		check(restored.q_table == before and restored.epsilon == 0.6 and restored.training_episodes == 12, "validation is atomic for " + damage)
	write_text(original)
	source.q_table["010101|1|-1|0"][0] = INF
	check(not Checkpoint.save_checkpoint(source, path).is_empty(), "non-finite values cannot be saved")
	check(FileAccess.get_file_as_string(path) == original, "failed save preserves old checkpoint")
	source.q_table["010101|1|-1|0"][0] = 0.25
	source.updates = 84
	check(Checkpoint.save_checkpoint(source, path).is_empty(), "save replaces an existing checkpoint")
	check(Checkpoint.load_checkpoint(restored, path).is_empty() and restored.updates == 84 and restored.q_table == source.q_table, "replacement checkpoint is complete")
	check(not Checkpoint.save_checkpoint(source, "/tmp/nonexistent-checkpoint-directory-%d/save.json" % OS.get_process_id()).is_empty(), "unwritable destination reports failure")
	check(not Checkpoint.load_checkpoint(restored, path + ".missing").is_empty(), "missing checkpoint reports failure")

	for evaluate in [false, true]:
		var menu := preload("res://MainMenu.tscn").instantiate()
		menu.checkpoint_path = path
		root.add_child(menu)
		current_scene = menu
		check(not menu.get_node("%ResumeButton").disabled and not menu.get_node("%LoadEvaluationButton").disabled, "saved menu choices enabled")
		menu.get_node("%LoadEvaluationButton" if evaluate else "%ResumeButton").pressed.emit()
		var level := current_scene
		if level == menu:
			check(false, "saved menu launch failed: " + menu.get_node("%CheckpointInfo").text)
			quit(1)
			return
		level.set_physics_process(false)
		level.agent.rng.seed = 0
		check(level.agent.training == not evaluate and level.agent.training_episodes == 12, "menu loads saved agent in requested mode with training history")
		var table_before: Dictionary = level.agent.q_table.duplicate(true)
		var updates_before: int = level.agent.updates
		for tick in 6:
			await physics_frame
			level._physics_process(DT)
		if evaluate:
			check(level.agent.q_table == table_before and level.agent.updates == updates_before, "loaded evaluation freezes the table")
		else:
			check(level.agent.updates == updates_before + 1 and level.agent.epsilon == 0.6, "resumed training continues updates without restarting exploration")
		level.get_node("%SaveButton").pressed.emit()
		check(level.get_node("%SaveStatus").text.begins_with("Saved:"), "save button reports success")
		var saved := QLearning.new()
		check(Checkpoint.load_checkpoint(saved, path).is_empty(), "save button writes a loadable checkpoint")
		check(saved.q_table.size() == level.agent.q_table.size(), "save button persists every table row")
		for key in level.agent.q_table:
			check(saved.q_table.has(key), "save button persists the state key")
			if not saved.q_table.has(key):
				continue
			for action in 6:
				# Godot's JSON parser can round tiny values by a few final decimal places.
				check(absf(saved.q_table[key][action] - level.agent.q_table[key][action]) < 1e-14, "save button persists the live action value")
		level.queue_free()
		await process_frame

	var menu := preload("res://MainMenu.tscn").instantiate()
	menu.checkpoint_path = path
	root.add_child(menu)
	current_scene = menu
	write_text("broken")
	menu.get_node("%LoadEvaluationButton").pressed.emit()
	check(current_scene == menu and menu.get_node("%CheckpointInfo").text.contains("JSON"), "load error stays in the menu with feedback")
	var old_file := FileAccess.get_file_as_string(path)
	menu.get_node("%QLearningButton").pressed.emit()
	var fresh := current_scene
	fresh.set_physics_process(false)
	check(fresh.agent.q_table.is_empty() and fresh.agent.epsilon == 1.0, "new training starts clean")
	check(FileAccess.get_file_as_string(path) == old_file, "new training does not overwrite an existing save")
	fresh.queue_free()
	await process_frame
	DirAccess.remove_absolute(path)
	menu = preload("res://MainMenu.tscn").instantiate()
	menu.checkpoint_path = path
	root.add_child(menu)
	check(menu.get_node("%ResumeButton").disabled and menu.get_node("%LoadEvaluationButton").disabled, "load choices disabled without a checkpoint")
	menu.queue_free()
	await process_frame
	if not failed:
		print("Q-checkpoint check passed")
	quit(1 if failed else 0)
