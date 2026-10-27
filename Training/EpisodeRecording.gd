extends RefCounted

const Recorder := preload("res://Training/EpisodeRecorder.gd")
const MAX_JSON_BYTES := 1024 * 1024
const MAX_SAMPLES := 1_000_000
var path := ""
var header: Dictionary = {}
var episodes: Array[Dictionary] = []
var error := ""
var warning := ""
var _file: FileAccess


func open(source: String) -> bool:
	close()
	path = source
	header = {}
	episodes.clear()
	error = ""
	warning = ""
	_file = FileAccess.open(path, FileAccess.READ)
	if _file == null:
		return _fail("Cannot open recording: " + error_string(FileAccess.get_open_error()))
	if _file.get_length() < 12 or _file.get_buffer(8).get_string_from_ascii() != Recorder.MAGIC:
		return _fail("Not an episode recording (MLPATH01).")
	var length := _file.get_32()
	if length == 0 or length > MAX_JSON_BYTES or length > _remaining():
		return _fail("Invalid or incomplete recording header.")
	var data: Variant = JSON.parse_string(_file.get_buffer(length).get_string_from_utf8())
	if not data is Dictionary:
		return _fail("Invalid recording header JSON.")
	header = data
	var hz: Variant = header.get("physics_hz")
	if header.get("format_version") != 1 or header.get("sample_bytes") != Recorder.SAMPLE_BYTES:
		return _fail("Unsupported recording format.")
	if not _positive_integer(hz) or hz > 10000:
		return _fail("Invalid recording tick rate.")
	var offset: Variant = header.get("episode_offset", 0)
	if not (offset is float or offset is int) or not is_finite(float(offset)) or offset < 0 or offset != floor(offset):
		return _fail("Invalid recording episode offset.")
	var fingerprints: Variant = header.get("source_sha256", {})
	if not fingerprints is Dictionary:
		return _fail("Invalid recording source fingerprints.")
	for source_path in fingerprints:
		if not source_path is String or not fingerprints[source_path] is String:
			return _fail("Invalid recording source fingerprint.")
	while _remaining() > 0:
		if _remaining() < 8:
			warning = "Incomplete final episode ignored."
			break
		var json_length := _file.get_32()
		var count := _file.get_32()
		if json_length == 0 or json_length > MAX_JSON_BYTES or count < 1 or count > MAX_SAMPLES:
			return _fail("Invalid episode lengths.")
		if json_length + count * Recorder.SAMPLE_BYTES > _remaining():
			warning = "Incomplete final episode ignored."
			break
		var metadata: Variant = JSON.parse_string(_file.get_buffer(json_length).get_string_from_utf8())
		if not metadata is Dictionary:
			return _fail("Invalid episode metadata JSON.")
		if not _positive_integer(metadata.get("episode")) or metadata.get("ticks") != count - 1:
			return _fail("Invalid episode ordinal or tick count.")
		if metadata.get("outcome") not in ["success", "death", "timeout"] or not metadata.get("training") is bool:
			return _fail("Invalid episode outcome or mode.")
		episodes.append({"metadata": metadata, "offset": _file.get_position(), "sample_count": count})
		_file.seek(_file.get_position() + count * Recorder.SAMPLE_BYTES)
	return true


func positions(index: int) -> PackedVector2Array:
	if _file == null or index < 0 or index >= episodes.size():
		error = "Episode is unavailable."
		return PackedVector2Array()
	var episode := episodes[index]
	_file.seek(episode.offset)
	var bytes: PackedByteArray = _file.get_buffer(episode.sample_count * Recorder.SAMPLE_BYTES)
	if bytes.size() != episode.sample_count * Recorder.SAMPLE_BYTES:
		error = "Recording changed or was truncated during playback."
		return PackedVector2Array()
	var result := PackedVector2Array()
	result.resize(episode.sample_count)
	for i in result.size():
		var offset := i * Recorder.SAMPLE_BYTES
		var point := Vector2(bytes.decode_float(offset), bytes.decode_float(offset + 4))
		var reward := bytes.decode_float(offset + 8)
		var flags := bytes[offset + 12]
		if not point.is_finite() or not is_finite(reward) or flags > 15 or (flags & 7) > 5:
			error = "Invalid position, reward, or action in episode %s." % episode.metadata.episode
			return PackedVector2Array()
		result[i] = point
	return result


static func _positive_integer(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and value >= 1 and value == floor(value)


func _remaining() -> int:
	return _file.get_length() - _file.get_position()


func _fail(message: String) -> bool:
	error = message
	episodes.clear()
	close()
	return false


func close() -> void:
	if _file != null:
		_file.close()
		_file = null
