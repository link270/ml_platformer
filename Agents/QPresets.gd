extends RefCounted

# Each follow-up changes ONE thing from longer exploration; they do not stack.
const DEFAULT_ID := "long_exploration"
const IDS := ["baseline", "time_penalty", "long_exploration", "discount_099", "horizontal_bins", "late_learning_rate"]
const PRESETS := {
	"baseline": {
		"label": "1. Original baseline",
		"description": "Six binary rays · no time penalty.\nExploration decay 0.995 · discount 0.95.",
		"archive": "2026-10-16-q-learning-baseline",
	},
	"time_penalty": {
		"label": "2. Small time penalty",
		"description": "Baseline + 0.001 cost per decision.\nExploration decay 0.995 · discount 0.95.",
		"archive": "2026-10-16-q-learning-time-penalty",
	},
	"long_exploration": {
		"label": "3. Longer exploration",
		"description": "Time penalty + slower exploration decay: 0.999.\nSix binary rays · discount 0.95. Current default.",
		"archive": "2026-10-16-q-learning-long-exploration",
	},
	"discount_099": {
		"label": "4. Higher discount",
		"description": "Longer exploration + discount 0.99.\nFuture rewards carry more weight.",
		"archive": "2026-10-19-q-learning-followups/discount_099",
	},
	"horizontal_bins": {
		"label": "5. Richer horizontal rays",
		"description": "Longer exploration + L/R near / far / no hit.\nNear: 0–1 blocks · far: 1–2. Other rays binary.",
		"archive": "2026-10-19-q-learning-followups/horizontal_bins",
	},
	"late_learning_rate": {
		"label": "6. Lower late learning rate",
		"description": "Longer exploration + smaller late updates.\nLearning rate 0.1 → 0.02 over episodes 3k–10k.",
		"archive": "2026-10-19-q-learning-followups/late_learning_rate",
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


static func save_path(id: String) -> String:
	# Keep the existing session save for the current default.
	return "user://q_learning_checkpoint.json" if id == DEFAULT_ID else "user://q_learning_%s.json" % id


static func archive_path(id: String, seed_value: int, episodes: int) -> String:
	return "res://Experiments/%s/checkpoints/checkpoint-%d-%d.json" % [PRESETS[id].archive, seed_value, episodes]
