class_name FuncWall
extends EntityBase
# func_wall — static brush that can have render properties and targetname registration.


func _ready() -> void:
	super()
	EntityRender.apply_render_properties(self, ent)
