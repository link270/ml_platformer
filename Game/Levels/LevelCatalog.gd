extends RefCounted

# Keep the original course first for existing experiments and checkpoints.
const IDS := ["original", "template", "easy", "medium", "hard"]
const LABELS := ["Original test level", "Large template · flat floor", "Easy · steps and hills", "Medium · platforms and gaps", "Hard · elevated gap chains"]
const PATHS := ["res://Game/Level.tscn", "res://Game/Levels/LargeTemplate.tscn", "res://Game/Levels/TrainingEasy.tscn", "res://Game/Levels/TrainingMedium.tscn", "res://Game/Levels/TrainingHard.tscn"]


static func scene_path(id: String) -> String:
	var index := IDS.find(id)
	return PATHS[index] if index >= 0 else ""
