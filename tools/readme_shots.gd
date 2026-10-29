extends Node
## Action screenshots for the README: a real listen-host match on ww_2fort with the bots herded onto
## the two ends of the rope bridge, shot from fixed cameras whenever spells are in the air over it.
## Frames are 2560x1440, rendered offscreen.
##
##   SHOT_DIR=/tmp/shots "$GODOT" --path . --rendering-method forward_plus \
##       res://tools/readme_shots.tscn -- --host --map ww_2fort --bots 12
##
## SHOT_WARMUP (s, default 20), SHOT_COUNT (default 30), SHOT_EVERY (s, default 1.5).

## GoldSrc units. The deck is z -64 from y -450 to 450, about 200 wide; ground either side is z -54.
const ENDS := {1: Vector2(250.0, 650.0), 2: Vector2(-650.0, -250.0)}
const STAND_Z := -18.0
## [eye, target] pairs.
const CAMERAS := [
	[Vector3(330, 60, 10), Vector3(0, -40, -30)],
	[Vector3(-330, -60, 10), Vector3(0, 40, -30)],
	[Vector3(260, 420, 110), Vector3(0, -60, -50)],
	[Vector3(-260, -420, 110), Vector3(0, 60, -50)],
	[Vector3(0, 620, 0), Vector3(0, 0, -30)],
	[Vector3(220, -150, -40), Vector3(0, 100, -40)],
]

var _pvs_cam: Camera3D = null


func _ready() -> void:
	if has_meta("active"):
		return
	var shooter := Node.new()
	shooter.set_script(get_script())
	shooter.name = "ReadmeShooter"
	shooter.set_meta("active", true)
	get_tree().root.add_child.call_deferred(shooter)
	get_tree().change_scene_to_file.call_deferred("res://src/main.tscn")


func _enter_tree() -> void:
	if has_meta("active"):
		process_physics_priority = 1000
		_run.call_deferred()


## main.gd points the BSP PVS at the host's eye every physics frame; running after it, this
## re-points it at the free camera so the world around the shot is not culled.
## The host's own view also drives the underwater fog, and a spectator parked in the ravine water
## would fog every frame.
func _physics_process(_delta: float) -> void:
	if _pvs_cam:
		VisibilitySystem.set_local_position(_pvs_cam.global_position)
		var world_env := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
		if world_env and world_env.environment:
			world_env.environment.fog_enabled = false


func _env(key: String, fallback: float) -> float:
	var v := OS.get_environment(key)
	return float(v) if v != "" else fallback


func _gs(g: Vector3) -> Vector3:
	return Vector3(-g.x, g.z, g.y) * GameConsts.SCALE_FACTOR


func _run() -> void:
	var dir := OS.get_environment("SHOT_DIR")
	DirAccess.make_dir_recursive_absolute(dir)
	await get_tree().create_timer(_env("SHOT_WARMUP", 20.0)).timeout
	var root := get_tree().root
	var sub := SubViewport.new()
	sub.size = Vector2i(2560, 1440)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.msaa_3d = root.msaa_3d
	sub.screen_space_aa = root.screen_space_aa
	sub.use_debanding = root.use_debanding
	root.add_child(sub)
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.far = 400.0
	sub.add_child(cam)
	cam.make_current()
	_pvs_cam = cam
	_herd_loop()
	var n := int(_env("SHOT_COUNT", 30.0))
	for i in n:
		var view: Array = CAMERAS[i % CAMERAS.size()]
		cam.global_position = _gs(view[0])
		cam.look_at(_gs(view[1]), Vector3.UP)
		await get_tree().create_timer(_env("SHOT_EVERY", 1.5)).timeout
		for attempt in 30:
			if _spells_over_bridge() >= 2:
				break
			await get_tree().create_timer(0.2).timeout
		await RenderingServer.frame_post_draw
		var path := "%s/bridge_%02d_cam%d.png" % [dir, i, i % CAMERAS.size()]
		sub.get_texture().get_image().save_png(path)
		print("[ReadmeShots] ", path)
	get_tree().quit()


func _in_arena(g: Vector3) -> bool:
	return absf(g.x) < 260.0 and absf(g.y) < 800.0 and g.z > -140.0 and g.z < 200.0


func _to_gs(p: Vector3) -> Vector3:
	var g := p / GameConsts.SCALE_FACTOR
	return Vector3(-g.x, g.z, g.y)


func _spells_over_bridge() -> int:
	var n := 0
	for s in get_tree().get_nodes_in_group("projectile"):
		if is_instance_valid(s) and s is Node3D and _in_arena(_to_gs((s as Node3D).global_position)):
			n += 1
	return n


## Every two seconds, any live bot that has left the bridge area goes back to its team's end,
## facing the other one.
func _herd_loop() -> void:
	while is_inside_tree():
		for b in BotSystem._bots:
			if not is_instance_valid(b) or b.is_dead or not ENDS.has(b.team):
				continue
			if _in_arena(_to_gs(b.global_position)):
				continue
			var span: Vector2 = ENDS[b.team]
			var g := Vector3(randf_range(-70.0, 70.0), randf_range(span.x, span.y), STAND_Z)
			b.teleport_to(_gs(g), 0.0 if b.team == 1 else PI)
		await get_tree().create_timer(2.0).timeout
