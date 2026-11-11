class_name LightEnvironment
extends EntityBase
# light_environment — lightstyle controller for BSP surface brightness.
# BSP surfaces are lit by baked lightmaps; models by the volumetric light grid.
# Only the first instance takes effect (maps may have duplicates for compile tools).

var _style: int = 0
var _ls_image: Image = null
var _ls_texture: ImageTexture = null


func _ready() -> void:
	super()
	for sibling in get_parent().get_children():
		if sibling == self:
			break  # we're the first one — keep us
		if sibling is EntityBase and sibling.get_script() == get_script():
			queue_free()
			return

	# The map's scene root owns a map-placed entity; a spawned one has no shared lightstyles to drive.
	if owner and owner.has_meta("lightstyle_image"):
		_ls_image = owner.get_meta("lightstyle_image")
		_ls_texture = owner.get_meta("lightstyle_texture")
	_style = parse_int(ent, "style", 0)
	_register_for_sync()

	# Deliberately no DirectionalLight3D: it would double-light models (which already
	# get ambient lighting from the volumetric light grid) and mis-light BSP surfaces
	# (already lit by baked lightmaps). Lightstyle animation still works via the
	# lightstyle texture that drives BSP surface shaders.


func set_light_style(style_char: String) -> void:
	if style_char.is_empty():
		return
	# Broadcast directly — light style is an event, not persistent diffable state
	if _entity.entity_id >= 0 and not _is_network_client():
		NetworkManager.sync_entity_state.rpc(_entity.entity_id, {"light_style": style_char})
	var intensity := GoldSrcEntity.decode_lightstyle_char(style_char)
	if _style > 0:
		if _ls_image and _ls_texture:
			_ls_image.set_pixel(_style, 0, Color(intensity, 0, 0, 1))
			_ls_texture.update(_ls_image)
	# A sun in style 0 shares its layer with the map's lights; the baked sun fraction is what
	# fades only the sun's part of it. Models take it from there either way.
	NightMode.set_sun_style(intensity, _style > 0)


func _apply_sync_state(state: Dictionary) -> void:
	if "light_style" in state:
		set_light_style(state["light_style"])
