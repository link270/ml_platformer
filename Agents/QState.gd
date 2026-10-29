extends RefCounted

# Source rays are clockwise from up. This is the order shown in the HUD.
const RAY_INDICES := [6, 2, 0, 4, 5, 3]
const RAY_NAMES := ["L", "R", "U", "D", "DL", "DR"]
const NEAR_DISTANCE := 1.0
const ALIGN_TOLERANCE := 0.5
const MAX_STATES := 1728 # 2^6 rays * 3 horizontal * 3 vertical * 3 motion.
# Cache only derived key strings, never observations or Q-values. The binary
# and horizontal-bin schemas have disjoint IDs, bounded to 1,728 + 3,888 keys.
static var _encoded_keys: Dictionary = {}


static func ray_bits(state: Dictionary, horizontal_bins: bool = false) -> String:
	var bits := ""
	for index in RAY_INDICES:
		if horizontal_bins and (index == 6 or index == 2) and state.ray_hits[index] and state.ray_clearances[index] > NEAR_DISTANCE:
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
	var rays := 0
	for index in RAY_INDICES:
		var horizontal_ray: bool = horizontal_bins and (index == 6 or index == 2)
		var value := 0
		if horizontal_ray and state.ray_hits[index] and state.ray_clearances[index] > NEAR_DISTANCE:
			value = 2
		elif state.ray_hits[index] and state.ray_clearances[index] <= NEAR_DISTANCE:
			value = 1
		rays = rays * (3 if horizontal_ray else 2) + value
	var horizontal := direction(state.orb_offset.x)
	var vertical := direction(state.orb_offset.y)
	var phase := motion(state)
	var key_id := ((rays * 3 + horizontal + 1) * 3 + vertical + 1) * 3 + phase
	if horizontal_bins:
		key_id += MAX_STATES
	if not _encoded_keys.has(key_id):
		_encoded_keys[key_id] = "%s|%d|%d|%d" % [ray_bits(state, horizontal_bins), horizontal, vertical, phase]
	return _encoded_keys[key_id]


static func describe(state: Dictionary) -> String:
	var horizontal: String = ["left", "aligned", "right"][direction(state.orb_offset.x) + 1]
	var vertical: String = ["above", "aligned", "below"][direction(state.orb_offset.y) + 1]
	var phase: String = ["grounded", "rising", "falling"][motion(state)]
	return "Orb: %s / %s   |   Motion: %s" % [horizontal, vertical, phase]
