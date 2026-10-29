class_name ThornplantWeapon
extends Weapon

const SCALE := GameConsts.SCALE_FACTOR
const PLACE_DISTANCE := 80.0 * SCALE    # 2.0m forward
const TRACE_HEIGHT := 45.0 * SCALE      # vertical trace range
const UPGRADE_DISTANCE := 3.0           # max distance to upgrade existing plant
const UPGRADE_DOT := 0.5                # must be roughly looking toward plant


const COOLDOWN := 1.0
const MANA_COST := 75.0
const MISS_CONFIRM_WINDOW := 2.0
const HEAL_MIN_MANA := 1.0              # can attempt a partial heal with as little as 1 mana

var _miss_confirm_time := -1.0
var _last_actual_cost := MANA_COST      # what the most recent fire() actually spent


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	for model_path in ["models/npc/thornbush1.mdl", "models/npc/thornbush2.mdl", "models/npc/thornbush3.mdl",
			"models/bushgibs.mdl", "models/npc/spore.mdl"]:
		AssetLoader.precache_model(model_path)
	for sound_path in ["spells/beanstalk_grow.wav", "monster/thornplant/thornplant_shoot.wav",
			"monster/thornplant/sporehit.wav", "misc/talk.wav"]:
		SoundSystem.precache(sound_path)


## Own thornplant that's currently in range and being looked at, or null.
func _reachable_thornplant(attacker: Node3D, aim_dir: Vector3 = Vector3.ZERO) -> Thornplant:
	var plants := PlantBehavior.of(attacker)
	if plants == null or not plants.has_thornplant:
		# LocalPlayer never carries persistent-entity state itself online — set_thornplant()
		# only runs on the authoritative puppet. Fall back to it so the client-side mana
		# gate isn't blind to a plant it actually owns.
		var peer_id: int = attacker.get("peer_id") if "peer_id" in attacker else 0
		var puppet := NetworkManager.get_player(peer_id)
		if puppet and puppet != attacker:
			plants = PlantBehavior.of(puppet)
	if plants == null or not plants.has_thornplant:
		return null
	var plant: Thornplant = plants.thornplant
	if not is_instance_valid(plant):
		return null
	var aim := Combat.get_aim(attacker, Vector3.INF, aim_dir)
	var to_plant := plant.global_position - attacker.global_position
	if to_plant.length() > UPGRADE_DISTANCE:
		return null
	var dot: float = aim.aim_dir.normalized().dot(to_plant.normalized())
	if dot < UPGRADE_DOT:
		return null
	return plant


## Lowered only when the cast would just heal an injured plant, which can proceed
## with whatever mana is on hand rather than the full level-up cost.
func min_mana_to_fire(attacker: Node3D, aim_dir: Vector3 = Vector3.ZERO) -> float:
	var plant := _reachable_thornplant(attacker, aim_dir)
	if plant and not plant.is_growing() and plant.health < plant.max_health:
		return HEAL_MIN_MANA
	return mana_cost


func actual_mana_cost(_attacker: Node3D) -> float:
	return _last_actual_cost


func can_fire(attacker: Node3D, aim_dir: Vector3 = Vector3.ZERO) -> bool:
	var plants := PlantBehavior.of(attacker)
	if plants == null or not plants.has_thornplant:
		return true

	var plant: Thornplant = plants.thornplant
	var aim := Combat.get_aim(attacker, Vector3.INF, aim_dir)
	var to_plant := plant.global_position - attacker.global_position
	var dist := to_plant.length()

	if dist <= UPGRADE_DISTANCE:
		var dot: float = aim.aim_dir.normalized().dot(to_plant.normalized())
		if dot >= UPGRADE_DOT:
			if plant.is_growing():
				SoundSystem.play_3d("misc/talk.wav", attacker.global_position)
				return false
			if plant.level >= Thornplant.LEVELS.size() - 1 and plant.health >= plant.max_health:
				SoundSystem.play_3d("misc/talk.wav", attacker.global_position)
				return false  # maxed and undamaged — nothing to spend mana on
			return true

	# Too far or not looking — require a second press to confirm destroy
	var now := Time.get_ticks_msec() / 1000.0
	if _miss_confirm_time > 0.0 and (now - _miss_confirm_time) < MISS_CONFIRM_WINDOW:
		# destroy_plant()'s owner callback clears the player's plant ref
		plant.destroy_plant()
		_miss_confirm_time = -1.0
		return true
	else:
		_miss_confirm_time = now
		SoundSystem.play_3d("misc/talk.wav", attacker.global_position)
		return false


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	_last_actual_cost = mana_cost
	if not NetworkManager.is_authoritative_fire(attacker):
		_fire_tail(attacker)
		return true

	var aim := Combat.get_aim(attacker, aim_from, aim_dir)

	var plants := PlantBehavior.of(attacker)
	if plants and plants.has_thornplant:
		var current_plant: Thornplant = plants.thornplant
		var to_plant := current_plant.global_position - attacker.global_position
		var dist := to_plant.length()
		if dist <= UPGRADE_DISTANCE:
			var dot: float = aim.aim_dir.normalized().dot(to_plant.normalized())
			if dot >= UPGRADE_DOT:
				var attacker_mana: float = attacker.get("mana") if "mana" in attacker else 0.0
				_last_actual_cost = current_plant.upgrade(mana_cost, attacker_mana)
				_miss_confirm_time = -1.0
				_fire_tail(attacker)
				return true

	# Trace forward to find ground placement
	var forward: Vector3 = aim.aim_dir
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = -attacker.global_transform.basis.z
		forward.y = 0.0
	forward = forward.normalized()

	var base_pos: Vector3 = attacker.global_position + forward * PLACE_DISTANCE
	var top: Vector3 = base_pos + Vector3(0, TRACE_HEIGHT, 0)
	var ray := Combat.raycast_world(attacker, top, Vector3.DOWN, TRACE_HEIGHT * 2.0, attacker.get_rid())
	if ray.result.is_empty():
		_fire_tail(attacker)
		return true

	var ground_pos: Vector3 = ray.result.position
	var team_val: int = int(attacker.get("team"))
	var peer_id: int = int(attacker.get("peer_id"))

	var plant: Thornplant = NetworkManager.spawn_projectile("res://src/monsters/thornplant.gd", {
		"sync_state": true,  # ongoing anim/attack/level state rides sync_entity_state
		"position": ground_pos,
		"yaw": randf_range(-PI, PI),
		"owner_peer_id": peer_id,
		"team": team_val,
		"level": 0,
	}, attacker)
	if plant:
		var platform := GoldSrcEntity.get_mover_root(ray.result.get("collider"))
		if platform:
			plant.reparent(platform, true)

	_miss_confirm_time = -1.0

	if plants:
		plants.set_thornplant(plant)

	_fire_tail(attacker)
	return true


func stop_firing(_attacker: Node3D, _secondary: bool = false) -> void:
	pass


func cleanup(_attacker: Node3D) -> void:
	pass  # Thornplant cleanup handled by Player.cleanup_for_class_change()
