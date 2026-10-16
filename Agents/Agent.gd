extends RefCounted

enum Action { DO_NOTHING = 0, MOVE_LEFT = 1, MOVE_RIGHT = 2, JUMP = 3, MOVE_LEFT_JUMP = 4, MOVE_RIGHT_JUMP = 5 }
const TICKS_PER_DECISION := 6
const ACTION_NAMES := ["Idle", "Left", "Right", "Jump", "Left + jump", "Right + jump"]
const ACTION_INPUTS := [
	{"move_axis": 0.0, "jump_pressed": false},
	{"move_axis": -1.0, "jump_pressed": false},
	{"move_axis": 1.0, "jump_pressed": false},
	{"move_axis": 0.0, "jump_pressed": true},
	{"move_axis": -1.0, "jump_pressed": true},
	{"move_axis": 1.0, "jump_pressed": true},
]

var rng := RandomNumberGenerator.new()
var observation_rays := [0, 1, 2, 3, 4, 5, 6, 7]


func _init() -> void:
	rng.randomize()


func choose_action(_state: Dictionary) -> int:
	return Action.DO_NOTHING


# Called once per decision interval (or early termination), with summed rewards.
func learn(_state: Dictionary, _action: int, _reward: float, _next_state: Dictionary) -> void:
	pass


func finish_episode(_success: bool) -> void:
	pass
