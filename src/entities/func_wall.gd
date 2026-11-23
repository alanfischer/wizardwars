class_name FuncWall
extends EntityBase
# func_wall — static brush that can have render properties and targetname registration.


func _ready() -> void:
	super()
	EntityRender.apply_render_properties(self, ent)
	if not ent.get("targetname", "").is_empty():
		_register_for_sync()  # only a named wall is used, and so ever changes frame


## CFuncWall::Use flips the frame, which switches its textures to their alternates.
func trigger(_activator: Node, type: TriggerSystem.Type) -> void:
	if _is_network_client():
		return
	if (type == TriggerSystem.Type.ON and _texture_frame != 0) \
			or (type == TriggerSystem.Type.OFF and _texture_frame == 0):
		return  # ShouldToggle
	set_texture_frame(1 - _texture_frame)
