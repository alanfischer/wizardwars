class_name NamedMarker
extends EntityBase
# Named marker point entity — registers with TriggerSystem and parses yaw.
# Used for: info_target, info_intermission, path_corner, info_teleport_destination


func _ready() -> void:
	super()
	rotation.y = parse_yaw(ent)
