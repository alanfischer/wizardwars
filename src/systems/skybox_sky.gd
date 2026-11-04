class_name SkyboxSky
extends OvercastSky
## The procedural sky Skybox draws on the sky brushes under dynamic weather. The weather talks to
## it either way, so lightning lights the map's own cubemap sky too.

var _skybox: WeakRef


func _init(skybox: Skybox = null, params: Dictionary = {}) -> void:
	super(params, Skybox.ProceduralSkyShader)
	_skybox = weakref(skybox)


func set_flash(color: Color, dir: Vector3) -> void:
	super(color, dir)
	var box := _skybox.get_ref() as Skybox
	if box:
		box.flash_stock(color, dir)

