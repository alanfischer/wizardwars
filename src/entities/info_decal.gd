class_name InfoDecal
extends EntityBase
# infodecal — places a decal texture on the nearest surface.

var texture_name: String


func _ready() -> void:
	super()
	texture_name = ent.get("texture", "")
	if not texture_name.is_empty():
		if Game.decal_system:
			Game.decal_system.place_probe(texture_name, global_position)
