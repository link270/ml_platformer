extends PanelContainer


func update_display(agent: RefCounted, last_return: float) -> void:
	%AgentLabel.text = "Exploration  %.0f%%\nLast reward  %+.2f\nTrained runs  %d" % [100.0 * agent.epsilon if agent.training else 0.0, last_return, agent.training_episodes]
	%EvaluationButton.text = "Evaluate" if agent.training else "Train this data"
