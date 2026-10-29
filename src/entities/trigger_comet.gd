class_name TriggerComet
extends EntityBase
# Spawn guard — drops a comet on an intruder. Two modes, picked from whether the map
# gave it a team_no, because that key is exactly what a guard needs to choose targets
# for itself:
#
#   no team_no   passive. Sits inert until triggered. A team-filtered trigger_multiple
#                volume names it as its target and hands over the player who tripped it,
#                so the volume's brush shape is the trigger area and its `wait` is the
#                cooldown.
#   has team_no  active. Scans every SCAN_INTERVAL for a visible player of that team
#                within RANGE and comets the first one it can see. Replaces the original
#                WW instant-kill beam.
#
# team_no names the team the guard ATTACKS, not the team that owns it — matching TFC
# monster_sentry, and matching trigger_multiple's own team_no. Mappers put guards in the
# enemy team's spawn.
#
# Entity classnames: trigger_comet, ww_sentrycrystal, monster_turret, monster_miniturret

const RANGE := 25.6          # 1024 GS units * 0.025
const SCAN_INTERVAL := 0.5   # seconds between scans
const FIRE_COOLDOWN := 2.0   # seconds between comet launches (per target)

var _scanning := false
var _team: int = 0
var _is_ceiling := false  # orientation: 0=floor, 1=ceiling (HL keyvalue)
var _scan_timer := 0.0
var _last_fire_time := {}  # instance id -> float (last comet time per target)


func _ready() -> void:
	super()
	# Presence, not value: a mapper writing team_no "0" means "attack team 0", not
	# "I have no team", and must not silently fall through to the passive mode.
	_scanning = ent.has("team_no")
	_team = parse_int(ent, "team_no", 0)
	_is_ceiling = parse_int(ent, "orientation", 0) == 1
	set_physics_process(_scanning)


## Passive mode. Still honoured while scanning, so a mapper can name a guard and fire it
## from a trigger as well as letting it hunt.
func trigger(activator: Node, _type: TriggerSystem.Type) -> void:
	if not activator or not is_instance_valid(activator):
		return
	if not NetworkManager.is_authority():
		return
	_comet(activator)


func _physics_process(delta: float) -> void:
	if not NetworkManager.is_authority():
		return
	_scan_timer -= delta
	if _scan_timer > 0:
		return
	_scan_timer = SCAN_INTERVAL
	_scan_for_enemies()


func _scan_for_enemies() -> void:
	var space := get_world_3d().direct_space_state
	var crystal_pos := global_position
	var now := Time.get_ticks_msec() / 1000.0
	_forget_freed_targets()

	# Raycast from crystal center (offset away from mounting surface)
	var ray_origin := crystal_pos + Vector3(0, -1.0 if _is_ceiling else 1.0, 0)

	for node in get_tree().get_nodes_in_group("damageable"):
		if not is_instance_valid(node) or not node.is_inside_tree():
			continue
		if node.get("is_dead"):
			continue
		# Same rule as Combat.find_homing_target: "unhunted" is killable but never hunted. It
		# needs saying twice because a guard given team_no "0" skips the team filter below and
		# would otherwise comet the sheep grazing in front of it, or the window behind them.
		if node.is_in_group("unhunted"):
			continue
		if _team != 0:
			var node_team: int = node.team if "team" in node else 0
			if node_team != _team:
				continue

		# Reject targets on the wrong side (ceiling: only below, floor: only above)
		var target_center: Vector3 = SpatialQuery.collision_center(node)
		if _is_ceiling and target_center.y > crystal_pos.y:
			continue
		if not _is_ceiling and target_center.y < crystal_pos.y:
			continue

		# Range check
		var dist := crystal_pos.distance_to(target_center)
		if dist > RANGE:
			continue

		# Per-target cooldown
		var id := node.get_instance_id()
		if _last_fire_time.has(id) and now < _last_fire_time[id] + FIRE_COOLDOWN:
			continue

		# Visibility check — ray from crystal center to target chest
		var params := PhysicsRayQueryParameters3D.create(ray_origin, target_center)
		params.collision_mask = GameConsts.MASK_WORLD
		var excludes: Array[RID] = []
		if node is CollisionObject3D:
			excludes.append(node.get_rid())
		# Exclude the guard's own collision bodies
		for child in get_children():
			if child is CollisionObject3D:
				excludes.append(child.get_rid())
		params.exclude = excludes
		# NOT hit_from_inside, even though "the crystal is buried, it cannot see you" is
		# the semantically tidy reading. A guard's origin is routinely inside the
		# brushwork it is mounted on, and the 1 m offset above does not clear it:
		# measured across the seven maps that field guards, 22 of 35 ray origins are
		# inside world solid (all 12 on ww_december, all 4 on ww_pushed). Now that hop
		# reports a surface a ray starts inside, honouring that here would read every
		# target as blocked and silently retire two thirds of the shipped guards.
		params.hit_back_faces = true
		var result := space.intersect_ray(params)
		if not result.is_empty():
			continue

		if _comet(node):
			_last_fire_time[id] = now
			return  # one comet per scan


## The guard contract, shared by both modes. A comet one-shots (200 dmg) and takes ~1.6s
## to fall, so don't rain on someone already dead or already under one — two overlapping
## volumes, or a scanner and a volume covering the same spawn, used to comet a player who
## was already dead ("died and got another one"). No owner: owners are blast-excluded and
## the guard comet has to damage the intruder.
func _comet(target: Node) -> bool:
	if target.get("is_dead") or Comet.has_incoming(target):
		return false
	Comet.spawn(target, null)
	return true


## Cooldowns outlive their target otherwise: a player who disconnects or dies out
## of the map leaves an entry that is never read again and never dropped.
func _forget_freed_targets() -> void:
	for id in _last_fire_time.keys():
		if not is_instance_valid(instance_from_id(id)):
			_last_fire_time.erase(id)
