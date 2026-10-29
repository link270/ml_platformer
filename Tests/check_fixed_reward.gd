extends SceneTree

const Presets := preload("res://Agents/QPresets.gd")
const QLearning := preload("res://Agents/QLearningAgent.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
const Course := preload("res://Game/Levels/LargeTemplate.tscn")
const DT := 1.0 / 60.0
const PRESET := "fixed_reward_per_block"
var failed := false
var scratch: DirAccess


func _initialize() -> void:
	call_deferred("run_check")


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func sample(id: String, goal_x: float, headless: bool) -> Dictionary:
	var level := Course.instantiate()
	level.control_mode = level.ControlMode.Q_LEARNING
	level.headless_training = headless
	level.agent = QLearning.new()
	Presets.configure(level.agent, id)
	# Align centers so an exact 32-pixel horizontal move is one block closer.
	level.get_node("Orb").position = Vector2(goal_x, 464)
	root.add_child(level)
	level.set_physics_process(false)
	var totals: Array[float] = []
	var states: Array[Dictionary] = []
	for action in [level.Action.MOVE_RIGHT, level.Action.MOVE_LEFT, level.Action.DO_NOTHING]:
		var total := 0.0
		for tick in 6:
			await physics_frame
			var state: Dictionary = level.step(DT, action)
			total += state.reward
			state.erase("reward")
			states.append(state)
		totals.append(total)
	if id == PRESET:
		check(absf(totals[0] - 0.002) < 0.000001, "fixed forward reward is independent of goal distance")
		check(absf(totals[1] + 0.004) < 0.000001, "backtracking reverses progress reward and still pays time cost")
		check(is_equal_approx(totals[2], -0.001), "standing still only pays the unchanged time cost")
		level.reset_episode()
		var retreat_reward := 0.0
		for tick in 6:
			await physics_frame
			retreat_reward += level.step(DT, level.Action.MOVE_LEFT).reward
		check(absf(retreat_reward + 0.004) < 0.000001, "reset initializes distance and retreat beyond spawn remains penalized")
		level.player.position.y = level.death_y + 10
		await physics_frame
		level.step(DT, level.Action.DO_NOTHING)
		check(level.done and level.reward == -1.0, "fixed rewards preserve the exact death penalty")
		level.reset_episode()
		level.player.position = level.orb.position
		await physics_frame
		level.step(DT, level.Action.DO_NOTHING)
		check(level.done and level.orb_collected and level.reward == 1.0, "fixed rewards preserve the exact orb reward")
		level.reset_episode()
		level.episode_limit_seconds = DT
		await physics_frame
		level.step(DT, level.Action.DO_NOTHING)
		check(level.done and level.timed_out and level.reward == -1.0, "fixed rewards preserve the exact timeout penalty")
	else:
		var expected := 0.1 * 19.2 / (goal_x - 80.0) - 0.001
		check(absf(totals[0] - expected) < 0.000001, "current preset retains normalized progress rewards")
	level.queue_free()
	await process_frame
	return {"rewards": totals, "states": states}


func run_check() -> void:
	var current := QLearning.new()
	var fixed := QLearning.new()
	Presets.configure(current, Presets.DEFAULT_ID)
	Presets.configure(fixed, PRESET)
	for field in ["learning_rate", "discount", "epsilon", "epsilon_decay", "minimum_epsilon", "observation_rays"]:
		check(current.get(field) == fixed.get(field), "new experiment preserves " + field)
	check(Presets.time_penalty(PRESET) == Presets.time_penalty(Presets.DEFAULT_ID), "new experiment preserves the time penalty")
	check(Presets.archive_path(PRESET, 12345, 10000).is_empty(), "new experiment has no invented archives")
	var near := await sample(PRESET, 816, false)
	var far := await sample(PRESET, 3760, false)
	var headless := await sample(PRESET, 3760, true)
	var normalized := await sample(Presets.DEFAULT_ID, 3760, false)
	for i in near.rewards.size():
		check(absf(near.rewards[i] - far.rewards[i]) < 0.000001, "equal progress earns equal rewards on different level lengths")
	check(var_to_bytes(far) == var_to_bytes(headless), "visible and headless fixed-reward physics and rewards match")
	check(var_to_bytes(far.states) == var_to_bytes(normalized.states), "reward experiment preserves actions, observations, and physics")
	scratch = DirAccess.create_temp("ml-platformer-fixed-reward")
	check(scratch != null, "scratch directory opens")
	if scratch == null:
		quit(1)
		return
	var directory := scratch.get_current_dir()
	var path := directory.path_join("fixed.json")
	check(Checkpoint.save_checkpoint(fixed, path).is_empty(), "fixed-reward checkpoint saves")
	check(not Checkpoint.load_checkpoint(current, path).is_empty(), "normalized preset rejects a fixed-reward checkpoint")
	var restored := QLearning.new()
	Presets.configure(restored, PRESET)
	check(Checkpoint.load_checkpoint(restored, path).is_empty(), "fixed-reward checkpoint reloads")
	var legacy := directory.path_join("legacy.json")
	check(Checkpoint.save_checkpoint(current, legacy).is_empty(), "normalized fixture saves")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(legacy))
	data.erase("preset_id")
	var file := FileAccess.open(legacy, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()
	check(not Checkpoint.load_checkpoint(restored, legacy).is_empty(), "legacy normalized checkpoint cannot silently become fixed-reward training")
	await check_menu_worker(directory)
	scratch = null
	if not failed:
		print("Fixed reward check passed")
	quit(1 if failed else 0)


func check_menu_worker(directory: String) -> void:
	var menu := preload("res://UI/MainMenu.tscn").instantiate()
	menu.checkpoint_directory = directory
	menu.checkpoint_path = directory.path_join("unused.json")
	root.add_child(menu)
	current_scene = menu
	var index := Presets.IDS.find(PRESET)
	menu.get_node("%ExperimentSelect").select(index)
	menu._select_experiment(index)
	menu.get_node("%LevelSelect").select(4)
	menu._select_level(4)
	menu.get_node("%HeadlessToggle").button_pressed = true
	menu.get_node("%BatchEpisodes").value = 1
	menu.get_node("%BatchCheckEvery").value = 1
	var panel := menu.get_node("%SessionInfo")
	panel.session_directory = directory
	menu.get_node("%BatchStart").pressed.emit()
	var deadline := Time.get_ticks_msec() + 15000
	while panel.process_id > 0 and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	if panel.process_id > 0:
		OS.kill(panel.process_id)
		check(false, "fixed-reward worker finishes")
	var preview: Node2D = menu._check_in_level
	check(is_instance_valid(preview), "fixed-reward worker launches a matching check-in")
	if is_instance_valid(preview):
		preview.set_physics_process(false)
		check(preview.agent.preset_id == PRESET and preview.agent.training_episodes == 1 and not preview.agent.training, "worker saves and check-in evaluates the new preset")
		check(preview.scene_file_path == "res://Game/Levels/TrainingHard.tscn", "new preset uses the selected larger level")
		preview.get_node("%MenuButton").pressed.emit()
	var trained := QLearning.new()
	Presets.configure(trained, PRESET)
	check(Checkpoint.load_checkpoint(trained, menu.checkpoint_path).is_empty() and trained.training_episodes == 1, "worker checkpoint remains readable by its experiment")
	var checkpoint_path: String = menu.checkpoint_path
	var saved := FileAccess.get_file_as_bytes(checkpoint_path)
	menu.get_node("%HeadlessToggle").button_pressed = false
	menu.get_node("%ModeSelect").select(1)
	menu._refresh_form()
	menu.get_node("%BatchStart").pressed.emit()
	var level := current_scene
	check(level != menu, "new preset launches visible evaluation")
	if level != menu:
		level.set_physics_process(false)
		check(level.agent.preset_id == PRESET and not level.agent.training, "visible evaluation retains the fixed-reward preset")
		level.queue_free()
	else:
		menu.queue_free()
	await process_frame
	check(FileAccess.get_file_as_bytes(checkpoint_path) == saved, "visible evaluation leaves the trained checkpoint unchanged")
