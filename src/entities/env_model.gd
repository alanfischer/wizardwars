class_name EnvModel
extends EntityBase
# env_model — MDL point entity. Displays a model with optional animation, preferring
# the BSP importer's pre-embedded model scene over AssetLoader.

const SF_START_ON := 1

var _active := true


func _ready() -> void:
	super()
	_register_for_sync()
	var model_path: String = ent.get("model", "")
	if model_path.is_empty():
		return

	var _embedded := get_children().filter(func(c): return c is Node3D)
	var model: Node3D = _embedded.front() if not _embedded.is_empty() else null
	if model == null:
		model = AssetLoader.load_model(model_path)
		if not model:
			push_warning("env_model: failed to load %s" % model_path)
			return
		add_child(model)
		add_child(BlobShadow.new(0.5))
		# Re-track so PVS uses the real mesh AABB, not just the origin point
		# (which can clip into a solid BSP leaf and hide the model).
		if _entity.entity_id >= 0:
			VisibilitySystem.untrack_node(_entity.entity_id)
			VisibilitySystem.track_node(_entity.entity_id, self)

	rotation = parse_angles(ent)
	EntityRender.apply_render_properties(model, ent)

	var anim_player := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if anim_player:
		var anims := anim_player.get_animation_list()
		var seq_idx := parse_int(ent, "sequence", 0)
		if seq_idx < anims.size():
			anim_player.play(anims[seq_idx])
		elif anims.size() > 0:
			anim_player.play(anims[0])

	var spawnflags := parse_spawnflags(ent)
	var has_targetname : bool = not ent.get("targetname", "").is_empty()
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
