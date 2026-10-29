class_name ItemHealthkit
extends EntityBase
## item_healthkit — the health pickup. WW inherits Half-Life's CHealthKit unchanged:
## touch it below max health and it heals, plays a sound, vanishes, and rematerializes
## 30s later; a player already at full health doesn't consume it.
##
## Model: WW's healthkit.cpp names models/w_medkit.mdl, but the mod never shipped that
## file, so we draw models/health.mdl (medibag) instead. Heal amount is skill-driven in
## GoldSrc (a skill.cfg WW doesn't ship); set here directly.
##
## HOST-AUTHORITATIVE: pickup and respawn happen on the host; clients follow synced
## game-visibility.

const HEAL_AMOUNT := 25.0
const RESPAWN_TIME := 30.0
const SF_NORESPAWN := 1 << 30
const PICKUP_SOUND := "items/smallmedkit1.wav"

var _touch := TouchBehavior.new()


func _ready() -> void:
	super()
	_register_for_sync()
	_touch.initialize(self, _try_give)
	if not (parse_spawnflags(ent) & SF_NORESPAWN):
		_touch.respawn_time = RESPAWN_TIME
	SoundSystem.precache(PICKUP_SOUND)

	var model := AssetLoader.load_model("models/health.mdl")
	if model:
		add_child(model)
		add_child(BlobShadow.new(0.3))
		# Re-track so _compute_local_aabb sees the real mesh AABB — otherwise PVS
		# uses the origin point alone and the kit vanishes when that point clips
		# into a solid leaf.
		if _entity.entity_id >= 0:
			VisibilitySystem.untrack_node(_entity.entity_id)
			VisibilitySystem.track_node(_entity.entity_id, self)
	else:
		push_warning("item_healthkit: failed to load models/health.mdl")

	rotation = parse_angles(ent)
	_touch.add_box()
	_seed_game_visible()


func _physics_process(delta: float) -> void:
	_touch.tick(delta)


func _try_give(body: Node3D) -> bool:
	if not body.has_method("heal"):
		return false
	if body.get("is_dead"):
		return false
	# CBaseEntity::TakeHealth: no room to heal means the kit isn't consumed.
	var health: float = body.get("health")
	var max_health: float = body.get("max_health")
	if health >= max_health:
		return false

	body.heal(HEAL_AMOUNT, self)
	SoundSystem.play_3d(PICKUP_SOUND, global_position)
	_touch.take()
	return true
