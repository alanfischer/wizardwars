class_name TriggerHurt
extends EntityBase
# trigger_hurt — area that damages players while inside.
# Negative "dmg" heals instead (CTriggerHurt::HurtTouch), capped at max_health.

const SF_START_OFF := 1

# Half-Life SDK damage type bitflags (from "damagetype" entity key)
const DMG_BURN := 8
const DMG_FREEZE := 16
const DMG_SHOCK := 256

var _dmg: float
var _delay: float  # seconds between damage ticks
var _dmg_type: int  # GameConsts.DamageType
var _active := true
var _target_key: String
var _req_team: int  # team_no: only this team is hurt (0 = all)
var _area: Area3D
var _timer: float
var _target_fired := false


func _ready() -> void:
	super()
	_dmg = parse_float(ent, "dmg", 10.0)
	_delay = parse_float(ent, "delay", 0.5)
	if _delay <= 0.0:
		_delay = 0.5
	_dmg_type = _parse_damage_type(parse_int(ent, "damagetype", 0))
	_target_key = ent.get("target", "")
	_req_team = parse_int(ent, "team_no", 0)
	var spawnflags := parse_spawnflags(ent)

	if spawnflags & SF_START_OFF:
		_active = false

	_area = GoldSrcEntity.use_volume_as_trigger(self, GameConsts.MASK_PLAYER)
	# Findable by a point query, and pointing back here: what the volume hurts for is on the
	# entity, not the Area3D, and an entity with no collider looks this up rather than being
	# touched (SpatialQuery.hurt_volume_at).
	_area.collision_layer = GameConsts.MASK_HAZARD
	_area.monitorable = true
	_area.set_meta(&"hurt_volume", self)
	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)
	_timer = 0.0


func _physics_process(delta: float) -> void:
	if not _active or not _area:
		return
	# Host-only: damage ticks and trigger firing are authoritative.
	# Client receives trigger toggle (_active state) via host broadcast.
	if _is_network_client():
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = _delay
	var hit := false
	for body in _area.get_overlapping_bodies():
		if body is CharacterBody3D and body.has_method("take_damage"):
			if not body.is_alive:
				continue
			if _req_team != 0 and body.get("team") != null and body.team != _req_team:
				continue
			if not _apply(body):
				continue
			hit = true
	if hit and not _target_fired and not _target_key.is_empty():
		_target_fired = true
		TriggerSystem.fire(_target_key, self, TriggerSystem.Type.TOGGLE)


func _on_body_entered(body: Node3D) -> void:
	if not _active or _is_network_client():
		return
	if body is CharacterBody3D and body.has_method("take_damage"):
		if not body.is_alive:
			return
		if _req_team != 0 and body.get("team") != null and body.team != _req_team:
			return
		_apply(body, true)
		_timer = _delay  # reset tick timer so we don't double-hit immediately


## Damage (or heal, for negative dmg) one body. Returns false if it was skipped.
## deferred: take_damage can kill (spawning a corpse / changing collision), which mid
## body_entered callback re-enters the physics server and corrupts it (Linux segfault
## under load). Runs on the next idle instead. Healing can't kill, so it goes direct.
func _apply(body: Node3D, deferred := false) -> bool:
	if _dmg < 0.0:
		if not body.has_method("heal"):
			return false
		body.heal(-_dmg)
	elif deferred:
		body.call_deferred("take_damage", _dmg, _dmg_type)
	else:
		body.take_damage(_dmg, _dmg_type)
	return true


## Damage something that reported itself inside this volume — the path for entities an Area3D
## cannot see (a projectile is a bare Node3D). Same damage, type and team rule as a touch; the
## caller reports itself on ENTERING, so this hurts once per crossing rather than per tick.
func hurt(node: Node3D) -> bool:
	if not _active or _is_network_client():
		return false
	if _req_team != 0 and node.get("team") != null and node.team != _req_team:
		return false
	return _apply(node)


func _on_body_exited(body: Node3D) -> void:
	if body is CharacterBody3D and _area.get_overlapping_bodies().is_empty():
		_target_fired = false


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	_active = not _active


# Map Half-Life damagetype bitflags to GameConsts.DamageType.
# HL uses bitflags so a trigger can in theory combine types; in practice WW maps
# set a single flag. Test fire first since fire status is the primary intent.
func _parse_damage_type(flags: int) -> int:
	if flags & DMG_BURN:
		return GameConsts.DamageType.FIRE
	if flags & DMG_FREEZE:
		return GameConsts.DamageType.ICE
	if flags & DMG_SHOCK:
		return GameConsts.DamageType.LIGHTNING
	return GameConsts.DamageType.PHYSICAL
