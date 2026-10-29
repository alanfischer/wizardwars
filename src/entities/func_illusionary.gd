class_name FuncIllusionary
extends EntityBase
# Non-solid brush entity — remove collision so players walk through it.


func _ready() -> void:
	super()
	_anim_body.collision_layer = 0
	_anim_body.collision_mask = 0
	EntityRender.apply_render_properties(self, ent)
