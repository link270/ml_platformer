extends SceneTree

const Agent := preload("res://Agents/Agent.gd")
const QLearning := preload("res://Agents/QLearningAgent.gd")
const QState := preload("res://Agents/QState.gd")
const DT := 1.0 / 60.0
var failed := false


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func observation() -> Dictionary:
	return {"ray_hits": [true, false, true, false, true, false, true, false],
		"ray_clearances": [0.0, 2.0, 1.01, 2.0, 0.0, 2.0, 1.0, 2.0],
		"orb_offset": Vector2(5, -5), "grounded": true, "velocity": Vector2.ZERO, "done": false}


func _initialize() -> void:
	call_deferred("run_check")


func run_check() -> void:
	var state := observation()
	check(QState.encode(state) == "101100|1|-1|0", "six bits use L R U D DL DR order and inclusive one-block threshold")
	state.ray_hits[1] = true
	state.ray_clearances[1] = 0.0
	state.ray_hits[7] = true
	state.ray_clearances[7] = 0.0
	check(QState.encode(state) == "101100|1|-1|0", "upward diagonal rays do not affect table keys")
	state.orb_offset = Vector2(0.5, -0.5)
	check(QState.encode(state).ends_with("|0|0|0"), "orb alignment has a half-block tolerance")
	state.grounded = false
	state.velocity.y = -1.0
	check(QState.motion(state) == 1, "rising state")
	state.velocity.y = 0.0
	check(QState.motion(state) == 2, "apex belongs to falling state")
	state.velocity.y = 10.0
	check(QState.motion(state) == 2, "falling state")

	# Enumerate all input combinations to detect collisions in the state encoding.
	var keys: Dictionary = {}
	for mask in 64:
		for i in 6:
			state.ray_hits[QState.RAY_INDICES[i]] = bool(mask & (1 << i))
			state.ray_clearances[QState.RAY_INDICES[i]] = 0.0
		for x in [-2.0, 0.0, 2.0]:
			for y in [-2.0, 0.0, 2.0]:
				for phase in 3:
					state.orb_offset = Vector2(x, y)
					state.grounded = phase == 0
					state.velocity.y = -1.0 if phase == 1 else 1.0
					keys[QState.encode(state)] = true
	check(keys.size() == 1728, "state encoding has exactly 1728 distinct combinations")

	var learner := QLearning.new()
	check(learner is Agent, "Q-learning inherits the shared agent")
	learner.rng.seed = 12345
	state = observation()
	var next_state := state.duplicate(true)
	next_state.orb_offset = Vector2(-5, 5)
	learner.q_table[QState.encode(next_state)] = [0.0, 0.0, 2.0, 0.0, 0.0, 0.0]
	learner.learn(state, 1, 0.5, next_state)
	check(is_equal_approx(learner.values(state)[1], 0.24), "Bellman update uses reward plus discounted best next value")
	next_state.done = true
	learner.learn(state, 1, -1.0, next_state)
	check(is_equal_approx(learner.values(state)[1], 0.116), "terminal update never bootstraps from next state")
	learner.finish_episode(true)
	check(learner.training_episodes == 1 and learner.training_wins == 1 and is_equal_approx(learner.epsilon, 0.995), "training outcome and exploration decay")
	learner.epsilon = 0.05
	learner.finish_episode(false)
	check(is_equal_approx(learner.epsilon, 0.05), "exploration has a floor")
	learner.training = false
	var table_before: Dictionary = learner.q_table.duplicate(true)
	var updates_before: int = learner.updates
	for i in 20:
		check(learner.choose_action(state) == 1, "evaluation chooses the best learned action")
	learner.learn(state, 0, 20.0, next_state)
	learner.finish_episode(true)
	var unseen := observation()
	unseen.orb_offset = Vector2.ZERO
	learner.choose_action(unseen)
	check(learner.q_table == table_before and learner.updates == updates_before and learner.epsilon == 0.05, "evaluation freezes values, table size, updates, and epsilon")
	check(learner.evaluation_episodes == 1 and learner.evaluation_wins == 1, "evaluation stats are separate")

	var level := preload("res://Level.tscn").instantiate()
	level.control_mode = level.ControlMode.Q_LEARNING
	root.add_child(level)
	level.set_physics_process(false)
	learner = level.agent
	learner.rng.seed = 12345
	check(level.player.show_rays and level.player.visible_ray_indices == QState.RAY_INDICES, "Q-learning displays exactly the six input rays")
	check(level.get_node("%AgentPanel").visible, "training panel visible")
	var start_state: Dictionary = level.get_state()
	var initial_proximity: float = start_state.orb_proximity
	for tick in 6:
		await physics_frame
		level._physics_process(DT)
		check(learner.updates == (1 if tick == 5 else 0), "learning occurs once per six-frame decision")
	check(is_equal_approx(learner.values(start_state)[level.get_state().action_id], 0.1 * level.episode_return), "decision reward aggregates the physics-frame rewards")
	check(is_equal_approx(level.episode_return, 0.1 * (level.get_state().orb_proximity - initial_proximity) - 0.001), "six nonterminal ticks cost exactly 0.001 in addition to unchanged proximity shaping")
	await physics_frame
	level._physics_process(DT)
	level.player.global_position.y = level.death_y + 10.0
	await physics_frame
	level._physics_process(DT)
	check(level.done and learner.updates == 2 and learner.training_episodes == 1, "death flushes a partial decision exactly once")
	await physics_frame
	level._physics_process(DT)
	check(not level.done and learner.updates == 2 and not learner.q_table.is_empty(), "auto reset preserves the table without repeating the terminal update")
	level.player.reset_to(level.orb.global_position)
	await physics_frame
	level._physics_process(DT)
	check(level.done and learner.training_wins == 1 and learner.training_episodes == 2, "orb success trains and records one successful episode")
	level.get_node("%SpeedSelect").item_selected.emit(3)
	check(Engine.time_scale == 8.0 and Engine.physics_ticks_per_second == 480, "speed selector applies 8x")
	level.get_node("%EvaluationButton").pressed.emit()
	check(Engine.time_scale == 1.0 and Engine.physics_ticks_per_second == 60 and level.get_node("%SpeedSelect").selected == 0, "evaluation returns to normal speed")
	check(not learner.training and level.get_state().tick == 0, "evaluation button starts a fresh evaluation episode")
	table_before = learner.q_table.duplicate(true)
	updates_before = learner.updates
	level.episode_limit_seconds = DT * 2
	for tick in 2:
		await physics_frame
		level._physics_process(DT)
	check(level.done and level.timed_out and level.timeouts == 1 and level.reward == -1.0, "stuck episodes time out separately from deaths")
	check(learner.evaluation_episodes == 1 and learner.training_episodes == 2, "timeout counts in evaluation only")
	check(learner.q_table == table_before and learner.updates == updates_before, "running evaluation leaves the trained table untouched")
	level.get_node("%EvaluationButton").pressed.emit()
	check(learner.training and not level.done and learner.q_table == table_before, "resume training preserves learned values")
	level.reset_episode()
	check(learner.training_episodes == 2, "manual resets do not count abandoned training episodes")
	var normal_max_steps := Engine.max_physics_steps_per_frame
	for index in level.TRAINING_SPEEDS.size():
		level.get_node("%SpeedSelect").item_selected.emit(index)
		await physics_frame
		await physics_frame
		var actual_delta := root.get_physics_process_delta_time()
		check(is_equal_approx(actual_delta, DT), "every speed keeps a 1/60 simulated physics step")
		level.episode_limit_seconds = 6.0 * DT
		level.reset_episode()
		updates_before = learner.updates
		initial_proximity = level.get_state().orb_proximity
		var last_nonterminal_proximity := initial_proximity
		for tick in 6:
			await physics_frame
			level._physics_process(actual_delta)
			if tick < 5:
				last_nonterminal_proximity = level.get_state().orb_proximity
		check(level.done and level.timed_out and level.get_state().tick == 6, "speed preserves timeout in simulated time")
		check(learner.updates == updates_before + 1, "speed preserves six-tick decisions")
		check(is_equal_approx(level.episode_return, -1.0 + 0.1 * (last_nonterminal_proximity - initial_proximity) - 0.001 * 5.0 / 6.0), "every speed charges elapsed nonterminal ticks and preserves the terminal penalty")
	level.queue_free()
	await process_frame
	check(Engine.time_scale == 1.0 and Engine.physics_ticks_per_second == 60 and Engine.max_physics_steps_per_frame == normal_max_steps, "leaving a fast level restores engine timing")
	if not failed:
		print("Q-learning check passed")
	quit(1 if failed else 0)
