extends SceneTree

const Recorder := preload("res://Training/EpisodeRecorder.gd")
const Recording := preload("res://Training/EpisodeRecording.gd")
const Viewer := preload("res://UI/ReplayViewer.tscn")
var failed := false
var scratch: DirAccess
var directory := ""


func _initialize() -> void:
	call_deferred("run_check")


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func fixture(name: String, offset: int, episodes: int, hz: int = 2) -> String:
	var path := directory.path_join(name + ".mlpaths")
	var recorder := Recorder.new()
	check(recorder.open(path, {"physics_hz": hz, "episode_offset": offset}), "fixture opens")
	for i in episodes:
		recorder.begin_episode({"episode": offset + i + 1, "training": true}, Vector2(80, 464), 2)
		recorder.sample(Vector2(100, 440), 5, true, 0.1)
		recorder.sample(Vector2(120, 464), 1, false, -1.0)
		check(recorder.finish_episode("death", -0.9), "fixture writes")
	recorder.close()
	return path


func no_simulation(node: Node) -> bool:
	if node is CollisionObject2D or node is RayCast2D:
		return false
	for child in node.get_children():
		if not no_simulation(child):
			return false
	return true


func run_check() -> void:
	scratch = DirAccess.create_temp("ml-platformer-playback")
	if scratch == null:
		quit(1)
		return
	directory = scratch.get_current_dir()
	var first := fixture("first", 0, 4)
	var second := fixture("second", 4, 2, 4)
	var original_hash := FileAccess.get_sha256(first)
	var reader := Recording.new()
	check(reader.open(first) and reader.episodes.size() == 4, "reader indexes all complete episodes")
	check(not reader.episodes[0].has("points"), "index keeps offsets instead of all position arrays")
	check(reader.positions(2) == PackedVector2Array([Vector2(80, 464), Vector2(100, 440), Vector2(120, 464)]), "reader decodes positions exactly")
	reader.close()
	var bad_samples := directory.path_join("bad-samples.mlpaths")
	var invalid_bytes := FileAccess.get_file_as_bytes(first)
	check(reader.open(first), "valid recording reopens for corruption fixture")
	invalid_bytes.encode_float(reader.episodes[0].offset, INF)
	reader.close()
	var invalid_file := FileAccess.open(bad_samples, FileAccess.WRITE)
	invalid_file.store_buffer(invalid_bytes)
	invalid_file.close()
	check(reader.open(bad_samples) and reader.positions(0).is_empty() and not reader.error.is_empty(), "non-finite recorded positions cannot reach the renderer")
	reader.close()
	var viewer := Viewer.instantiate()
	viewer.recording_directory = directory
	root.add_child(viewer)
	current_scene = viewer
	viewer.set_process(false)
	check(no_simulation(viewer), "playback world has no physics bodies, sensors, or simulated player")
	check(viewer.load_recordings(PackedStringArray([second, first])), "viewer loads multiple recording chunks")
	check(viewer.playlist.size() == 6 and viewer.active.size() == 1, "sequential playback loads only one ghost")
	check(viewer.active[0].metadata.episode == 1, "chunks are sorted by their recorded offset")
	viewer.advance(0.25)
	check(viewer.active[0].visual.position.is_equal_approx(Vector2(90, 452)), "ghost interpolates recorded positions using the file tick rate")
	viewer.get_node("%PausePlayback").button_pressed = true
	viewer.advance(5.0)
	check(viewer.active[0].visual.position.is_equal_approx(Vector2(90, 452)), "pause freezes playback")
	check(viewer.get_node("%PlaybackStatus").text.begins_with("Paused"), "paused status is visible")
	viewer.get_node("%PausePlayback").button_pressed = false
	viewer.advance(1.0)
	check(viewer.completed == 1 and viewer.active[0].metadata.episode == 2, "sequential playback advances to the next recorded episode")
	check(viewer.active[0].visual.position.is_equal_approx(Vector2(90, 452)), "frame remainder carries into the next episode")
	check(viewer.history.history.size() == 1 and viewer.history.history[0].points[-1] == Vector2(120, 464), "terminal path persists at the recorded endpoint")
	viewer.advance(10.0)
	check(viewer.finished and viewer.completed == 6 and viewer.active.is_empty(), "all selected recordings complete exactly once, including mixed tick rates")
	check(viewer.history.history.size() == 6, "sequential history survives across recording files")
	viewer.get_node("%ShowEvery").value = 2
	check(viewer.playlist.size() == 3 and viewer.active[0].metadata.episode == 2, "every X filters saved episodes, starting at X")
	viewer.get_node("%PlaybackMode").select(1)
	viewer.get_node("%PlaybackMode").item_selected.emit(1)
	viewer.get_node("%BotCount").value = 2
	check(viewer.active.size() == 2 and viewer.active[1].metadata.episode == 4, "simultaneous group spawns selected episodes together")
	viewer.advance(1.1)
	check(viewer.completed == 2 and viewer.active.size() == 1 and viewer.active[0].metadata.episode == 6, "next group starts after current group completes")
	check(viewer.history.history.size() == 2, "simultaneous completed paths share one persistent history")
	viewer.get_node("%PlaybackTrails").button_pressed = false
	check(not viewer.get_node("ActiveTrails").visible and viewer.get_node("Ghosts").visible, "hiding paths keeps ghosts visible")
	viewer.get_node("%ShowEvery").value = 1
	viewer.get_node("%BotCount").value = 20
	viewer.advance(0.6)
	check(viewer.completed == 2 and viewer.active.size() == 4, "shorter ghosts end independently without prematurely advancing the group")
	viewer.get_node("%RestartPlayback").pressed.emit()
	check(viewer.completed == 0 and viewer.history.history.is_empty() and viewer.active.size() == 6, "restart clears history and rewinds the playlist")
	viewer.get_node("%PlaybackSpeed").select(4)
	viewer.advance(0.25)
	check(viewer.finished and viewer.completed == 6, "playback speed scales recorded time")
	var large := fixture("large", 0, 120)
	viewer.get_node("%BotCount").value = 100
	check(viewer.load_recordings(PackedStringArray([large])) and viewer.active.size() == 100, "simultaneous playback loads at most the chosen group")
	viewer.advance(1.0)
	check(viewer.finished and viewer.completed == 120 and viewer.history.history.size() == 50, "long playback bounds history and handles a partial final group")
	check(FileAccess.get_sha256(first) == original_hash, "playback leaves source recordings unchanged")
	var truncated := directory.path_join("truncated.mlpaths")
	var bytes := FileAccess.get_file_as_bytes(first)
	bytes.resize(bytes.size() - 5)
	var file := FileAccess.open(truncated, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	check(reader.open(truncated) and reader.episodes.size() == 3 and not reader.warning.is_empty(), "truncated tail preserves earlier complete episodes with a warning")
	reader.close()
	var corrupt := directory.path_join("corrupt.mlpaths")
	file = FileAccess.open(corrupt, FileAccess.WRITE)
	file.store_string("not a recording")
	file.close()
	check(not viewer.load_recordings(PackedStringArray([corrupt])) and viewer.active.is_empty(), "malformed recording reports failure without spawning ghosts")
	check(not viewer.get_node("%PlaybackStatus").text.is_empty(), "recording failure is visible")
	check(viewer.load_recordings(PackedStringArray([first])), "valid recording recovers from an earlier load error")
	viewer.get_node("%ShowEvery").value = 999
	check(viewer.active.is_empty() and viewer.playlist.is_empty(), "filtering beyond the available episodes spawns no ghosts")
	viewer.queue_free()
	await process_frame
	var menu := preload("res://UI/MainMenu.tscn").instantiate()
	menu.recording_directory = directory
	root.add_child(menu)
	current_scene = menu
	menu.get_node("%PlaybackButton").pressed.emit()
	check(current_scene != menu and current_scene.recording_directory == directory, "setup opens playback with the recording folder")
	current_scene.queue_free()
	await process_frame
	scratch = null
	if not failed:
		print("Episode playback check passed")
	quit(1 if failed else 0)
