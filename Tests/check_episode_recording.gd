extends SceneTree

const Recorder := preload("res://Training/EpisodeRecorder.gd")
const LevelScene := preload("res://Game/Level.tscn")
const DT := 1.0 / 60.0
var failed := false
var scratch: DirAccess
var directory := ""


func _initialize() -> void:
	call_deferred("run_check")


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func verify_file(path: String, expected: Dictionary, interval: int, offset: int) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	check(file.get_buffer(8).get_string_from_ascii() == Recorder.MAGIC, "recording has a versioned magic header")
	var header: Dictionary = JSON.parse_string(file.get_buffer(file.get_32()).get_string_from_utf8())
	check(header.physics_hz == 60 and header.sample_bytes == 13 and header.record_every == interval, "header describes timing and layout")
	check(header.episode_offset == offset and header.source_sha256.size() == 6, "header identifies session sampling and source")
	var ordinals: Array = []
	while file.get_position() < file.get_length():
		var json_length := file.get_32()
		var count := file.get_32()
		var metadata: Dictionary = JSON.parse_string(file.get_buffer(json_length).get_string_from_utf8())
		var ordinal := int(metadata.episode)
		ordinals.append(ordinal)
		check(ordinal % interval == 0, "only the requested episodes are saved")
		check(metadata.outcome == "timeout" and metadata.training and count == 10 and metadata.ticks == 9, "complete episode has outcome, mode, and spawn plus all ticks")
		var samples := file.get_buffer(count * Recorder.SAMPLE_BYTES)
		check(samples.size() == count * Recorder.SAMPLE_BYTES, "episode payload is complete")
		var observations: Array = expected[ordinal]
		check(observations.size() == count, "every physics step is recorded exactly once")
		var total_reward := 0.0
		for i in count:
			var at := i * Recorder.SAMPLE_BYTES
			var position := Vector2(samples.decode_float(at), samples.decode_float(at + 4))
			var reward := samples.decode_float(at + 8)
			check(position.is_equal_approx(observations[i][0]), "recorded position matches the actual trajectory")
			check(is_equal_approx(reward, observations[i][1]), "recorded reward matches the actual tick")
			check(samples[at + 12] == observations[i][2], "recorded actions and exploration flags match")
			total_reward += reward
		check(is_equal_approx(total_reward, metadata.episode_return), "episode return matches recorded rewards")
	check(ordinals == ([2, 4, 6] if interval == 2 else [1, 2, 3, 4, 5, 6]), "sampling uses the session ordinal, including a chunk offset")
	file.close()


func sample_run(interval: int, trails: bool, offset: int = 0) -> Dictionary:
	var level := LevelScene.instantiate()
	level.control_mode = level.ControlMode.Q_LEARNING
	level.agent = level.QLearningAgent.new()
	level.agent.rng.seed = 12345
	level.headless_training = not trails
	level.show_path_trails = trails
	level.record_every = interval
	level.recording_episode_offset = offset
	level.recording_path = directory.path_join("sample-%d-%s.mlpaths" % [interval, trails])
	level.episode_limit_seconds = DT * 9
	root.add_child(level)
	level.set_physics_process(false)
	check(level.recording_error.is_empty(), "recording opens")
	check((level.episode_recorder == null) == (interval == 0), "recording off allocates no recorder and opens no file")
	var observations := {offset + 1: [[level.player.position, 0.0, 0]]}
	while level.session_runs < 6:
		var ordinal: int = offset + level.session_runs + 1
		await physics_frame
		level._physics_process(DT)
		if level.player.tick == 0:
			observations[ordinal] = [[level.player.position, 0.0, 0]]
		else:
			observations[ordinal].append([level.player.position, level.reward, level._held_action_id | (8 if level.agent.exploring else 0)])
	check(level.recording_error.is_empty(), "all episode writes succeed")
	var fingerprint := var_to_bytes([level.agent.q_table, level.agent.rng.state, level.agent.updates, level.agent.epsilon, level.agent.training_wins]).hex_encode().sha256_text()
	if trails:
		check(level.path_trails.history.size() == 6 and level.path_trails.current.is_empty(), "completed paths persist separately from the current path")
		for i in 60:
			level.path_trails.begin_episode(Vector2.ZERO)
			level.path_trails.sample(Vector2(10, 0))
			level.path_trails.sample(Vector2(20, 0))
			check(level.path_trails.current.size() == 2, "straight trail sections are simplified")
			level.path_trails.finish_episode("success")
		check(level.path_trails.history.size() == 50, "trail history is bounded")
	# Restarting/closing a partial episode must not serialize it or connect paths.
	level.reset_episode()
	for i in 3:
		await physics_frame
		level._physics_process(DT)
	level.reset_episode()
	if trails:
		check(level.path_trails.current == PackedVector2Array([level.player.position]), "restart drops the unfinished path")
	var path: String = level.recording_path
	level.queue_free()
	await process_frame
	if interval > 0:
		verify_file(path, observations, interval, offset)
	else:
		check(not FileAccess.file_exists(path), "recording off creates no file")
	return {"fingerprint": fingerprint}


func run_check() -> void:
	scratch = DirAccess.create_temp("ml-platformer-recording")
	if scratch == null:
		quit(1)
		return
	directory = scratch.get_current_dir()
	var baseline := await sample_run(0, false)
	check(await sample_run(1, false) == baseline, "recording every episode preserves learning and RNG state")
	check(await sample_run(2, true, 1) == baseline, "sampled recording and visible trails preserve learning and RNG state")
	var path := directory.path_join("sample-1-false.mlpaths")
	var hash_before := FileAccess.get_sha256(path)
	var recorder := Recorder.new()
	check(not recorder.open(path, {}), "an existing recording cannot be overwritten")
	check(FileAccess.get_sha256(path) == hash_before, "existing recording remains intact")
	check(not recorder.open(path.path_join("invalid.mlpaths"), {}), "unwritable recording destinations report failure")
	scratch = null
	if not failed:
		print("Episode recording check passed")
	quit(1 if failed else 0)
