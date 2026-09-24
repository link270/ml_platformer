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
	var level := preload("res://Level.tscn").instantiate()
	root.add_child(level)
	level.set_physics_process(false)
	var player: CharacterBody2D = level.get_node("Player")
	await physics_frame
	player.physics_step(DT)
	check(player.is_on_floor(), "initial landing")

	for tick in 12:
		await physics_frame
		player.set_action(1.0, false)
		player.physics_step(DT)
		check(absf(player.velocity.x) <= 6.0 * 32.0 + 0.01, "horizontal speed cap")
	check(is_equal_approx(player.velocity.x, 6.0 * 32.0), "horizontal acceleration")

	for tick in 10:
		await physics_frame
		player.set_action(-1.0, false)
		player.physics_step(DT)
	check(player.velocity.x < 0.0, "reversal")

	player.reset_to(level.get_node("Spawn").global_position)
	check(player.velocity == Vector2.ZERO, "reset velocity")
	await physics_frame
	player.physics_step(DT)
	await physics_frame
	player.set_action(0.0, true)
	player.physics_step(DT)
	for tick in 2:
		await physics_frame
		player.physics_step(DT)
	check(player.velocity.y >= -12.0 * 32.0 - 0.01, "upward speed cap")
	check(player.velocity.y < 0.0, "jump launch")
	for tick in 100:
		await physics_frame
		player.physics_step(DT)
		check(player.velocity.y <= 14.0 * 32.0 + 0.01, "fall speed cap")
	check(player.is_on_floor(), "jump landing")

	for tick in 120:
		await physics_frame
		player.set_action(1.0, false)
		player.physics_step(DT)
	check(player.global_position.x <= 304.1, "wall blocking")
	check(is_zero_approx(player.velocity.x), "wall velocity")
	var wall_state: Dictionary = player.get_state()
	check(wall_state.ray_hits[2] and wall_state.ray_clearances[2] < 0.05, "post-move wall sensing")

	var block_scene := preload("res://Block.tscn")
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
	check(state.tick == 1 and state.action.move_axis == 0.5, "latest applied action")
	check(state.position.distance_to(player.position / 32.0) < 0.001, "latest position")
	var state_string: String = player.get_state_string()
	check(state_string.split("\n").size() == state.size() and state_string.contains("tick: 1"), "state string")
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

	state = level.reset_episode()
	check(not state.done and state.reward == 0.0 and state.orb_proximity == 0.0, "episode reset")
	await physics_frame
	state = level.step(DT, 1.0, false)
	check(not state.done and state.reward > 0.0, "reward for approaching orb")
	await physics_frame
	state = level.step(DT, -1.0, false)
	check(state.reward < 0.0, "penalty for moving away")

	level.reset_episode()
	player.global_position = Vector2(80, level.death_y + 10.0)
	await physics_frame
	state = level.step(DT, 0.0, false)
	check(state.done and state.reward == -1.0 and not state.orb_collected, "death outcome")
	var death_tick: int = state.tick
	check(level.step(DT, 1.0, false).tick == death_tick, "terminal stops movement")

	level.reset_episode()
	player.reset_to(level.get_node("Orb").global_position + Vector2(-30, 0))
	await physics_frame
	player.velocity.x = 6.0 * 32.0
	state = level.step(DT, 1.0, false)
	check(state.done and state.reward == 1.0 and state.orb_collected, "orb outcome")
	check(not level.get_node("Orb").visible, "collected orb hidden")
	state = level.reset_episode()
	check(not state.done and state.reward == 0.0 and level.get_node("Orb").visible, "orb restored")
	if not failed:
		print("Platformer check passed")
	quit(1 if failed else 0)
