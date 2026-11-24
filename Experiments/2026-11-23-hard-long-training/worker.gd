extends "res://easy_worker.gd"

# The shared worker saves 1,000 and 5,000. Save later milestones in the same run.
func on_episode_completed() -> void:
	super.on_episode_completed()
	if not agent.training or completed_runs <= 5000 or completed_runs == episodes or completed_runs % 5000 != 0:
		return
	var path := save_path.get_base_dir().path_join("%05d.json" % completed_runs)
	var error := Checkpoint.save_checkpoint(agent, path)
	if not error.is_empty():
		fail(error)
