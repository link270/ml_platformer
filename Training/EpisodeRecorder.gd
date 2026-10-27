extends RefCounted

# Little-endian stream: magic, JSON header length/header, then complete episodes.
# Each episode: JSON length, sample count, JSON metadata, sample bytes.
# Each 13-byte sample: float32 x/y (level-local pixels), float32 reward,
# uint8 flags (bits 0–2 action ID, bit 3 exploratory action). Sample 0 is spawn.
const MAGIC := "MLPATH01"
const SAMPLE_BYTES := 13
const DIRECTORY := "user://recordings"

var path := ""
var error := ""
var recorded_episodes := 0
var recorded_samples := 0
var bytes_written := 0
var _file: FileAccess
var _samples := PackedByteArray()
var _sample_count := 0
var _metadata: Dictionary = {}


static func new_path(directory: String = DIRECTORY) -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	return directory.path_join("episodes_%s_%d_%d.mlpaths" % [stamp, OS.get_process_id(), Time.get_ticks_usec()])


func open(destination: String, metadata: Dictionary) -> bool:
	path = destination
	if FileAccess.file_exists(path):
		error = "Recording already exists: " + path
		return false
	var result := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if result != OK:
		error = "Cannot create recordings folder: " + error_string(result)
		return false
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		error = "Cannot open recording: " + error_string(FileAccess.get_open_error())
		return false
	var header := metadata.duplicate()
	header.format_version = 1
	header.sample_bytes = SAMPLE_BYTES
	header.coordinates = "level-local pixels"
	header.created_at = Time.get_datetime_string_from_system(true)
	var json := JSON.stringify(header).to_utf8_buffer()
	_file.store_buffer(MAGIC.to_ascii_buffer())
	_file.store_32(json.size())
	_file.store_buffer(json)
	_file.flush()
	return _check_write()


func begin_episode(metadata: Dictionary, position: Vector2, maximum_ticks: int) -> void:
	_metadata = metadata
	_sample_count = 0
	_samples.resize((maximum_ticks + 1) * SAMPLE_BYTES)
	sample(position, 0, false, 0.0)


func sample(position: Vector2, action: int, exploring: bool, reward: float) -> void:
	var offset := _sample_count * SAMPLE_BYTES
	if offset + SAMPLE_BYTES > _samples.size():
		_samples.resize(maxi(offset + SAMPLE_BYTES, _samples.size() * 2))
	_samples.encode_float(offset, position.x)
	_samples.encode_float(offset + 4, position.y)
	_samples.encode_float(offset + 8, reward)
	_samples[offset + 12] = action | (8 if exploring else 0)
	_sample_count += 1


func finish_episode(outcome: String, total_reward: float) -> bool:
	_metadata.outcome = outcome
	_metadata.episode_return = total_reward
	_metadata.ticks = _sample_count - 1
	var json := JSON.stringify(_metadata).to_utf8_buffer()
	_file.store_32(json.size())
	_file.store_32(_sample_count)
	_file.store_buffer(json)
	_samples.resize(_sample_count * SAMPLE_BYTES)
	_file.store_buffer(_samples)
	# Only complete episodes reach disk. Earlier episodes survive an interrupted run.
	_file.flush()
	if not _check_write():
		return false
	recorded_episodes += 1
	recorded_samples += _sample_count
	return true


func _check_write() -> bool:
	var result := _file.get_error()
	bytes_written = _file.get_position()
	if result != OK:
		error = "Cannot write recording: " + error_string(result)
		return false
	return true


func close() -> void:
	if _file != null:
		_file.close()
		_file = null
	_samples = PackedByteArray()
