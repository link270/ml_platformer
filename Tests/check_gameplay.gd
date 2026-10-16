extends SceneTree

const DT := 1.0 / 60.0
var failed := false


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func _initialize() -> void:
	call_deferred("run_check")


func run_check() -> void:
	var level := preload("res://Game/Level.tscn").instantiate()
	root.add_child(level)
	level.set_physics_process(false)
	check(level.get_node("%StatsLabel").text == "Episodes completed: 0\nDeaths: 0\nOrb collections: 0\nTimeouts: 0", "session stats start at zero")
	var player: CharacterBody2D = level.get_node("Player")
	await physics_frame
	player.physics_step(DT)
	check(player.is_on_floor(), "initial landing")

	for axis in [1.0, -1.0, 0.0, 0.5, -0.5]:
		await physics_frame
		player.set_action(axis, false)
		player.physics_step(DT)
		check(is_equal_approx(player.velocity.x, signf(axis) * 6.0 * 32.0), "instant fixed horizontal speed, stop, and reversal")
	await physics_frame
	player.physics_step(DT)
	check(is_zero_approx(player.velocity.x), "missing action stops immediately")

	var jump_snapshots: Array[Dictionary] = []
	for run in 2:
		player.reset_to(level.get_node("Spawn").global_position)
		check(player.velocity == Vector2.ZERO, "reset velocity")
		await physics_frame
		player.set_action(0.0, true)
		player.physics_step(DT)
		check(player.is_on_floor() and is_zero_approx(player.velocity.y), "reset requires ground contact before jumping")
		for tick in 80:
			await physics_frame
			var axis := 1.0 if tick == 1 else (-1.0 if tick == 2 else 0.0)
			player.set_action(axis, tick == 0 or (run == 1 and tick < 20))
			player.physics_step(DT)
			var jump_state: Dictionary = player.get_state()
			if tick == 0:
				check(is_equal_approx(player.velocity.y, -12.0 * 32.0), "instant fixed jump impulse")
				check(not jump_state.jump_allowed, "no airborne jump permission")
			if tick == 1:
				check(is_equal_approx(player.velocity.y, (-12.0 + 40.0 * DT) * 32.0), "gravity after takeoff and no double jump")
			if tick >= 1 and tick <= 3:
				check(not player.is_on_floor(), "air steering is tested while airborne")
				check(is_equal_approx(player.velocity.x, axis * 6.0 * 32.0), "instant air steering and stopping")
			check(player.velocity.y <= 14.0 * 32.0 + 0.01, "fall speed cap")
			if run == 0:
				jump_snapshots.append(jump_state)
			else:
				check(jump_state.position.distance_to(jump_snapshots[tick].position) < 0.01, "jump requests in air do not change jump height or queue a jump")
				check(jump_state.velocity.distance_to(jump_snapshots[tick].velocity) < 0.01, "fixed jump trajectory regardless of jump hold")
		check(player.is_on_floor(), "jump landing")

	for tick in 120:
		await physics_frame
		player.set_action(1.0, false)
		player.physics_step(DT)
	check(player.global_position.x <= 304.1, "wall blocking")
	check(is_zero_approx(player.velocity.x), "wall velocity")
	var wall_state: Dictionary = player.get_state()
	check(wall_state.ray_hits[2] and wall_state.ray_clearances[2] < 0.05, "post-move wall sensing")

	var block_scene := preload("res://Game/Block.tscn")
	for point in [Vector2(464, 208), Vector2(464, 144), Vector2(400, 272)]:
		var block := block_scene.instantiate()
		block.position = point
		level.add_child(block)
	await physics_frame
	player.reset_to(Vector2(400, 208))
	var state: Dictionary = player.get_state()
	check(state.tick == 0 and not state.jump_allowed, "reset observation")
	check(state.ray_hits.size() == 8 and state.ray_clearances.size() == 8, "eight probes")
	check(state.ray_hits[2] and absf(state.ray_clearances[2] - 1.0) < 0.05, "right clearance")
	check(state.ray_hits[1] and absf(state.ray_clearances[1] - sqrt(2.0)) < 0.05, "diagonal clearance")
	check(state.ray_hits[4] and absf(state.ray_clearances[4] - 1.0) < 0.05, "down clearance")
	check(not state.ray_hits[0] and is_equal_approx(state.ray_clearances[0], 2.0), "no hit clearance")

	var contact_block := block_scene.instantiate()
	contact_block.position = Vector2(400, 240)
	level.add_child(contact_block)
	await physics_frame
	player.reset_to(Vector2(400, 208))
	state = player.get_state()
	check(state.ray_hits[4] and state.ray_clearances[4] < 0.05, "contact clearance")
	await physics_frame
	player.set_action(0.5, false)
	player.physics_step(DT)
	state = player.get_state()
	check(state.tick == 1 and state.action.move_axis == 1.0, "latest applied discrete action")
	check(state.position.distance_to(player.position / 32.0) < 0.001, "latest position")
	var preserved := state.duplicate(true)
	var mutated: Dictionary = player.get_state()
	mutated.action.move_axis = 99.0
	mutated.ray_hits[0] = not mutated.ray_hits[0]
	mutated.ray_clearances[0] = -99.0
	check(player.get_state() == preserved, "editing an observation cannot change the player or cached rays")
	await physics_frame
	player.physics_step(DT)
	check(state == preserved, "later physics and sampling cannot change an earlier observation")
	var state_string: String = player.get_state_string()
	check(state_string.split("\n").size() == state.size() and state_string.contains("tick: 2"), "state string")
	player.show_rays = true
	player.queue_redraw()
	await process_frame
	player.show_rays = false

	var snapshots: Array[Dictionary] = []
	for run in 2:
		player.reset_to(level.get_node("Spawn").global_position)
		check(player.get_state().tick == 0, "replay reset tick")
		await physics_frame
		player.physics_step(DT)
		for tick in 20:
			await physics_frame
			player.set_action(1.0 if tick < 12 else -1.0, tick == 2)
			player.physics_step(DT)
			state = player.get_state()
			if run == 0:
				snapshots.append(state)
			else:
				var previous: Dictionary = snapshots[tick]
				check(state.position.distance_to(previous.position) < 0.01, "replay position")
				check(state.velocity.distance_to(previous.velocity) < 0.01, "replay velocity")
				check(state.ray_hits == previous.ray_hits, "replay hits")
				for i in 8:
					check(absf(state.ray_clearances[i] - previous.ray_clearances[i]) < 0.01, "replay clearance")

	var expected_axes := [0.0, -1.0, 1.0, 0.0, -1.0, 1.0]
	for action_id in 6:
		level.reset_episode()
		for tick in 6:
			await physics_frame
			level.step(DT, level.Action.DO_NOTHING)
		await physics_frame
		state = level.step(DT, action_id)
		check(state.action.move_axis == expected_axes[action_id], "action ID maps horizontal input")
		check(state.action.jump_pressed == (action_id >= 3), "action ID maps jump input")
		check(is_equal_approx(player.velocity.x, expected_axes[action_id] * 6.0 * 32.0), "action ID applies horizontal movement")
		check(is_equal_approx(player.velocity.y, -12.0 * 32.0 if action_id >= 3 else 0.0), "action ID applies grounded jump")
		if action_id >= 3:
			await physics_frame
			state = level.step(DT, action_id)
			check(is_equal_approx(player.velocity.y, (-12.0 + 40.0 * DT) * 32.0), "repeated jump action cannot double jump")

	state = level.reset_episode()
	check(state.decision_required, "reset requests an immediate first decision")
	for tick in 18:
		await physics_frame
		var requested_action: int = level.Action.MOVE_RIGHT if tick == 0 or tick == 12 else level.Action.MOVE_LEFT
		var expected_action: int = level.Action.MOVE_LEFT if tick >= 6 and tick < 12 else level.Action.MOVE_RIGHT
		state = level.step(DT, requested_action)
		check(state.tick == tick + 1, "shared step advances exactly one physics tick")
		check(state.action_id == expected_action, "shared interface holds action for six ticks and ignores early replacements")
		check(state.action.move_axis == expected_axes[expected_action], "held action drives player movement")
		check(state.decision_required == ((tick + 1) % 6 == 0), "shared interface reports the next decision boundary")
	await physics_frame
	level.step(DT, level.Action.MOVE_RIGHT)
	state = level.reset_episode()
	check(state.tick == 0 and state.decision_required and state.action_id == level.Action.DO_NOTHING, "mid-interval reset clears held action and timing")
	await physics_frame
	state = level.step(DT, level.Action.MOVE_LEFT)
	check(state.action_id == level.Action.MOVE_LEFT and state.action.move_axis == -1.0, "reset immediately accepts a new decision")

	level.reset_episode()
	for tick in 18:
		await physics_frame
		var previous_state: Dictionary = level.get_state()
		level._physics_process(DT)
		state = level.get_state()
		var action_id: int = state.action_id
		check(action_id >= 0 and action_id < 6, "random agent chooses a valid action ID")
		check(state.action.move_axis == expected_axes[action_id] and state.action.jump_pressed == (action_id >= 3), "random agent uses shared action mapping")
		if not previous_state.decision_required:
			check(action_id == previous_state.action_id, "random agent uses shared decision timing")

	state = level.reset_episode()
	check(not state.done and state.reward == 0.0 and state.orb_proximity == 0.0, "episode reset")
	check(state.action_id == level.Action.DO_NOTHING, "reset clears random agent action")
	for tick in 6:
		await physics_frame
		state = level.step(DT, level.Action.MOVE_RIGHT)
		check(not state.done and state.reward > 0.0, "reward for approaching orb")
	await physics_frame
	state = level.step(DT, level.Action.MOVE_LEFT)
	check(state.reward < 0.0, "penalty for moving away")

	level.reset_episode()
	var deaths_before: int = level.deaths
	var collections_before: int = level.orb_collections
	player.global_position = Vector2(80, level.death_y + 10.0)
	await physics_frame
	state = level.step(DT, level.Action.DO_NOTHING)
	check(state.done and state.reward == -1.0 and not state.orb_collected, "death outcome")
	check(not state.decision_required, "terminal state requests no further decisions")
	var death_tick: int = state.tick
	check(level.step(DT, level.Action.MOVE_RIGHT).tick == death_tick, "terminal stops movement")
	check(level.deaths == deaths_before + 1 and level.orb_collections == collections_before, "death counted once even when terminal step repeats")
	await physics_frame
	level._physics_process(DT)
	state = level.get_state()
	check(not state.done and state.tick == 0 and state.reward == 0.0, "random agent resets after death")
	check(player.global_position == level.get_node("Spawn").global_position and player.velocity == Vector2.ZERO, "death reset restores spawn and clears motion")
	check(state.action_id == level.Action.DO_NOTHING and state.decision_required, "death reset clears agent action and timing")
	check(level.deaths == deaths_before + 1, "death count survives automatic reset")
	await physics_frame
	level._physics_process(DT)
	check(level.get_state().tick == 1 and not level.done, "random agent resumes next episode")

	level.reset_episode()
	player.reset_to(level.get_node("Orb").global_position + Vector2(-30, 0))
	await physics_frame
	player.velocity.x = 6.0 * 32.0
	state = level.step(DT, level.Action.MOVE_RIGHT)
	check(state.done and state.reward == 1.0 and state.orb_collected, "orb outcome")
	check(not level.get_node("Orb").visible, "collected orb hidden")
	level._on_orb_body_entered(player)
	check(level.orb_collections == collections_before + 1, "orb collection counted once despite duplicate signal")
	await physics_frame
	level._physics_process(DT)
	state = level.get_state()
	check(not state.done and state.tick == 0 and state.reward == 0.0 and not state.orb_collected, "random agent resets after orb collection")
	check(level.get_node("Orb").visible and player.global_position == level.get_node("Spawn").global_position, "orb reset restores orb and spawn")
	level._on_orb_body_entered(player)
	check(not level.done and level.orb_collections == collections_before + 1, "stale orb signal after reset does not count a new success")
	level.reset_episode()
	check(level.get_node("%StatsLabel").text == "Episodes completed: %d\nDeaths: %d\nOrb collections: %d\nTimeouts: 0" % [deaths_before + collections_before + 2, deaths_before + 1, collections_before + 1], "stats display totals and survive manual reset")

	level.queue_free()
	await process_frame
	level = preload("res://Game/Level.tscn").instantiate()
	level.control_mode = level.ControlMode.HUMAN
	root.add_child(level)
	level.set_physics_process(false)
	player = level.get_node("Player")
	Input.action_press("move_right")
	await physics_frame
	level._physics_process(DT)
	check(is_equal_approx(player.velocity.x, 6.0 * 32.0), "human keyboard moves right")
	Input.action_release("move_right")
	await physics_frame
	Input.action_press("move_left")
	level._physics_process(DT)
	check(is_equal_approx(player.velocity.x, -6.0 * 32.0), "human can reverse before six agent ticks")
	Input.action_release("move_left")
	Input.action_press("jump")
	await physics_frame
	level._physics_process(DT)
	check(is_zero_approx(player.velocity.x) and is_equal_approx(player.velocity.y, -12.0 * 32.0), "human stops and jumps immediately")
	var landed := false
	for tick in 80:
		await physics_frame
		level._physics_process(DT)
		if landed:
			check(player.is_on_floor(), "holding human jump does not repeat after landing")
		landed = landed or player.is_on_floor()
	Input.action_release("jump")
	check(landed, "human jump lands")
	level.queue_free()
	await process_frame

	check(ProjectSettings.get_setting("application/run/main_scene") == "res://UI/MainMenu.tscn", "game starts at menu")
	for mode in 3:
		var menu := preload("res://UI/MainMenu.tscn").instantiate()
		root.add_child(menu)
		current_scene = menu
		check(not menu.get_node("%QLearningButton").disabled and menu.get_node("%DeepAgentButton").disabled, "Q-learning enabled and deep agent reserved")
		check(menu.get_node("%SessionInfo").get_child_count() >= 3, "menu has room for training information")
		menu.get_node(["%HumanButton", "%RandomButton", "%QLearningButton"][mode]).pressed.emit()
		var game := current_scene
		game.set_physics_process(false)
		check(game.scene_file_path == "res://Game/Level.tscn", "menu starts the level")
		check(game.control_mode == mode, "menu starts selected control mode")
		check(game.deaths == 0 and game.orb_collections == 0, "menu launch starts a fresh stats session")
		if mode == game.ControlMode.HUMAN:
			var escape := InputEventAction.new()
			escape.action = "ui_cancel"
			escape.pressed = true
			game._unhandled_input(escape)
		else:
			game.get_node("HUD/MenuButton").pressed.emit()
		await scene_changed
		check(current_scene.scene_file_path == "res://UI/MainMenu.tscn", "game can return to menu")
		current_scene.queue_free()
		await process_frame
	if not failed:
		print("Platformer check passed")
	quit(1 if failed else 0)
