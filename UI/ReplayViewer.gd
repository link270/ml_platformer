extends Node2D

const Recording := preload("res://Training/EpisodeRecording.gd")
const Recorder := preload("res://Training/EpisodeRecorder.gd")
const Trails := preload("res://Game/PathTrails.gd")
const HeatMap := preload("res://Game/PathHeatMap.gd")
const Levels := preload("res://Game/Levels/LevelCatalog.gd")
const CourseBackground := preload("res://Game/CourseBackground.gd")
const SPEEDS := [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

var recording_directory := Recorder.DIRECTORY
var recordings: Array[RefCounted] = []
var playlist: Array[Dictionary] = []
var active: Array[Dictionary] = []
var completed := 0
var available_episodes := 0
var paused := false
var finished := false
var playback_error := ""
var _next := 0
var _group_time := 0.0
var _group_duration := 0.0
var _polygon := PackedVector2Array()
var history: Node2D
var heat_map: Node2D
var course_bounds := Rect2(0, 0, 960, 540)
var course_camera: Camera2D
var course_background: Node2D


func _ready() -> void:
	course_background = CourseBackground.new()
	add_child(course_background)
	_build_course()
	course_camera = Camera2D.new()
	add_child(course_camera)
	_update_camera()
	heat_map = HeatMap.new()
	heat_map.bounds = course_bounds
	$HeatMapLayer.add_child(heat_map)
	%HeatMapControls.bind_heat_map(heat_map)
	history = Trails.new()
	$CompletedTrails.add_child(history)
	%PlaybackMode.add_item("Sequential")
	%PlaybackMode.add_item("Simultaneous groups")
	for speed in SPEEDS:
		%PlaybackSpeed.add_item(str(speed) + "x")
	%PlaybackSpeed.select(2)
	%OpenRecordings.pressed.connect(_browse)
	%RecordingFiles.files_selected.connect(load_recordings)
	%PlaybackMode.item_selected.connect(_restart.unbind(1))
	%ShowEvery.value_changed.connect(_restart.unbind(1))
	%BotCount.value_changed.connect(_restart.unbind(1))
	%PausePlayback.toggled.connect(_pause)
	%RestartPlayback.pressed.connect(_restart)
	%MenuButton.pressed.connect(_menu)
	%PlaybackTrails.toggled.connect(_show_trails)
	_update_status()


func _build_course(scene_path: String = "res://Game/Level.tscn") -> void:
	# Copy visuals before the level enters the tree: no agents, raycasts or bodies
	# are instantiated into the playback world, and the level script never runs.
	for child in $Course.get_children():
		child.free()
	var template := (load(scene_path) as PackedScene).instantiate()
	course_bounds = template.world_bounds
	course_background.bounds = course_bounds
	course_background.queue_redraw()
	_polygon = template.get_node("Player/Visual").polygon
	for child in template.get_children():
		if child is StaticBody2D or child.name == "Orb":
			var visual := child.get_node("Visual").duplicate() as Polygon2D
			visual.transform = child.transform * visual.transform
			$Course.add_child(visual)
	template.free()


func _browse() -> void:
	_pause(true)
	%PausePlayback.set_pressed_no_signal(true)
	%RecordingFiles.current_dir = ProjectSettings.globalize_path(recording_directory) if DirAccess.dir_exists_absolute(recording_directory) else OS.get_user_data_dir()
	%RecordingFiles.popup_centered_ratio(0.8)


func load_recordings(paths: PackedStringArray) -> bool:
	_clear_active()
	for recording in recordings:
		recording.close()
	recordings.clear()
	playlist.clear()
	history.clear()
	playback_error = ""
	%SourceName.text = "Recorded episode playback"
	%SourceName.tooltip_text = ""
	%PlaybackWarning.text = ""
	if paths.is_empty():
		playback_error = "Select at least one recording."
		_restart()
		return false
	var warnings: Array[String] = []
	var selected_course := ""
	for path in paths:
		var recording := Recording.new()
		if not recording.open(path):
			playback_error = path.get_file() + ": " + recording.error
			for opened in recordings:
				opened.close()
			recordings.clear()
			_restart()
			return false
		recordings.append(recording)
		var course := str(recording.header.get("level_scene", "res://Game/Level.tscn"))
		if not Levels.PATHS.has(course) or (not selected_course.is_empty() and course != selected_course):
			playback_error = "Choose recordings from one supported level at a time."
			for opened in recordings:
				opened.close()
			recordings.clear()
			_restart()
			return false
		selected_course = course
		if not recording.warning.is_empty() and not warnings.has(recording.warning):
			warnings.append(recording.warning)
		var sources: Dictionary = recording.header.get("source_sha256", {})
		var changed := false
		for source in [course, "res://Game/Levels/CourseBase.tscn"]:
			if sources.has(source) and sources[source] != FileAccess.get_sha256(source):
				changed = true
		if changed:
			var message := "Course changed since recording; displaying the current course."
			if not warnings.has(message):
				warnings.append(message)
	recordings.sort_custom(func(a: RefCounted, b: RefCounted) -> bool:
		var a_time := str(a.header.get("created_at", ""))
		var b_time := str(b.header.get("created_at", ""))
		if a_time != b_time:
			return a_time < b_time
		var a_offset := int(a.header.get("episode_offset", 0))
		var b_offset := int(b.header.get("episode_offset", 0))
		return a_offset < b_offset if a_offset != b_offset else a.path.naturalnocasecmp_to(b.path) < 0
	)
	%SourceName.text = paths[0].get_file() if paths.size() == 1 else "%d recordings" % paths.size()
	%SourceName.tooltip_text = "\n".join(paths)
	%PlaybackWarning.text = "\n".join(warnings)
	_build_course(selected_course)
	heat_map.bounds = course_bounds
	_restart()
	return true


func _restart() -> void:
	_clear_active()
	history.clear()
	heat_map.clear()
	playlist.clear()
	completed = 0
	_next = 0
	paused = false
	finished = false
	%PausePlayback.set_pressed_no_signal(false)
	%PausePlayback.text = "Pause"
	%BotCount.editable = %PlaybackMode.selected == 1
	var available := 0
	var interval := int(%ShowEvery.value)
	for recording in recordings:
		for i in recording.episodes.size():
			available += 1
			if available % interval == 0:
				playlist.append({"recording": recording, "index": i})
	available_episodes = available
	if not playlist.is_empty() and playback_error.is_empty():
		_spawn_group()
	_update_status()


func _spawn_group() -> void:
	_group_time = 0.0
	_group_duration = 0.0
	var count := 1 if %PlaybackMode.selected == 0 else int(%BotCount.value)
	for i in mini(count, playlist.size() - _next):
		var item := playlist[_next]
		var recording: RefCounted = item.recording
		var points: PackedVector2Array = recording.positions(item.index)
		if points.is_empty():
			playback_error = recording.error
			_clear_active()
			return
		var metadata: Dictionary = recording.episodes[item.index].metadata
		heat_map.begin_episode(_next, points[0])
		var color := Trails.ACTIVE_COLOR if count == 1 else Color.from_hsv(fmod(_next * 0.618034, 1.0), 0.55, 1.0, 0.8)
		var trail := Trails.new()
		trail.active_color = color
		$ActiveTrails.add_child(trail)
		trail.begin_episode(points[0])
		var visual := Polygon2D.new()
		visual.polygon = _polygon
		visual.color = color
		visual.position = points[0]
		$Ghosts.add_child(visual)
		var label := Label.new()
		label.text = "Ep %d" % metadata.episode
		label.position = Vector2(-16, -34)
		label.add_theme_font_size_override("font_size", 12)
		label.modulate = color
		visual.add_child(label)
		var hz := float(recording.header.physics_hz)
		var duration := (points.size() - 1) / hz
		_group_duration = maxf(_group_duration, duration)
		active.append({"points": points, "hz": hz, "duration": duration, "tick": 0, "heat_id": _next,
			"metadata": metadata, "trail": trail, "visual": visual})
		_next += 1
	_update_camera()


func _update_camera() -> void:
	var viewport_size := get_viewport_rect().size
	var zoom_factor := minf(1.0, viewport_size.x / course_bounds.size.x) if %PlaybackMode.selected == 1 else 1.0
	course_camera.zoom = Vector2.ONE * zoom_factor
	var center := course_bounds.get_center()
	if not active.is_empty() and zoom_factor == 1.0:
		var half_width := viewport_size.x * 0.5
		center.x = clampf(active[0].visual.position.x, course_bounds.position.x + half_width, maxf(course_bounds.end.x - half_width, course_bounds.position.x + half_width))
	course_camera.position = center


func _process(delta: float) -> void:
	advance(delta)


func advance(delta: float) -> void:
	if paused or finished or not playback_error.is_empty() or active.is_empty():
		return
	var remaining: float = maxf(delta, 0.0) * SPEEDS[%PlaybackSpeed.selected]
	while remaining > 0.0 and not active.is_empty():
		var step := minf(remaining, maxf(0.0, _group_duration - _group_time))
		_group_time += step
		remaining -= step
		for i in range(active.size() - 1, -1, -1):
			var ghost := active[i]
			var points: PackedVector2Array = ghost.points
			var complete: bool = _group_time + 0.000001 >= ghost.duration
			var tick: float = points.size() - 1 if complete else minf(_group_time * ghost.hz, points.size() - 1)
			var whole := mini(int(floor(tick + 0.000001)), points.size() - 1)
			for sample in range(ghost.tick + 1, whole + 1):
				ghost.trail.sample(points[sample], sample == points.size() - 1)
				heat_map.sample(ghost.heat_id, points[sample])
			ghost.tick = whole
			ghost.visual.position = points[whole].lerp(points[mini(whole + 1, points.size() - 1)], clampf(tick - whole, 0.0, 1.0))
			if complete:
				heat_map.finish_episode(ghost.heat_id)
				history.remember(ghost.trail.current, ghost.metadata.outcome)
				ghost.trail.free()
				ghost.visual.free()
				active.remove_at(i)
				completed += 1
		if active.is_empty():
			if _next < playlist.size():
				_spawn_group()
			else:
				finished = true
	_update_camera()
	_update_status()


func _clear_active() -> void:
	for ghost in active:
		heat_map.abort_episode(ghost.heat_id)
		ghost.trail.free()
		ghost.visual.free()
	active.clear()


func _pause(value: bool) -> void:
	paused = value
	%PausePlayback.text = "Resume" if paused else "Pause"
	_update_status()


func _show_trails(value: bool) -> void:
	$ActiveTrails.visible = value
	$CompletedTrails.visible = value


func _update_status() -> void:
	%PausePlayback.disabled = playlist.is_empty() or finished or not playback_error.is_empty()
	%RestartPlayback.disabled = playlist.is_empty() or not playback_error.is_empty()
	if not playback_error.is_empty():
		%PlaybackStatus.text = "Cannot play: " + playback_error
	elif recordings.is_empty():
		%PlaybackStatus.text = "Open one or more .mlpaths files.\nPosition playback · no physics or training."
	elif playlist.is_empty():
		%PlaybackStatus.text = "No complete saved episodes in these files." if available_episodes == 0 else "No saved episodes match this interval.\nReduce Show every, or open another recording."
	else:
		var text := "%s · %d / %d played\n%d ghosts active · %.2f s" % ["Finished" if finished else ("Paused" if paused else "Playback"), completed, playlist.size(), active.size(), _group_time]
		if active.size() == 1:
			text += "\nEpisode %d · %s" % [active[0].metadata.episode, "training" if active[0].metadata.training else "evaluation"]
		%PlaybackStatus.text = text


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_menu()
	elif event.is_action_pressed("reset"):
		_restart()
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_SPACE:
		if not %PausePlayback.disabled:
			%PausePlayback.button_pressed = not paused
		get_viewport().set_input_as_handled()


func _menu() -> void:
	get_tree().change_scene_to_file("res://UI/MainMenu.tscn")


func _exit_tree() -> void:
	for recording in recordings:
		recording.close()
