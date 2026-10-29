class_name FuncWater
extends FuncDoorBase
# Liquid volume brush (water/slime/lava) — configures the pre-built Volume (Area3D
# with convex shapes from the BSP tree) for liquid detection, and applies translucency.
# The "skin" key picks the liquid type (HL convention: -3 water, -4 slime, -5 lava).
# Slime/lava also register on MASK_WATER so swim physics works, with the extra layer
# driving damage and suppressing the fire-extinguish that pure water gets.
#
# Extends the mover rather than EntityBase because in GoldSrc a func_water IS a door:
# doors.cpp does LINK_ENTITY_TO_CLASS(func_water, CFuncDoor), water being a door whose skin
# names a content type. That is why these brushes carry door keys — speed, lip, wait — and it
# is how a map floods: ww_volcano's "volc" is a lava door with lip 160 that rises on trigger.
# Water differs from a door only in what SOLID_NOT implies (see _setup_movement).

const SKIN_WATER := -3
const SKIN_SLIME := -4
const SKIN_LAVA := -5

var move_dir: Vector3
var lip: float

func _ready() -> void:
	super()
	if _anim_body:
		_anim_body.collision_layer = 0
		_anim_body.collision_mask = 0

	var skin := parse_int(ent, "skin", SKIN_WATER)

	# Configure the pre-built convex volume for liquid layer detection
	var volume := get_node_or_null("Volume") as Area3D
	if volume:
		var layer := GameConsts.MASK_WATER
		if skin == SKIN_LAVA:
			layer |= GameConsts.MASK_LAVA
		elif skin == SKIN_SLIME:
			layer |= GameConsts.MASK_SLIME
		volume.collision_layer = layer
		volume.collision_mask = 0
		volume.monitorable = true
		volume.monitoring = false

	# Before the alpha block below, which returns early when the liquid is opaque — and opaque
	# is exactly ww_volcano's lava (rendermode 0, skin -5), the one brush in the game that moves.
	_setup_movement()

	# GoldSrc draws func_water translucent via rendermode + renderamt; plain water with no
	# rendermode still reads as see-through, while slime/lava stay opaque unless set. Textures
	# without a '!' prefix skip the importer's turbulent water shader, so this is the only
	# place they turn to liquid.
	var rendermode := parse_int(ent, "rendermode", 0)
	# An ABSENT renderamt is 0, not 255: GoldSrc zero-initialises the entity, so a rendermode
	# with no amount is an invisible brush. EntityRender.apply_render_properties has read it that
	# way all along; this was the one place that did not. ww_osaka's *43 is the only brush in
	# the game it decides — rendermode 2 with no renderamt, an invisible water volume laid over
	# the func_conveyor that supplies the visuals.
	var renderamt := parse_int(ent, "renderamt", 0)
	var alpha := 1.0
	if rendermode != 0:
		alpha = clampf(renderamt / 255.0, 0.0, 1.0)
	elif skin == SKIN_WATER:
		alpha = 0.6

	# Backfaces stay culled, as in GoldSrc: a func_water brush model carries only
	# outward-facing faces, so a water box sunk flush into rock never z-fights it —
	# at the cost of the surface vanishing when you swim under it, same as the engine.
	if alpha >= 1.0:
		return  # nothing to apply; leave the BSP's own lightmapped material alone

	for mi in EntityRender.find_mesh_instances(self):
		# The converter now gives every func_water face the turbulent liquid shader, whatever
		# its texture is called. Feed that shader its alpha rather than replacing it: converting
		# to StandardMaterial3D would strip the warp back off the very maps this fixed — 2fort
		# is rendermode 2 / renderamt 150, so it lands here every time. The BSP builds one
		# material per (texture, atlas page) PER MODEL, and a func_water is exactly one model,
		# so writing the uniform in place touches only this brush.
		if mi.has_meta("is_water_surface"):
			for surf_idx in mi.mesh.get_surface_count():
				var water_mat := mi.mesh.surface_get_material(surf_idx) as ShaderMaterial
				if water_mat:
					water_mat.set_shader_parameter("water_alpha", alpha)
			continue
		for surf_idx in mi.mesh.get_surface_count():
			var base_mat: Material = mi.get_active_material(surf_idx)
			var mat: StandardMaterial3D = null
			if base_mat is StandardMaterial3D:
				mat = base_mat.duplicate()
			elif base_mat is ShaderMaterial:
				mat = EntityRender.convert_shader_to_standard(base_mat)
			if mat == null:
				continue
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = alpha
			mi.set_surface_override_material(surf_idx, mat)


## Wire up door movement, but only for a brush something can actually trigger. Water is
## SOLID_NOT in the SDK, which decides all three differences from a door:
##   - it can never be touch-activated, so an unnamed func_water is scenery and takes none of
##     this. That matters: the game has over a hundred static pools and each would otherwise
##     pay for a MultiplayerSynchronizer and a registered synced entity it can never use.
##   - nothing can be crushed by it, so it needs no blocked detector (_build_body's solid_brush).
##   - it moves silently.
## The Volume Area3D and the surface meshes are children of this node, so the tween that moves
## the entity carries the swimmable volume with it — there is no second thing to keep in step.
func _setup_movement() -> void:
	if (ent.get("targetname", "") as String).is_empty():
		return

	_parse_common_properties(ent)
	_move_sound = null  # SDK: water spawns silent, and no map declares movesnd/stopsnd on one
	_stop_sound = null

	move_dir = parse_movedir(ent)
	move_speed = parse_float(ent, "speed", 100.0) * GameConsts.SCALE_FACTOR
	lip = parse_float(ent, "lip", 0.0) * GameConsts.SCALE_FACTOR

	var aabb := _compute_brush_aabb()
	var travel := absf(move_dir.dot(aabb.size)) - lip
	position1 = Vector3.ZERO
	position2 = move_dir * travel
	if spawn_flags & SF_START_OPEN:
		var tmp := position1
		position1 = position2
		position2 = tmp

	_build_body(aabb, false)
	position = _base_position + position1

	# No _setup_touch_area: SOLID_NOT means the only way in is the trigger chain. And no
	# _physics_process either — everything the base does per frame is push-and-crush handling
	# for a solid brush. EntityBase's kinematic-velocity sync rides physics_frame, not this,
	# so it keeps working.
	set_physics_process(false)

	Log.debug("func_water '%s': dir=%s aabb_size=%s travel=%.3f speed=%.3f wait=%.1f lip=%.3f" % [
		name, move_dir, aabb.size, travel, move_speed, wait_time, lip])


func _move_open(callback: Callable) -> void:
	_linear_move(position2, callback)


func _move_closed(callback: Callable) -> void:
	_linear_move(position1, callback)
