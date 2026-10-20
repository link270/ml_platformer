extends SceneTree

# Repeat the old geometry probe with both the binary and richer horizontal keys.
# No Q-table or learning is needed to demonstrate indistinguishable observations.
func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var level := preload("res://Level.tscn").instantiate()
	var agent := preload("res://Agents/QLearningAgent.gd").new()
	level.agent = agent
	level.control_mode = level.ControlMode.Q_LEARNING
	level.headless_training = true
	root.add_child(level)
	level.set_physics_process(false)
	var matches: Array = []
	for child in level.get_children():
		if not child is StaticBody2D:
			continue
		for offset in [-15.0, 0.0, 15.0]:
			level.reset_episode()
			level.player.reset_to(child.position + Vector2(offset, -32.01))
			for tick in 3:
				await physics_frame
				level.player.set_action(0, false)
				level.player.physics_step(1.0 / 60.0)
			var state: Dictionary = level.get_state(agent.observation_rays)
			var key: String = agent.State.encode(state)
			var parts := key.split("|")
			parts[0] = parts[0].replace("2", "0")
			var binary_key := "|".join(parts)
			if binary_key == "000101|1|1|0":
				matches.append({"x": state.position.x * 32, "y": state.position.y * 32,
					"binary_key": binary_key, "horizontal_bin_key": key})
	var file := FileAccess.open("res://bin-alias-probe.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(matches, "\t"))
	print(JSON.stringify(matches))
	quit()
