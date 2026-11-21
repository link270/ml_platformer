extends SceneTree

const Agent = preload("res://Agents/QLearningAgent.gd")
const Presets = preload("res://Agents/QPresets.gd")
const Checkpoint = preload("res://Agents/QCheckpoint.gd")


func _initialize() -> void:
	var agent := Agent.new()
	Presets.configure(agent, "baseline")
	var path := OS.get_cmdline_user_args()[0]
	var error := Checkpoint.save_checkpoint(agent, path)
	if not error.is_empty():
		printerr(error)
	quit(0 if error.is_empty() else 1)
