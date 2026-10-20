extends RefCounted

const Agent := preload("res://Agents/Agent.gd")
const State := preload("res://Agents/QState.gd")
const Presets := preload("res://Agents/QPresets.gd")
const DEFAULT_PATH := "user://q_learning_checkpoint.json"
# Bump this if the encoding or checkpoint structure changes incompatibly.
const FORMAT_VERSION := 1
const SETTINGS := ["learning_rate", "discount", "epsilon", "epsilon_decay", "minimum_epsilon"]
const COUNTERS := ["updates", "training_episodes", "training_wins"]


static func _schema(preset_id: String = Presets.DEFAULT_ID) -> Dictionary:
	var schema := {"rays": State.RAY_INDICES, "near_distance": State.NEAR_DISTANCE,
		"orb_alignment": State.ALIGN_TOLERANCE, "motion": ["grounded", "rising", "falling"],
		"actions": Agent.ACTION_NAMES, "action_inputs": Agent.ACTION_INPUTS,
		"ticks_per_decision": Agent.TICKS_PER_DECISION}
	if preset_id == "horizontal_bins":
		schema.horizontal_bins = ["no_hit", "near_0_to_1", "far_1_to_2"]
	if preset_id == "late_learning_rate":
		schema.learning_schedule = "alpha_0.1_through_3000_linear_to_0.02_at_10000"
	# JSON reads all numbers as floats, including numbers inside arrays.
	return JSON.parse_string(JSON.stringify(schema))


# Empty string means success; otherwise return a message suitable for the UI.
static func save_checkpoint(agent: RefCounted, path: String = DEFAULT_PATH) -> String:
	var data := {"format_version": FORMAT_VERSION, "preset_id": agent.preset_id,
		"schema": _schema(agent.preset_id), "q_table": agent.q_table}
	for field in SETTINGS + COUNTERS:
		data[field] = agent.get(field)
	var error := _validate(data, agent.preset_id)
	if not error.is_empty():
		return "Cannot save: " + error
	# Write beside the destination, then replace it only after a complete write.
	var temporary_path := path + ".tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return "Cannot write checkpoint: " + error_string(FileAccess.get_open_error())
	file.store_string(JSON.stringify(data, "\t", true, true))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		return "Cannot write checkpoint: " + error_string(write_error)
	var rename_error := DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary_path), ProjectSettings.globalize_path(path))
	if rename_error != OK:
		return "Cannot replace checkpoint: " + error_string(rename_error)
	return ""


static func load_checkpoint(agent: RefCounted, path: String = DEFAULT_PATH) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "Cannot open checkpoint: " + error_string(FileAccess.get_open_error())
	if file.get_length() > 2_000_000:
		return "Checkpoint is too large."
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return "Checkpoint is not valid JSON."
	var error := _validate(json.data, agent.preset_id)
	if not error.is_empty():
		return error
	# Apply only after every row and setting has passed validation.
	agent.q_table = json.data.q_table
	for field in SETTINGS:
		agent.set(field, float(json.data[field]))
	for field in COUNTERS:
		agent.set(field, int(json.data[field]))
	agent.evaluation_episodes = 0
	agent.evaluation_wins = 0
	agent.exploring = false
	return ""


static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


static func _validate(data: Variant, preset_id: String = Presets.DEFAULT_ID) -> String:
	if not data is Dictionary:
		return "Checkpoint must contain an object."
	# Archived v1 tables predate preset IDs; their menu folder supplies the mode.
	if not Presets.PRESETS.has(preset_id) or data.get("preset_id", preset_id) != preset_id:
		return "Checkpoint belongs to a different experiment mode."
	if data.get("format_version") != FORMAT_VERSION or data.get("schema") != _schema(preset_id):
		return "Checkpoint uses a different state/action format."
	for field in SETTINGS:
		var value: Variant = data.get(field)
		if not _number(value) or value < 0.0 or value > 1.0:
			return "Invalid setting: " + field
	if data.learning_rate == 0.0 or data.epsilon_decay == 0.0 or data.minimum_epsilon > data.epsilon:
		return "Invalid learning or exploration settings."
	for field in COUNTERS:
		var value: Variant = data.get(field)
		if not _number(value) or value < 0 or value > 9007199254740991 or floorf(value) != value:
			return "Invalid counter: " + field
	if data.training_wins > data.training_episodes:
		return "Training wins exceed completed episodes."
	var table: Variant = data.get("q_table")
	var max_states := 3888 if preset_id == "horizontal_bins" else State.MAX_STATES
	if not table is Dictionary or table.size() > max_states:
		return "Invalid Q-table."
	var key_pattern := RegEx.new()
	var rays := "[012]{2}[01]{4}" if preset_id == "horizontal_bins" else "[01]{6}"
	key_pattern.compile("^" + rays + "\\|(-1|0|1)\\|(-1|0|1)\\|[012]\\z")
	for key in table:
		if not key is String or key_pattern.search(key) == null:
			return "Invalid Q-table state key."
		var row: Variant = table[key]
		if not row is Array or row.size() != Agent.ACTION_INPUTS.size():
			return "Each Q-table row must contain six action values."
		for score in row:
			if not _number(score):
				return "Q-table contains a non-finite or nonnumeric value."
	return ""
