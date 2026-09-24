extends Node2D

@onready var player = $Player
@onready var spawn = $Spawn


func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("toggle_rays"):
		player.show_rays = not player.show_rays
		player.queue_redraw()
	if Input.is_action_just_pressed("reset"):
		player.reset_to(spawn.global_position)
		return
	player.set_action(Input.get_axis("move_left", "move_right"), Input.is_action_just_pressed("jump"))
	player.physics_step(delta)
