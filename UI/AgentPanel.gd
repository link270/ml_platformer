extends PanelContainer


func update_display(agent: RefCounted, last_return: float) -> void:
	var episodes: int = agent.training_episodes if agent.training else agent.evaluation_episodes
	var wins: int = agent.training_wins if agent.training else agent.evaluation_wins
	var success := "—" if episodes == 0 else "%.1f%%" % (100.0 * wins / episodes)
	%AgentHeading.text = "Training" if agent.training else "Evaluating"
	%AgentLabel.text = "\n".join([
		"Episodes: %d" % episodes,
		"Success rate: %s" % success,
		"Exploration: %.0f%%" % (100.0 * agent.epsilon) if agent.training else "Exploration: off",
		"Last reward: %+.2f" % last_return,
	])
	%EvaluationButton.text = "Evaluate" if agent.training else "Resume training"
