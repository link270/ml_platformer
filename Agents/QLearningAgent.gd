extends "res://Agents/Agent.gd"

const State := preload("res://Agents/QState.gd")

# Starting experiment settings. Gamma discounts one six-frame decision.
var learning_rate := 0.1
var discount := 0.95
var epsilon := 1.0
var epsilon_decay := 0.995
var minimum_epsilon := 0.05
var training := true

var q_table: Dictionary = {}
var updates := 0
var training_episodes := 0
var training_wins := 0
var evaluation_episodes := 0
var evaluation_wins := 0
var exploring := false


func _init() -> void:
	super._init()
	observation_rays = State.RAY_INDICES


func values(state: Dictionary) -> Array:
	# Reading unseen states during evaluation must not grow the table.
	return q_table.get(State.encode(state), [0.0, 0.0, 0.0, 0.0, 0.0, 0.0])


func choose_action(state: Dictionary) -> int:
	exploring = training and rng.randf() < epsilon
	if exploring:
		return rng.randi_range(0, ACTION_INPUTS.size() - 1)
	var scores := values(state)
	var best: float = scores.max()
	var tied_actions: Array[int] = []
	for action in scores.size():
		if scores[action] == best:
			tied_actions.append(action)
	# Random ties avoid an arbitrary preference for idle on unseen states.
	return tied_actions[rng.randi_range(0, tied_actions.size() - 1)]


func learn(state: Dictionary, action: int, reward: float, next_state: Dictionary) -> void:
	if not training:
		return
	var scores := values(state)
	var target := reward
	if not next_state.done:
		target += discount * float(values(next_state).max())
	scores[action] += learning_rate * (target - scores[action])
	q_table[State.encode(state)] = scores
	updates += 1


func finish_episode(success: bool) -> void:
	if training:
		training_episodes += 1
		training_wins += int(success)
		epsilon = maxf(minimum_epsilon, epsilon * epsilon_decay)
	else:
		evaluation_episodes += 1
		evaluation_wins += int(success)
