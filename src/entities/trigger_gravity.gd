class_name TriggerGravity
extends EntityBase
# trigger_gravity — area that changes the player's gravity while inside.

var _gravity_scale: float
var _area: Area3D


func _ready() -> void:
	super()
	_gravity_scale = parse_float(ent, "gravity", 1.0)

	_area = GoldSrcEntity.use_volume_as_trigger(self, GameConsts.MASK_FIELD_TRIGGER)
	_area.body_entered.connect(_on_body_entered)


# MASK_FIELD_TRIGGER already filters overlaps to bodies this peer owns, so no
# authority check is needed. GoldSrc parity: gravity persists until another
# trigger_gravity overwrites it — no restore on exit.
func _on_body_entered(body: Node3D) -> void:
	if body is CharacterBody3D and "gravity_scale" in body and body.is_alive:
		body.gravity_scale = _gravity_scale
