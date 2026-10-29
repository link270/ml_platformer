extends "res://Training/train.gd"

# Instrument the existing worker without changing its observations or actions.
# Progress is sampled at the normal six-tick decision boundaries, including the
# final partial decision. Evaluation episodes each use an independent fixed seed.
class MeasuredAgent extends "res://Agents/QLearningAgent.gd":
	var best_progress := 0.0
	var furthest_x := 0.0
	var decisions := 0
	var exploratory_decisions := 0
	var action_counts: Array[int] = [0, 0, 0, 0, 0, 0]

	func observe(state: Dictionary) -> void:
		best_progress = maxf(best_progress, state.orb_proximity)
		furthest_x = maxf(furthest_x, state.position.x)

	func choose_action(state: Dictionary) -> int:
		observe(state)
		var action := super.choose_action(state)
		decisions += 1
		exploratory_decisions += int(exploring)
		action_counts[action] += 1
		return action

	func learn(state: Dictionary, action: int, reward: float, next_state: Dictionary) -> void:
		observe(next_state)
		super.learn(state, action, reward, next_state)

	func reset_measurements() -> void:
		best_progress = 0.0
		furthest_x = 0.0
		decisions = 0
		exploratory_decisions = 0
		action_counts.fill(0)


var metrics_file: FileAccess
var experiment_seed := 12345
var experiment_phase := "training"
var experiment_milestone := 0


func _initialize() -> void:
	experiment_seed = OS.get_environment("ML_COMPARISON_SEED").to_int()
	experiment_phase = OS.get_environment("ML_COMPARISON_PHASE")
	experiment_milestone = OS.get_environment("ML_COMPARISON_MILESTONE").to_int()
	var path := OS.get_environment("ML_COMPARISON_METRICS")
	if path.is_empty() or FileAccess.file_exists(path):
		printerr("Metrics path missing or already exists: ", path)
		quit(1)
		return
	metrics_file = FileAccess.open(path, FileAccess.WRITE)
	if metrics_file == null:
		printerr("Cannot open metrics: ", path)
		quit(1)
		return
	agent = MeasuredAgent.new()
	agent.rng.seed = experiment_seed
	super._initialize()


func on_episode_completed() -> void:
	var level := current_scene
	var measured := agent as MeasuredAgent
	var outcome := "success" if level.orb_collected else ("stuck" if level.stuck else ("timeout" if level.timed_out else "death"))
	var row := {
		"phase": experiment_phase, "preset": preset_id,
		"milestone": experiment_milestone, "session_episode": completed_runs + 1,
		"training_episode": agent.training_episodes, "training": agent.training,
		"episode_seed": experiment_seed if agent.training else experiment_seed + completed_runs,
		"outcome": outcome, "ticks": level.player.tick,
		"seconds": level.player.tick / float(level._normal_tick_rate),
		"return": level.last_episode_return, "best_progress": measured.best_progress,
		"furthest_x_blocks": measured.furthest_x,
		"end_position": [level.player.position.x, level.player.position.y],
		"decisions": measured.decisions, "exploratory_decisions": measured.exploratory_decisions,
		"action_counts": measured.action_counts.duplicate(),
		"epsilon_after": agent.epsilon, "q_states": agent.q_table.size(),
		"updates": agent.updates, "rng_state_after": str(agent.rng.state),
	}
	metrics_file.store_line(JSON.stringify(row))
	if (completed_runs + 1) % 100 == 0:
		metrics_file.flush()
	super.on_episode_completed()
	measured.reset_measurements()
	if not agent.training and completed_runs < episodes:
		agent.rng.seed = experiment_seed + completed_runs


func report_progress(status: String = "running", message: String = "") -> void:
	super.report_progress(status, message)
	if status not in ["completed", "stopped", "error"]:
		return
	metrics_file.flush()
	var level := current_scene
	var result := {
		"status": status, "message": message, "phase": experiment_phase,
		"preset": preset_id, "seed": experiment_seed, "milestone": experiment_milestone,
		"completed": completed_runs, "wins": successful_runs,
		"deaths": level.deaths, "timeouts": level.timeouts, "stuck": level.stuck_count,
		"training_episodes": agent.training_episodes, "updates": agent.updates,
		"q_states": agent.q_table.size(), "epsilon": agent.epsilon,
		"seconds": (Time.get_ticks_msec() - started_at) / 1000.0,
		"physics_hz": level._normal_tick_rate, "episode_limit_seconds": level.episode_limit_seconds,
		"stuck_detection": level.stuck_detection_enabled,
		"patience_seconds": level.STUCK_PATIENCE_SECONDS,
		"settings": {"learning_rate": agent.learning_rate, "discount": agent.discount,
			"epsilon_decay": agent.epsilon_decay, "minimum_epsilon": agent.minimum_epsilon},
	}
	var file := FileAccess.open(OS.get_environment("ML_COMPARISON_RESULT"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
