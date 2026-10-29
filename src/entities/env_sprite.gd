class_name EnvSprite
extends EntityBase
# env_sprite — billboard sprite point entity.
# Loads sprite frames from pre-converted .scn (self-animating) or C++ plugin fallback.

const SF_START_ON := 1  # GoldSrc env_sprite: spawnflag 1 = start on (default is off)

var _active := true


func _ready() -> void:
	super()
	_register_for_sync()
	var model_path: String = ent.get("model", "")
	if model_path.is_empty():
		return

	var _embedded := get_children().filter(func(c): return c is Sprite3D)
	var sprite := _embedded.front() as Sprite3D if not _embedded.is_empty() else null
	if sprite == null:
		sprite = AssetLoader.load_sprite_node(model_path)
		if not sprite:
			push_warning("env_sprite: failed to load %s" % model_path)
			return
		add_child(sprite)

	sprite.name = "Sprite"
	# Billboard mode is baked into the scene by the SPR importer from the sprite's
	# type field — don't override it here.
	sprite.pixel_size = GameConsts.SCALE_FACTOR * parse_float(ent, "scale", 1.0)

	var framerate := parse_float(ent, "framerate", 10.0)
	var sap = sprite.get_node_or_null(^"SpriteAnimationPlayer")
	if sap:
		sap.fps = framerate

	var rendermode := parse_int(ent, "rendermode", 0)
	var renderamt := parse_int(ent, "renderamt", 255)

	# SPR texture_format and entity rendermode are independent (e.g. a NORMAL sprite
	# used additively in the map), so patch the baked material if only the entity says additive.
	if rendermode == 5:
		var mat := sprite.material_override
		if mat is StandardMaterial3D:
			AssetLoader.set_additive_blend(mat as StandardMaterial3D)
		elif mat == null:
			var new_mat := StandardMaterial3D.new()
			new_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			new_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			AssetLoader.set_additive_blend(new_mat)
			if sprite.texture:
				new_mat.albedo_texture = sprite.texture
			sprite.material_override = new_mat
	else:
		# The SPR itself may be additive (texture_format SPR_ADDITIVE) even when the
		# entity's rendermode isn't; that baked material needs the fog opt-out too.
		AssetLoader.fix_additive_fog(sprite)

	if rendermode > 0 and renderamt < 255:
		sprite.modulate.a = renderamt / 255.0

	var spawnflags := parse_spawnflags(ent)
	var has_targetname: bool = not ent.get("targetname", "").is_empty()
	if has_targetname and not (spawnflags & SF_START_ON):
		_active = false
		visible = false
	_seed_game_visible()


func trigger(_activator: Node, type: TriggerSystem.Type) -> void:
	match type:
		TriggerSystem.Type.ON: _active = true
		TriggerSystem.Type.OFF: _active = false
		TriggerSystem.Type.TOGGLE: _active = not _active
	_set_game_visible_synced(_active)
