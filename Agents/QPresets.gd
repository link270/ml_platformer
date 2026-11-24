extends RefCounted

const DEFAULT_ID := "long_exploration"
const IDS := ["baseline", "fixed_reward_per_block", "course_position", "gap_rays", "airborne_landing", "time_penalty", "long_exploration", "discount_099", "horizontal_bins", "late_learning_rate"]
const FIXED_REWARD_PER_BLOCK := 0.005
const COURSE_POSITION_BAND_BLOCKS := 4
const EASY_ARCHIVE := "res://Experiments/2026-11-20-easy-q-learning/"
const GAP_RAY_ARCHIVE := "res://Experiments/2026-11-23-gap-rays/"
const LANDING_MEMORY_ARCHIVE := "res://Experiments/2026-11-23-airborne-landing/"
const EASY_EVALUATION_SEED := 78436300
const PRESETS := {
	"baseline": {
		"label": "Original baseline",
		"description": "Six binary rays · no time penalty.\nExploration decay 0.995 · discount 0.95.",
		"archive": "2026-10-16-q-learning-baseline",
	},
	"time_penalty": {
		"label": "Small time penalty",
		"description": "Baseline + 0.001 cost per decision.\nExploration decay 0.995 · discount 0.95.",
		"archive": "2026-10-16-q-learning-time-penalty",
	},
	"long_exploration": {
		"label": "Longer exploration",
		"description": "Time penalty + slower exploration decay: 0.999.\nSix binary rays · discount 0.95. Current default.",
		"archive": "2026-10-16-q-learning-long-exploration",
	},
	"discount_099": {
		"label": "Higher discount",
		"description": "Longer exploration + discount 0.99.\nFuture rewards carry more weight.",
		"archive": "2026-10-19-q-learning-followups/discount_099",
	},
	"horizontal_bins": {
		"label": "Richer horizontal rays",
		"description": "Longer exploration + L/R near / far / no hit.\nNear: 0–1 blocks · far: 1–2. Other rays binary.",
		"archive": "2026-10-19-q-learning-followups/horizontal_bins",
	},
	"late_learning_rate": {
		"label": "Lower late learning rate",
		"description": "Longer exploration + smaller late updates.\nLearning rate 0.1 → 0.02 over episodes 3k–10k.",
		"archive": "2026-10-19-q-learning-followups/late_learning_rate",
	},
	"fixed_reward_per_block": {
		"label": "Fixed reward per block",
		"description": "0.005 per block closer; no distance normalization.\nOther settings match Longer exploration.",
	},
	"course_position": {
		"label": "Fixed reward + course position",
		"description": "Fixed reward per block plus signed horizontal distance to the orb in four-block bands.",
	},
	"gap_rays": {
		"label": "Fixed reward + gap rays",
		"description": "Fixed reward per block plus local rays for the edge, gap width, and landing height.",
	},
	"airborne_landing": {
		"label": "Fixed reward + landing memory",
		"description": "Gap rays plus distance and height relative to the last visible landing while airborne.",
	},
}
const SEEDS := [12345, 42, 98765]
const MILESTONES := [10000, 5000, 3000, 2000, 1000, 600, 300, 100, 0]


static func configure(agent: RefCounted, id: String) -> void:
	agent.preset_id = id
	agent.learning_rate = 0.1
	agent.discount = 0.99 if id == "discount_099" else 0.95
	agent.epsilon_decay = 0.995 if id in ["baseline", "time_penalty"] else 0.999


static func time_penalty(id: String) -> float:
	return 0.0 if id == "baseline" else 0.001


static func uses_fixed_reward(id: String) -> bool:
	return id in ["fixed_reward_per_block", "course_position"] or uses_gap_rays(id)


static func uses_gap_rays(id: String) -> bool:
	return id == "gap_rays" or id == "airborne_landing"


static func save_path(id: String) -> String:
	# Keep the existing session save for the current default.
	return "user://q_learning_checkpoint.json" if id == DEFAULT_ID else "user://q_learning_%s.json" % id


static func archive_path(id: String, seed_value: int, episodes: int) -> String:
	var archive: String = PRESETS[id].get("archive", "")
	return "" if archive.is_empty() else "res://Experiments/%s/checkpoints/checkpoint-%d-%d.json" % [archive, seed_value, episodes]


static func easy_archive_path(id: String, episodes: int) -> String:
	if episodes == 0:
		return EASY_ARCHIVE + "control-results/untrained/00000.json" if id == "baseline" else ""
	var directory := "position-results" if id == "course_position" else "results"
	return EASY_ARCHIVE + "%s/%s/%05d.json" % [directory, id, episodes]


static func gap_ray_archive_path(level_id: String, episodes: int, id := "gap_rays") -> String:
	var directory := LANDING_MEMORY_ARCHIVE if id == "airborne_landing" else GAP_RAY_ARCHIVE
	return directory + "results/%s/%05d.json" % [level_id, episodes]


static func is_matched_archive(path: String) -> bool:
	return path.begins_with(EASY_ARCHIVE) or path.begins_with(GAP_RAY_ARCHIVE) or path.begins_with(LANDING_MEMORY_ARCHIVE)
