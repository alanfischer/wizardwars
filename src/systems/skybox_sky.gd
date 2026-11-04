class_name SkyboxSky
extends OvercastSky
## The procedural sky Skybox draws on the sky brushes under dynamic weather. The weather talks to
## it either way: lightning lights the map's own cubemap sky too, and with the cubemap up the
## haze fades to the art's horizon, which no storm greys.

var _skybox: WeakRef


func _init(skybox: Skybox = null, params: Dictionary = {}) -> void:
	super(params, Skybox.ProceduralSkyShader)
	_skybox = weakref(skybox)


func set_flash(color: Color, dir: Vector3) -> void:
	super(color, dir)
	var box := _skybox.get_ref() as Skybox
	if box:
		box.flash_stock(color, dir)


func horizon_now() -> Color:
	if drawing:
		return super()
	return (param("horizon_color") as Color).srgb_to_linear()  # sRGB, measured off the cubemap
