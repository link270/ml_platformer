extends SceneTree

const DT := 1.0 / 60.0
var failed := false


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func _initialize() -> void:
	call_deferred("run_check")


func run_check() -> void:
	var level := preload("res://Level.tscn").instantiate()
	root.add_child(level)
	level.set_physics_process(false)
	var player: CharacterBody2D = level.get_node("Player")
	await physics_frame
	player.physics_step(DT)
	check(player.is_on_floor(), "initial landing")

	for tick in 12:
		await physics_frame
		player.set_action(1.0, false)
		player.physics_step(DT)
		check(absf(player.velocity.x) <= 6.0 * 32.0 + 0.01, "horizontal speed cap")
	check(is_equal_approx(player.velocity.x, 6.0 * 32.0), "horizontal acceleration")

	for tick in 10:
		await physics_frame
		player.set_action(-1.0, false)
		player.physics_step(DT)
	check(player.velocity.x < 0.0, "reversal")

	player.reset_to(level.get_node("Spawn").global_position)
	check(player.velocity == Vector2.ZERO, "reset velocity")
	await physics_frame
	player.physics_step(DT)
	await physics_frame
	player.set_action(0.0, true)
	player.physics_step(DT)
	for tick in 2:
		await physics_frame
		player.physics_step(DT)
	check(player.velocity.y >= -12.0 * 32.0 - 0.01, "upward speed cap")
	check(player.velocity.y < 0.0, "jump launch")
	for tick in 100:
		await physics_frame
		player.physics_step(DT)
		check(player.velocity.y <= 14.0 * 32.0 + 0.01, "fall speed cap")
	check(player.is_on_floor(), "jump landing")

	for tick in 120:
		await physics_frame
		player.set_action(1.0, false)
		player.physics_step(DT)
	check(player.global_position.x <= 240.1, "wall blocking")
	check(is_zero_approx(player.velocity.x), "wall velocity")
	if not failed:
		print("Phase one check passed")
	quit(1 if failed else 0)
