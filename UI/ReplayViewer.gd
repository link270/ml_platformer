extends Node2D

const Recording := preload("res://Training/EpisodeRecording.gd")
const Recorder := preload("res://Training/EpisodeRecorder.gd")
const Trails := preload("res://Game/PathTrails.gd")
const LevelScene := preload("res://Game/Level.tscn")
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


func _ready() -> void:
	_build_course()
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


func _build_course() -> void:
	# Copy visuals before the level enters the tree: no agents, raycasts or bodies
	# are instantiated into the playback world, and the level script never runs.
	var template := LevelScene.instantiate()
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
		if not recording.warning.is_empty() and not warnings.has(recording.warning):
			warnings.append(recording.warning)
		var fingerprint: String = recording.header.get("source_sha256", {}).get("res://Game/Level.tscn", "")
		if not fingerprint.is_empty() and fingerprint != FileAccess.get_sha256("res://Game/Level.tscn"):
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
	_restart()
	return true


func _restart() -> void:
	_clear_active()
	history.clear()
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
		active.append({"points": points, "hz": hz, "duration": duration, "tick": 0,
			"metadata": metadata, "trail": trail, "visual": visual})
		_next += 1


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
			ghost.tick = whole
			ghost.visual.position = points[whole].lerp(points[mini(whole + 1, points.size() - 1)], clampf(tick - whole, 0.0, 1.0))
			if complete:
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
	_update_status()


func _clear_active() -> void:
	for ghost in active:
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
