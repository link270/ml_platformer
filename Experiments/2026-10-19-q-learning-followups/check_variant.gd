extends SceneTree

const Q := preload("res://Agents/QLearningAgent.gd")
const State := preload("res://Agents/QState.gd")
const Checkpoint := preload("res://Agents/QCheckpoint.gd")

func _initialize() -> void:
	var variant := FileAccess.get_file_as_string("res://variant.txt").strip_edges()
	var agent := Q.new()
	assert(agent.epsilon_decay == 0.999 and agent.minimum_epsilon == 0.05)
	assert(agent.discount == (0.99 if variant == "discount_099" else 0.95))
	var state := {"ray_hits": [false, false, true, false, false, false, true, false],
		"ray_clearances": [2.0, 2.0, 1.00001, 2.0, 2.0, 2.0, 1.0, 2.0],
		"orb_offset": Vector2(3, -3), "grounded": true, "velocity": Vector2.ZERO}
	assert(State.ray_bits(state) == ("120000" if variant == "horizontal_bins" else "100000"))
	state.ray_hits[6] = false
	assert(State.ray_bits(state) == ("020000" if variant == "horizontal_bins" else "000000"))
	state.ray_clearances[2] = 2.0
	assert(State.ray_bits(state) == ("020000" if variant == "horizontal_bins" else "000000"))
	state.ray_hits[2] = false
	assert(State.ray_bits(state) == "000000")
	if variant == "late_learning_rate":
		for episode in [2999, 3000, 6500, 10000, 12000]:
			agent.training_episodes = episode - 1
			agent.finish_episode(false)
			var expected := maxf(0.02, 0.1 - 0.08 * maxf(0.0, episode - 3000.0) / 7000.0)
			assert(is_equal_approx(agent.learning_rate, expected))
		agent.training = false
		agent.finish_episode(false)
		assert(agent.learning_rate == 0.02 and agent.training_episodes == 12000)
	agent.q_table = {State.encode(state): [0.0, 0.0, 1.0, 0.0, 0.0, 0.0]}
	var path := "/tmp/platformer-variant-%d.json" % OS.get_process_id()
	assert(Checkpoint.save_checkpoint(agent, path).is_empty())
	var loaded := Q.new()
	assert(Checkpoint.load_checkpoint(loaded, path).is_empty())
	assert(loaded.q_table == agent.q_table and loaded.learning_rate == agent.learning_rate)
	assert(loaded.training_episodes == agent.training_episodes and loaded.discount == agent.discount)
	# A changed encoder/schedule must never be silently used with the old format.
	if variant != "discount_099":
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		data.schema.erase("horizontal_bins" if variant == "horizontal_bins" else "learning_schedule")
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify(data))
		file.close()
		assert(not Checkpoint.load_checkpoint(loaded, path).is_empty())
	DirAccess.remove_absolute(path)
	print("Variant check passed: ", variant)
	quit()
