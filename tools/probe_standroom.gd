extends SceneTree
## Where on the golem can a player stand, and where can they only duck?
##
## "I can't unduck here" is almost always the map, not the engine: GoldSrc hulls are
## boxes, so headroom is a step function and the standable band can end a unit from
## where you're standing. This prints the stand/duck map over a horizontal slice in
## the left leg's own GoldSrc space, which is the frame ww_golem's stairs are cut in.
##
## Verified against a direct clipnode descent of ww_golem.bsp: the two agree.
## Usage: Z=224 tools/probe_standroom.gd   (Z is the floor height, leg-local GS)

const MovementConfig = preload("res://addons/pmove/movement_config.gd")

const S := 0.025


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 20:
		await physics_frame

	var leg: AnimatableBody3D = null
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if "leftleg" in String(n.get_meta("entity", {}).get("classname", "")):
			leg = n

	var b := CharacterBody3D.new()
	b.collision_layer = 0
	b.collision_mask = 33
	b.safe_margin = 0.01
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"  # GodotBody.set_collision_height looks it up by name
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 0.9
	cs.shape = cap
	cs.position = Vector3(0, 0.45, 0)
	b.add_child(cs)
	root.add_child(b)
	var body := GodotBody.new(b)
	var cfg := MovementConfig.new()

	var z := 224.0
	if OS.get_environment("Z") != "":
		z = float(OS.get_environment("Z"))
	# Landmarks in this frame: the stair treads run z = 16k at x = -44+k, in the
	# channel y 64..112; the leg top is z=208; the golem's belly deck is z=224.
	print("Standing room with the feet at leg-local z=%.0f." % z)
	print("'ST' = the player may stand here, '#' = crouch-only or solid.")
	print("The stair channel is y 64..112, so that is where the stairs leave you.\n")
	var header := "   x |"
	for y in range(-8, 121, 8):
		header += " %4d" % y
	print(header)
	for x in range(-56, 41, 8):
		var line := "%4d |" % x
		for y in range(-8, 121, 8):
			b.global_position = leg.global_transform * gs_to_godot(float(x), float(y), z) + Vector3.UP * 0.002
			body.force_sync_physics()
			line += "  %s " % ("ST" if body.has_headroom(cfg.stand_height - cfg.crouch_height) else " #")
		print(line)
	quit(0)
