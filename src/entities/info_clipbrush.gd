class_name InfoClipBrush
extends EntityBase
## info_clipbrush — an importer-injected clip volume.
##
## GoldSrc CLIP brushes live only in the clip hulls (hull 1-3), which our importer
## doesn't build, so clip walls are lost (e.g. ww_golem's water had no collision).
## This point entity re-creates one as an axis-aligned (optionally yaw-rotated) box
## on LAYER_CLIP: blocks player movement/dragon/satchels/bots (MASK_WORLD_AND_CLIP),
## while spells and hitscan (never masked against MASK_CLIP) pass through.
## Injected by tools/ww_clipbrush.py.
##
## Keys: origin = box center (GoldSrc units, applied by the importer); size =
## "sx sy sz" full extents (GoldSrc units); optional angles "pitch yaw roll"
## (only yaw is meaningful for a box).


func _ready() -> void:
	super()
	# parse_vector3 maps GoldSrc (x,y,z) -> Godot (-x, z, y) * scale; box
	# dimensions are unsigned, so take magnitudes of the mapped extents.
	# The importer turns this node 90° past the clip's yaw (its -Z faces the yaw), so the box's
	# X and Z swap to stand at the yaw itself.
	var mapped := parse_vector3(ent.get("size", "0 0 0"))
	var box_size := Vector3(absf(mapped.z), absf(mapped.y), absf(mapped.x))
	if box_size.x <= 0.0 or box_size.y <= 0.0 or box_size.z <= 0.0:
		push_warning("info_clipbrush '%s': non-positive size '%s'" % [name, ent.get("size", "")])
		return

	var body := StaticBody3D.new()
	body.name = "ClipBody"
	body.collision_layer = GameConsts.MASK_CLIP
	body.collision_mask = 0

	var box := BoxShape3D.new()
	box.size = box_size
	var shape := CollisionShape3D.new()
	shape.shape = box
	body.add_child(shape)

	add_child(body)
