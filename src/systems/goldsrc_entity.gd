extends Node
## GoldSrc entity scaffolding with no WizardWars gameplay in it: lightstyle codes, the box that
## stands in for a brush a runtime-spawned entity never had, the "Volume" trigger setup, the
## FCAP_IMPULSE_USE test, and the map-unit conversion. Split out of entity_util.gd; together with
## EntityRender this is the part a generic GoldSrc entity runtime would take as-is.


# --- Lightstyle helpers ---

## GoldSrc lightstyle: 'a' = dark (0), 'm' = normal (1.0), 'z' = bright.
const LIGHTSTYLE_M_VAL := 12.0  # float("m" - "a")


## Decode a single lightstyle character to a 0.0–~2.0 intensity float.
func decode_lightstyle_char(ch: String) -> float:
	return float(ch.unicode_at(0) - "a".unicode_at(0)) / LIGHTSTYLE_M_VAL


## Encode an on/off state to a lightstyle character ('m' for on, 'a' for off).
func encode_lightstyle_on_off(on: bool) -> String:
	return String.chr("a".unicode_at(0) + (int(LIGHTSTYLE_M_VAL) if on else 0))


## GoldSrc FCAP_IMPULSE_USE test for a +use raycast hit. World geometry and
## entities that never declare the cap answer false, so a player pressing +use
## on e.g. a func_breakable does nothing — it has to be destroyed instead.
func is_player_usable(node: Node) -> bool:
	return node != null and node.has_method("is_player_usable") and node.is_player_usable()


## True for a body that walks the world the way a player does. Reads the layer rather than the
## class so a local player, a bot puppet and a third-person avatar all answer the same, and so a
## monster — which is on MASK_ENTITY — answers no. Touch volumes that were written for players
## use it to tell the two apart now that monsters can reach them.
func is_player_body(node: Node) -> bool:
	var co := node as CollisionObject3D
	return co != null and (co.collision_layer & GameConsts.MASK_PLAYER) != 0


## Default edge length for a brush stand-in, in GoldSrc units (1.6m — about a door panel).
const DEFAULT_BRUSH_SIZE := 64.0


## The brush a map entity would have been built around, stood in for by a box: the collision, the
## visible mesh, and the "Volume" Area3D that use_volume_as_trigger reads.
##
## A runtime-spawned entity (/spawn) has no brushwork — the command builds this from a "size"
## keyvalue, and the two places an entity asks for its brush (use_volume_as_trigger below, and
## FuncDoorBase._compute_brush_aabb) fall back to it when no size was given. That fallback is what
## keeps "the entity needs a brush" from being a list of classnames someone has to maintain.
func build_brush_stand_in(entity: Node3D, size_units := DEFAULT_BRUSH_SIZE) -> void:
	var extents := Vector3.ONE * size_units * GameConsts.SCALE_FACTOR
	var box := BoxShape3D.new()
	box.size = extents

	var shape := CollisionShape3D.new()
	shape.shape = box
	entity.add_child(shape)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = extents
	mesh.mesh = box_mesh
	entity.add_child(mesh)

	var volume_shape := CollisionShape3D.new()
	volume_shape.shape = box
	var volume := Area3D.new()
	volume.name = "Volume"
	volume.add_child(volume_shape)
	entity.add_child(volume)


## Configure the pre-built "Volume" Area3D on a brush entity as a trigger.
## Zeros collision_layer on the root body and hides MeshInstance3D children.
func use_volume_as_trigger(entity: Node3D, mask: int,
		monitoring: bool = true, monitorable: bool = false) -> Area3D:
	var area := entity.get_node_or_null("Volume") as Area3D
	# Spawned at runtime with no size given: asking for a trigger volume IS the entity saying it
	# needs one, so build the default rather than returning null into six callers that all connect
	# a signal to the result on the next line.
	if not area and entity.has_meta("_dyn_spawner_entity"):
		build_brush_stand_in(entity)
		area = entity.get_node_or_null("Volume") as Area3D
	if entity is CollisionObject3D:
		(entity as CollisionObject3D).collision_layer = 0
	if not area:
		push_error("use_volume_as_trigger: no Volume child on %s" % entity.name)
		return null
	area.collision_mask = mask
	area.monitoring = monitoring
	area.monitorable = monitorable
	for child in entity.get_children():
		if child is MeshInstance3D:
			child.visible = false
	return area


## Returns the moving brush entity that owns this collider, or null if it
## isn't a mover. Lets placed entities (thornplants, beanstalks) ride doors,
## elevators, and rotators by reparenting to them.
func get_mover_root(collider: Object) -> Node3D:
	if collider is FuncDoorBase or collider is FuncRotating or collider is FuncPendulum:
		return collider
	return null


## World position back into GoldSrc map units — the inverse of EntityBase.parse_vector3.
## Map data (entity "origin" keys, .map/.bsp coordinates) lives in that space, so a
## readout in these units can be compared directly against the map file.
func to_goldsrc(pos: Vector3) -> Vector3:
	var s := GameConsts.SCALE_FACTOR
	return Vector3(-pos.x / s, pos.z / s, pos.y / s)
