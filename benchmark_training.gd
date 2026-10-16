extends "res://train.gd"

# Use the real worker, including its usual saves, with repeatable actions.
var physics_steps := 0
var episode_results: Array = []


func _initialize() -> void:
	save_path = "user://q_learning_benchmark.json"
	agent.rng.seed = 12345
	super._initialize()


func on_episode_completed() -> void:
	var level := current_scene
	var ticks: int = level.player.get_state().tick
	physics_steps += ticks
	episode_results.append([ticks, level.last_episode_return, level.orb_collected, level.timed_out])
	super.on_episode_completed()


func report_progress(status: String = "running", message: String = "") -> void:
	super.report_progress(status, message)
	if status != "completed":
		return
	var elapsed := (Time.get_ticks_msec() - started_at) / 1000.0
	var result := {
		"episodes": episodes, "physics_steps": physics_steps, "seconds": elapsed,
		"steps_per_second": physics_steps / elapsed, "episodes_per_second": episodes / elapsed,
		"updates": agent.updates, "wins": agent.training_wins,
		"behavior_sha256": var_to_bytes([episode_results, agent.q_table, agent.epsilon, agent.rng.state, agent.updates]).hex_encode().sha256_text(),
	}
	var file := FileAccess.open(save_path + ".benchmark.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	print("BENCHMARK ", JSON.stringify(result))
