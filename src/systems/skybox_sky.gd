@tool
class_name SkyboxSky
extends OvercastSky
## The procedural sky Skybox draws on the sky brushes under dynamic weather. The weather talks to
## it either way, so lightning lights the map's own cubemap sky too. Its sun stays put unless the
## map's baked sun can follow it (Skybox._sun_params).

var _skybox: WeakRef


func _init(skybox: Skybox = null, params: Dictionary = {}) -> void:
	# A sun baked into the lightmaps, where the light_environment put it, cannot move.
	super({"sun_follows_time": false}.merged(params, true), Skybox.ProceduralSkyShader)
	_skybox = weakref(skybox)


func set_flash(color: Color, dir: Vector3) -> void:
	super(color, dir)
	var box := _skybox.get_ref() as Skybox
	if box:
		box.flash_stock(color, dir)
