extends VBoxContainer

const HeatMap := preload("res://Game/PathHeatMap.gd")
var heat_map: Node2D


func _ready() -> void:
	%ShowHeatMap.toggled.connect(_toggle)


func bind_heat_map(map: Node2D) -> void:
	heat_map = map
	heat_map.totals_changed.connect(_update_counts)
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0])
	gradient.colors = PackedColorArray(HeatMap.COLORS)
	var texture := GradientTexture1D.new()
	texture.width = 128
	texture.gradient = gradient
	%HeatScale.texture = texture
	show()
	_toggle(%ShowHeatMap.button_pressed)
	_update_counts()


func _toggle(value: bool) -> void:
	if heat_map != null:
		heat_map.visible = value
	%HeatLegend.visible = value


func _update_counts() -> void:
	%HeatCounts.text = "%d completed · %d active" % [heat_map.completed_episodes, heat_map.active_episodes.size()]
