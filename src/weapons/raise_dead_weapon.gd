class_name RaiseDeadWeapon
extends Weapon

## Raise dead — the Wizard Wars combo spell "weapon_skeletonspell". It is not thrown at anything.
## It goes off where the caster stands and takes every body within 10 m: enemy wizards it can see
## are killed outright and dragged back up as skeletons fighting for the caster, and any corpse
## already lying there is raised the same way.
##
## Which makes it the only spell in the set that is worth more the worse the fight has been
## going. It also refuses rather than wasting itself: with nothing to raise, the book stays in
## the loadout, and a corpse with someone standing over it stops the whole cast.

const SCALE := GameConsts.SCALE_FACTOR
const RADIUS := 400.0 * SCALE          # 10 m around the caster
const GUARD_RADIUS := 50.0 * SCALE     # 1.25 m — a body this well watched cannot be taken
const KILL_DAMAGE := 1000.0            # enough to put down anything wearing a wizard
const COOLDOWN := 2.0
const CAST_SOUND := "spells/combos/raisedead_cast.wav"
const NO_BODY_MESSAGE := "There are no bodies here to raise!"
const TOO_CLOSE_MESSAGE := "Someone is standing over that body!"


func _init() -> void:
	cooldown = COOLDOWN
	# No mana: the book itself is the cost, and it's gone after one cast (see fire).


func precache() -> void:
	Skeleton.precache()
	SoundSystem.precache(CAST_SOUND)


## Everything the cast would take: enemy wizards in the open, and corpses lying about. Guarded
## corpses come back as a refusal rather than a body, which is what stops the spell being cast
## into a scrum around a fresh kill.
func _harvest(attacker: Node3D) -> Dictionary:
	var bodies: Array[Vector3] = []
	var victims: Array[Node3D] = []
	var team := int(attacker.get("team"))
	var from: Vector3 = SpatialQuery.collision_center(attacker)

	for node in SpatialQuery.nodes_near(&"damageable", from, RADIUS):
		if node == attacker or not is_instance_valid(node) or not (node is Node3D):
			continue
		if not node.is_inside_tree() or node.get("is_dead"):
			continue
		# Wizards only — a plant or a tornado has no body to raise. Carrying a peer_id is what
		# separates a player (bots included, on negative ids) from a summon, the same test
		# Combat.collect_hitscan_excludes leans on.
		if not ("peer_id" in node):
			continue
		if Teams.summon_spares(team, attacker, node):
			continue
		var center: Vector3 = SpatialQuery.collision_center(node)
		if from.distance_to(center) > RADIUS:
			continue
		# It has to be able to see them — the original traced from the caster and took the body
		# only if nothing but the victim was in the way.
		var ray := Combat.raycast_world(attacker, from, (center - from).normalized(),
				from.distance_to(center), attacker.get_rid())
		if not ray.result.is_empty():
			continue
		victims.append(node)
		bodies.append((node as Node3D).global_position)

	var corpses: Array[Node] = []
	for corpse in attacker.get_tree().get_nodes_in_group("corpses"):
		if not is_instance_valid(corpse) or not (corpse is Node3D):
			continue
		var pos: Vector3 = (corpse as Node3D).global_position
		if from.distance_to(pos) > RADIUS:
			continue
		if _guarded(pos):
			return {"blocked": true, "bodies": bodies, "victims": victims, "corpses": []}
		bodies.append(pos)
		corpses.append(corpse)
	return {"blocked": false, "bodies": bodies, "victims": victims, "corpses": corpses}


## Anyone at all standing over a body, their own side or not.
func _guarded(pos: Vector3) -> bool:
	for node in SpatialQuery.nodes_near(&"damageable", pos, GUARD_RADIUS):
		if not is_instance_valid(node) or not ("peer_id" in node) or node.get("is_dead"):
			continue
		if SpatialQuery.collision_center(node).distance_to(pos) <= GUARD_RADIUS:
			return true
	return false


func can_fire(attacker: Node3D, _aim_dir: Vector3 = Vector3.ZERO) -> bool:
	var harvest := _harvest(attacker)
	if not harvest.blocked and not (harvest.bodies as Array).is_empty():
		return true
	SoundSystem.play_3d("misc/talk.wav", attacker.global_position)
	# Only the caster's own view has a HUD, so the message is shown from there rather than
	# rpc'd back from the server's identical refusal.
	if attacker is LocalPlayer:
		if Game.hud:
			Game.hud.show_center_message(
				TOO_CLOSE_MESSAGE if harvest.blocked else NO_BODY_MESSAGE,
				Color(0.7, 0.1, 0.1), 3.0, true)
	return false


func fire(attacker: Node3D, _aim_from: Vector3 = Vector3.INF, _aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if not NetworkManager.is_authoritative_fire(attacker):
		_fire_tail(attacker)  # client plays the cast; the host owns the raising
		return true

	var harvest := _harvest(attacker)
	if harvest.blocked or (harvest.bodies as Array).is_empty():
		return false  # refused, so the book is not spent — see can_fire

	_spend(attacker)

	# Killed first, then raised: a wizard taken by this does not get to see it coming.
	for victim in harvest.victims:
		if victim.has_method("take_damage"):
			victim.take_damage(KILL_DAMAGE, GameConsts.DamageType.RAISING, attacker)
	for corpse in harvest.corpses:
		if is_instance_valid(corpse):
			corpse.queue_free()  # the body is used up by the raising

	for spot in harvest.bodies:
		NetworkManager.spawn_projectile("res://src/monsters/skeleton.gd", {
			"sync_state": true,  # its death is a one-shot event, not a convergent property
			"position": spot,
			# Facing back at the wizard who raised it, which is where the fight is.
			"yaw": atan2(attacker.global_position.x - spot.x,
				attacker.global_position.z - spot.z),
			"owner_peer_id": int(attacker.get("peer_id")),
			"team": int(attacker.get("team")),
		}, attacker)

	SoundSystem.play_3d(CAST_SOUND, attacker.global_position)
	_fire_tail(attacker)
	return true


## Take the spell back out of the caster's loadout — one book, one raising. Deferred because the
## server is mid-fire: it still has to stamp last_fired_weapon_idx and broadcast the shot by slot
## index, and dropping a slot now would renumber the loadout under both.
func _spend(attacker: Node3D) -> void:
	if attacker.has_method("revoke_weapon"):
		attacker.call_deferred(&"revoke_weapon", SpawnRegistry.name_for(get_script()))


func cleanup(_attacker: Node3D) -> void:
	pass  # nothing to tear down: the skeletons are the world's once raised, not the loadout's
