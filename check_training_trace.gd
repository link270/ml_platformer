extends SceneTree

# Run this same script in two project copies to compare every step/transition.
class TracedAgent extends "res://Agents/QLearningAgent.gd":
	var trace := HashingContext.new()

	func _init() -> void:
		super._init()
		trace.start(HashingContext.HASH_SHA256)

	func record_state(state: Dictionary) -> void:
		var observed := state.duplicate(true)
		# These two rays are outside the Q-learning observation.
		for i in [1, 7]:
			observed.ray_hits[i] = false
			observed.ray_clearances[i] = 0.0
		trace.update(var_to_bytes(observed))

	func choose_action(state: Dictionary) -> int:
		record_state(state)
		var action := super.choose_action(state)
		trace.update(var_to_bytes(action))
		return action

	func learn(state: Dictionary, action: int, reward: float, next_state: Dictionary) -> void:
		record_state(state)
		trace.update(var_to_bytes([action, reward]))
		record_state(next_state)
		super.learn(state, action, reward, next_state)


func _initialize() -> void:
	call_deferred("run_check")


func run_sample(seed_value: int, headless: bool) -> Dictionary:
	var level := preload("res://Level.tscn").instantiate()
	var learner := TracedAgent.new()
	learner.rng.seed = seed_value
	level.agent = learner
	level.control_mode = level.ControlMode.Q_LEARNING
	level.headless_training = headless
	root.add_child(level)
	level.set_physics_process(false)
	var physics_trace := HashingContext.new()
	physics_trace.start(HashingContext.HASH_SHA256)
	var steps := 0
	while learner.training_episodes < 50:
		await physics_frame
		level._physics_process(1.0 / 60.0)
		if level.player._tick > 0:
			steps += 1
		physics_trace.update(var_to_bytes([
			level.player._tick, level.player.position, level.player.velocity,
			level.player.is_on_floor(), level.player.is_on_wall(), level.player.is_on_ceiling(),
			level._held_action_id, level.reward, level.done, level.orb_collected, level.timed_out,
		]))
	var result := {
		"seed": seed_value, "steps": steps, "updates": learner.updates,
		"wins": learner.training_wins, "deaths": level.deaths, "timeouts": level.timeouts,
		"physics": physics_trace.finish().hex_encode(),
		"learning": learner.trace.finish().hex_encode(),
		"table": var_to_bytes(learner.q_table).hex_encode().sha256_text(),
	}
	level.queue_free()
	await process_frame
	await physics_frame
	return result


func run_check() -> void:
	var results: Array = []
	var failed := false
	for seed_value in [12345, 42, 98765]:
		var headless := await run_sample(seed_value, true)
		var visible := await run_sample(seed_value, false)
		if headless != visible:
			push_error("Visible/headless physics and learning traces differ for seed %d" % seed_value)
			print("Visible trace: ", JSON.stringify(visible))
			failed = true
		results.append(headless)
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		if FileAccess.file_exists(args[0]):
			var reference: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
			# JSON parses integer counters as floats; normalize both sides.
			if reference != JSON.parse_string(JSON.stringify(results)):
				push_error("Physics/learning traces differ from the reference")
				failed = true
		else:
			var file := FileAccess.open(args[0], FileAccess.WRITE)
			file.store_string(JSON.stringify(results, "\t"))
	print(JSON.stringify(results))
	if not failed:
		print("Training trace check passed")
	quit(1 if failed else 0)
