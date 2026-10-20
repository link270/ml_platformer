extends RefCounted

# Source rays are clockwise from up. This is the order shown in the HUD.
const RAY_INDICES := [6, 2, 0, 4, 5, 3]
const RAY_NAMES := ["L", "R", "U", "D", "DL", "DR"]
const NEAR_DISTANCE := 1.0
const ALIGN_TOLERANCE := 0.5
const MAX_STATES := 1728 # 2^6 rays * 3 horizontal * 3 vertical * 3 motion.


static func ray_bits(state: Dictionary, horizontal_bins: bool = false) -> String:
	var bits := ""
	for index in RAY_INDICES:
		if horizontal_bins and index in [6, 2] and state.ray_hits[index] and state.ray_clearances[index] > NEAR_DISTANCE:
			bits += "2" # Far hit within the existing two-block ray.
		else:
			bits += "1" if state.ray_hits[index] and state.ray_clearances[index] <= NEAR_DISTANCE else "0"
	return bits


static func direction(offset: float) -> int:
	if absf(offset) <= ALIGN_TOLERANCE:
		return 0
	return -1 if offset < 0.0 else 1


static func motion(state: Dictionary) -> int:
	if state.grounded:
		return 0
	return 1 if state.velocity.y < 0.0 else 2


static func encode(state: Dictionary, horizontal_bins: bool = false) -> String:
	return "%s|%d|%d|%d" % [ray_bits(state, horizontal_bins), direction(state.orb_offset.x), direction(state.orb_offset.y), motion(state)]


static func describe(state: Dictionary) -> String:
	var horizontal: String = ["left", "aligned", "right"][direction(state.orb_offset.x) + 1]
	var vertical: String = ["above", "aligned", "below"][direction(state.orb_offset.y) + 1]
	var phase: String = ["grounded", "rising", "falling"][motion(state)]
	return "Orb: %s / %s   |   Motion: %s" % [horizontal, vertical, phase]
