extends SceneTree

const LevelScene := preload("res://Level.tscn")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")
var failed := false


func _initialize() -> void:
	call_deferred("run_check")


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func train_sample(headless: bool) -> Dictionary:
	var level := LevelScene.instantiate()
	level.control_mode = level.ControlMode.Q_LEARNING
	level.headless_training = headless
	root.add_child(level)
	level.set_physics_process(false)
	level.agent.rng.seed = 12345
	if headless:
		check(not level.player.show_rays and not level.get_node("HUD").visible, "headless skips visual updates")
	while level.agent.training_episodes < 10:
		await physics_frame
		var delta := root.get_physics_process_delta_time()
		check(is_equal_approx(delta, 1.0 / 60.0), "uncapped training keeps 1/60 steps")
		level._physics_process(delta)
	var result := {"table": level.agent.q_table.duplicate(true), "updates": level.agent.updates,
		"epsilon": level.agent.epsilon, "wins": level.agent.training_wins,
		"deaths": level.deaths, "timeouts": level.timeouts}
	level.queue_free()
	await process_frame
	return result


func run_check() -> void:
	var visible_result := await train_sample(false)
	var headless_result := await train_sample(true)
	check(visible_result == headless_result, "headless and visible runs learn identical tables from the same seed")
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		var menu := preload("res://MainMenu.tscn").instantiate()
		menu.checkpoint_path = args[0]
		root.add_child(menu)
		current_scene = menu
		menu.get_node("%LoadEvaluationButton").pressed.emit()
		check(current_scene != menu, "game menu loads headless checkpoint")
		if current_scene != menu:
			var level := current_scene
			level.set_physics_process(false)
			check(not level.agent.training and Engine.time_scale == 1.0, "headless checkpoint evaluates at normal speed")
			var table: Dictionary = level.agent.q_table.duplicate(true)
			for tick in 12:
				await physics_frame
				level._physics_process(1.0 / 60.0)
			check(table == level.agent.q_table, "evaluation preserves the headless-trained table")
			level.queue_free()
			await process_frame
	if not failed:
		print("Headless training check passed")
	quit(1 if failed else 0)
