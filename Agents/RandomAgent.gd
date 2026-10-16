extends "res://Agents/Agent.gd"


func choose_action(_state: Dictionary) -> int:
	return rng.randi_range(0, ACTION_INPUTS.size() - 1)
