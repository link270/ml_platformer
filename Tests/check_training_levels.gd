extends SceneTree

const Levels := preload("res://Game/Levels/LevelCatalog.gd")
const DT := 1.0 / 60.0
var failed := false
var scratch: DirAccess


func _initialize() -> void:
	call_deferred("run_check")


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


# Read the authored geometry, independently of the route controller. Each entry
# is a contiguous top surface; missing columns are real pits, with no safety floor.
func surfaces(level: Node2D) -> Array[Rect2]:
	var tops := {}
	for child in level.get_children():
		if child is StaticBody2D:
			var column := floori(child.position.x / 32.0)
			tops[column] = minf(tops.get(column, INF), child.position.y - 16.0)
	var result: Array[Rect2] = []
	for column in 120:
		if not tops.has(column):
			continue
		var left := column * 32.0
		var top: float = tops[column]
		if not result.is_empty() and result[-1].end.x == left and result[-1].position.y == top:
			result[-1].size.x += 32.0
		else:
			result.append(Rect2(left, top, 32, 32))
	return result


func complete_course(id: String, takeoff_margin: float) -> void:
	var level := (load(Levels.scene_path(id)) as PackedScene).instantiate()
	level.control_mode = level.ControlMode.RANDOM
	level.headless_training = true
	root.add_child(level)
	level.set_physics_process(false)
	var route := surfaces(level)
	check(level.world_bounds.size.x >= 4.0 * 960.0, id + " is at least four screens wide")
	check(level.spawn.position.x == 80 and level.orb.position.x == 3760, id + " has opposite-end start and goal")
	check(level.player.get_node("Camera2D").limit_right == 3840, id + " camera covers the course")
	if id == "template":
		check(route.size() == 1 and route[0] == Rect2(0, 480, 3840, 32), "template has a complete block floor")
	var section := 0
	var action: int = level.Action.MOVE_RIGHT
	for tick in 3600:
		await physics_frame
		if tick % level.TICKS_PER_DECISION == 0:
			var player: CharacterBody2D = level.player
			while section + 1 < route.size() and player.is_on_floor() and player.position.x >= route[section + 1].position.x - 16.0 and absf(player.position.y + 16.0 - route[section + 1].position.y) < 1.0:
				section += 1
			action = level.Action.MOVE_RIGHT
			if section + 1 < route.size():
				var gap := route[section + 1].position.x - route[section].end.x
				var rise := route[section].position.y - route[section + 1].position.y
				if (gap > 0 or rise > 0) and player.is_on_floor() and player.position.x >= route[section].end.x - takeoff_margin:
					action = level.Action.MOVE_RIGHT_JUMP
		level.step(DT, action)
		if level.done:
			break
	check(level.done and level.orb_collected and level.deaths == 0 and not level.timed_out,
		"%s completes with real collisions and six-tick actions (takeoff %.0f; position %s)" % [id, takeoff_margin, level.player.position])
	print("%s · takeoff %.0f px · %.2f s · success=%s" % [id, takeoff_margin, level.player.tick * DT, level.orb_collected])
	level.queue_free()
	await process_frame


func run_check() -> void:
	for id in ["template", "easy", "medium", "hard"]:
		# Vary launch timing over a 12-pixel window, in addition to the 19.2-pixel
		# decision interval, to guard against a single pixel-perfect winning route.
		for margin in [36.0, 42.0, 48.0]:
			await complete_course(id, margin)
	await check_integration()
	if not failed:
		print("Training level completion check passed")
	quit(1 if failed else 0)


func check_integration() -> void:
	scratch = DirAccess.create_temp("ml-platformer-courses")
	check(scratch != null, "integration scratch directory opens")
	if scratch == null:
		return
	var directory := scratch.get_current_dir()
	for id in ["template", "easy", "medium", "hard"]:
		var menu := preload("res://UI/MainMenu.tscn").instantiate()
		menu.checkpoint_directory = directory
		menu.checkpoint_path = directory.path_join("unused.json")
		root.add_child(menu)
		current_scene = menu
		var index := Levels.IDS.find(id)
		menu.get_node("%LevelSelect").select(index)
		menu.get_node("%LevelSelect").item_selected.emit(index)
		menu.get_node("%ControllerSelect").select(1)
		menu.get_node("%ControllerSelect").item_selected.emit(1)
		menu.get_node("%BatchStart").pressed.emit()
		var level := current_scene
		level.set_physics_process(false)
		check(level.scene_file_path == Levels.scene_path(id), "menu starts " + id)
		check(level.heat_map.bounds == level.world_bounds, "heat map covers all four screens")
		level.heat_map.begin_episode(99, Vector2(3760, 464))
		check(not level.heat_map.counts.is_empty(), "heat map samples the far end")
		level.queue_free()
		await process_frame

	# The real worker must instantiate the selected course and stamp its recording.
	var recording_path := directory.path_join("hard.mlpaths")
	var output: Array = []
	var exit_code := OS.execute(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--fixed-fps", "60", "--disable-render-loop", "--script", "res://Training/train.gd", "--",
		"--level", "hard", "--agent", "random", "--mode", "evaluation", "--episodes", "2",
		"--record-every", "1", "--record-to", recording_path,
	]), output, true)
	check(exit_code == 0, "headless hard-course worker exits successfully: " + str(output))
	var recording := preload("res://Training/EpisodeRecording.gd").new()
	check(recording.open(recording_path), "worker recording opens")
	check(recording.header.get("level_scene") == Levels.scene_path("hard") and recording.episodes.size() == 2, "worker records the selected level for both episodes")
	recording.close()
	var viewer := preload("res://UI/ReplayViewer.tscn").instantiate()
	root.add_child(viewer)
	viewer.set_process(false)
	check(viewer.load_recordings(PackedStringArray([recording_path])), "hard-course replay opens")
	check(viewer.course_bounds.size.x == 3840 and viewer.heat_map.bounds == viewer.course_bounds, "replay uses large-course bounds")
	var course := (load(Levels.scene_path("hard")) as PackedScene).instantiate()
	var expected_visuals := 1
	for child in course.get_children():
		if child is StaticBody2D:
			expected_visuals += 1
	check(viewer.get_node("Course").get_child_count() == expected_visuals, "replay displays the authored hard course")
	course.free()
	viewer.active[0].visual.position.x = 3600
	viewer._update_camera()
	check(viewer.course_camera.position.x == 3360, "sequential replay follows the ghost to the far end")
	viewer.get_node("%PlaybackMode").select(1)
	viewer._update_camera()
	check(viewer.course_camera.zoom == Vector2(0.25, 0.25), "simultaneous replay fits the complete course")
	viewer.queue_free()
	await process_frame
	scratch = null
