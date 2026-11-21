extends "res://Experiments/2026-10-29-medium-reward-comparison/worker.gd"

# Save the requested milestones without resuming or reseeding training.
func on_episode_completed() -> void:
	super.on_episode_completed()
	if not agent.training or completed_runs not in [1000, 5000]:
		return
	var path := save_path.get_base_dir().path_join("%05d.json" % completed_runs)
	var error := Checkpoint.save_checkpoint(agent, path)
	if not error.is_empty():
		fail(error)
