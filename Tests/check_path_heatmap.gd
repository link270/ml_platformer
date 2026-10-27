extends SceneTree

const HeatMap := preload("res://Game/PathHeatMap.gd")
const LevelScene := preload("res://Game/Level.tscn")
const Viewer := preload("res://UI/ReplayViewer.tscn")
const DT := 1.0 / 60.0
var failed := false
var scratch: DirAccess


func _initialize() -> void:
	call_deferred("run_check")


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func check_counts() -> void:
	var heat := HeatMap.new()
	root.add_child(heat)
	heat.begin_episode(1, Vector2(8, 8))
	for i in 100:
		heat.sample(1, Vector2(9, 9))
	check(heat.counts[Vector2i.ZERO] == 1 and heat.frequency(Vector2i.ZERO) == 1.0, "standing still counts once per episode")
	heat.sample(1, Vector2(20, 8))
	heat.sample(1, Vector2(8, 8))
	check(heat.counts.size() == 2 and heat.counts[Vector2i.ZERO] == 1, "revisiting a cell within an episode adds no extra heat")
	heat.finish_episode(1)
	heat.finish_episode(1)
	check(heat.completed_episodes == 1 and heat.active_episodes.is_empty(), "finishing commits exactly one episode")
	heat.begin_episode(2, Vector2(8, 8))
	check(heat.frequency(Vector2i.ZERO) == 1.0 and heat.frequency(Vector2i(1, 0)) == 0.5, "frequencies include completed episodes and active paths so far")
	heat.begin_episode(3, Vector2(40, 8))
	check(heat.episode_count() == 3 and is_equal_approx(heat.frequency(Vector2i.ZERO), 2.0 / 3.0), "concurrent ghosts each contribute a separate visit")
	heat.abort_episode(2)
	check(heat.counts[Vector2i.ZERO] == 1 and heat.episode_count() == 2, "aborting removes only the unfinished episode's contribution")
	heat.begin_episode(3, Vector2(60, 8))
	check(not heat.counts.has(Vector2i(2, 0)) and heat.counts.has(Vector2i(3, 0)), "restarting an active ID discards its earlier cells")
	var previous := heat.counts.duplicate()
	for point in [Vector2(-1, 0), Vector2(960, 8), Vector2(8, 540), Vector2(INF, 0), Vector2(NAN, 0)]:
		heat.sample(3, point)
	check(heat.counts == previous, "offscreen and non-finite positions cannot grow the grid")
	heat.abort_episode(3)
	check(heat.episode_count() == 1 and heat.counts.size() == 2, "completed heat survives partial restarts")
	heat.clear()
	check(heat.counts.is_empty() and heat.episode_count() == 0 and heat.frequency(Vector2i.ZERO) == 0.0, "clear resets both accumulated and active heat safely")
	for i in 200:
		heat.begin_episode(i, Vector2(8, 8))
		heat.finish_episode(i)
	check(heat.completed_episodes == 200 and heat.counts.size() == 1, "heat keeps aggregate counts instead of storing episode paths")
	heat.free()


func train(headless: bool, record_path: String = "") -> Dictionary:
	var level := LevelScene.instantiate()
	level.control_mode = level.ControlMode.Q_LEARNING
	level.agent = level.QLearningAgent.new()
	level.agent.rng.seed = 12345
	level.headless_training = headless
	level.episode_limit_seconds = 1.2
	level.record_every = 0 if record_path.is_empty() else 1
	level.recording_path = record_path
	root.add_child(level)
	level.set_physics_process(false)
	if headless:
		check(level.heat_map == null, "headless training allocates no heat-map grid")
	else:
		check(not level.heat_map.visible and level.path_trails == null, "heat is collected independently of trails, and its display defaults off")
		level.get_node("%HeatMapControls").get_node("%ShowHeatMap").button_pressed = true
		check(level.heat_map.visible, "live HUD toggle enables the heat overlay")
	while level.session_runs < 6:
		await physics_frame
		level._physics_process(DT)
	var result := {"behavior": var_to_bytes([level.agent.q_table, level.agent.rng.state, level.agent.updates, level.agent.epsilon]).hex_encode().sha256_text()}
	if not headless:
		result.counts = level.heat_map.counts.duplicate()
		check(level.heat_map.completed_episodes == 6 and level.heat_map.active_episodes.is_empty(), "live completed count follows actual episode boundaries")
		level.reset_episode()
		level.heat_map.sample(0, Vector2(900, 100))
		level.reset_episode()
		check(not level.heat_map.counts.has(Vector2i(56, 6)), "manual restart removes heat from abandoned cells")
		level._toggle_evaluation()
		check(level.heat_map.completed_episodes == 0 and level.heat_map.active_episodes.size() == 1, "switching training/evaluation resets the heat population")
	level.queue_free()
	await process_frame
	return result


func run_check() -> void:
	check_counts()
	scratch = DirAccess.create_temp("ml-platformer-heatmap")
	if scratch == null:
		quit(1)
		return
	var path := scratch.get_current_dir().path_join("live.mlpaths")
	var baseline := await train(true)
	var live := await train(false, path)
	check(live.behavior == baseline.behavior, "heat collection leaves learning and random-number state unchanged")
	var source_hash := FileAccess.get_sha256(path)
	var viewer := Viewer.instantiate()
	root.add_child(viewer)
	viewer.set_process(false)
	check(viewer.load_recordings(PackedStringArray([path])), "live recording opens in playback")
	viewer.get_node("%PlaybackTrails").button_pressed = false
	viewer.get_node("%HeatMapControls").get_node("%ShowHeatMap").button_pressed = true
	check(viewer.heat_map.visible and not viewer.get_node("ActiveTrails").visible, "playback heat and persistent paths have independent toggles")
	viewer.advance(100.0)
	check(viewer.finished and viewer.heat_map.completed_episodes == 6, "sequential replay counts played episodes")
	check(viewer.heat_map.counts == live.counts, "recorded replay produces the exact same heat grid as live training")
	viewer.get_node("%PlaybackMode").select(1)
	viewer.get_node("%PlaybackMode").item_selected.emit(1)
	check(viewer.heat_map.completed_episodes == 0 and viewer.heat_map.active_episodes.size() == 6, "restart clears accumulated heat and starts each concurrent ghost separately")
	var counts_before: Dictionary = viewer.heat_map.counts.duplicate()
	viewer.get_node("%PausePlayback").button_pressed = true
	viewer.advance(100.0)
	check(viewer.heat_map.counts == counts_before and viewer.heat_map.completed_episodes == 0, "paused playback accumulates no extra heat")
	viewer.get_node("%PausePlayback").button_pressed = false
	viewer.get_node("%PlaybackSpeed").select(5)
	viewer.advance(100.0)
	check(viewer.heat_map.counts == live.counts, "simultaneous high-speed playback yields the same frequency grid")
	viewer.get_node("%ShowEvery").value = 2
	viewer.advance(100.0)
	check(viewer.heat_map.completed_episodes == 3, "the playback interval limits heat to selected episodes")
	var expected := HeatMap.new()
	for item in viewer.playlist:
		var positions: PackedVector2Array = item.recording.positions(item.index)
		expected.begin_episode(item.index, positions[0])
		for point in positions:
			expected.sample(item.index, point)
		expected.finish_episode(item.index)
	check(viewer.heat_map.counts == expected.counts, "skipped episodes contribute no cells")
	expected.free()
	check(FileAccess.get_sha256(path) == source_hash, "heat playback leaves the source recording unchanged")
	viewer.free()
	scratch = null
	if not failed:
		print("Path heat-map check passed")
	quit(1 if failed else 0)
