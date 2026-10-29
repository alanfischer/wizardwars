class_name BeanstalkWeapon
extends Weapon

const SCALE := GameConsts.SCALE_FACTOR
const PLACE_DISTANCE := 80.0 * SCALE   # 2.0m forward
const SEGMENT_HEIGHT := 45.0 * SCALE   # 1.125m per segment
const TRACE_HEIGHT := 45.0 * SCALE     # vertical trace range

var _is_building := false
var _last_segment: Beanstalk
var _stalk_root: Beanstalk  # bottom-most segment (for owner tracking)
var _platform: Node3D  # moving brush the stalk rides, if any

const COOLDOWN := 0.5
const MANA_COST := 5.0
const MISS_CONFIRM_WINDOW := 2.0

var _miss_confirm_time := -1.0


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.precache_model("models/beanstalk.mdl")
	SoundSystem.precache("spells/beanstalk_grow.wav")
	SoundSystem.precache("misc/talk.wav")

func can_fire(attacker: Node3D, _aim_dir: Vector3 = Vector3.ZERO) -> bool:
	if _is_building:
		return true

	var plants := PlantBehavior.of(attacker)
	if plants == null or not plants.has_beanstalk:
		return true

	# require a second press before destroying an existing beanstalk
	var now := Time.get_ticks_msec() / 1000.0
	if _miss_confirm_time > 0.0 and (now - _miss_confirm_time) < MISS_CONFIRM_WINDOW:
		if NetworkManager.is_authoritative_fire(attacker):
			plants.beanstalk._kill_chain(false)
		_miss_confirm_time = -1.0
		return true
	else:
		_miss_confirm_time = now
		SoundSystem.play_3d("misc/talk.wav", attacker.global_position)
		return false


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if not NetworkManager.is_authoritative_fire(attacker):
		if not _is_building:
			_freeze_player(attacker)
			_is_building = true
		_fire_tail(attacker)
		return true

	if not _is_building:
		_start_build(attacker, aim_from, aim_dir)
	else:
		_continue_build(attacker)

	_fire_tail(attacker)
	return true


func _start_build(attacker: Node3D, aim_from: Vector3, aim_dir: Vector3) -> void:
	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var forward = aim.aim_dir
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = -attacker.global_transform.basis.z
		forward.y = 0.0
	forward = forward.normalized()

	var base_pos: Vector3 = attacker.global_position + forward * PLACE_DISTANCE

	var top : Vector3 = base_pos + Vector3(0, TRACE_HEIGHT, 0)
	var ray = Combat.raycast_world(attacker, top, Vector3.DOWN, TRACE_HEIGHT * 2.0, attacker.get_rid())

	if ray.result.is_empty():
		return

	var ground_pos: Vector3 = ray.result.position
	_platform = GoldSrcEntity.get_mover_root(ray.result.get("collider"))

	var stalk := _create_segment(attacker, ground_pos, true)
	if not stalk:
		return

	_stalk_root = stalk
	_last_segment = stalk
	_is_building = true

	_freeze_player(attacker)

	var plants := PlantBehavior.of(attacker)
	if plants:
		plants.set_beanstalk(_stalk_root)


func _continue_build(attacker: Node3D) -> void:
	if not _last_segment or not is_instance_valid(_last_segment):
		_end_build(attacker)
		return

	var next_pos: Vector3 = _last_segment.global_position + Vector3(0, SEGMENT_HEIGHT, 0)

	var space := attacker.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		next_pos, next_pos + Vector3(0, SEGMENT_HEIGHT, 0),
		GameConsts.MASK_WORLD)
	# exclude own segments so the check doesn't block on itself
	var excludes: Array[RID] = []
	var seg := _stalk_root
	while seg and is_instance_valid(seg):
		if seg._collision_body:
			excludes.append(seg._collision_body.get_rid())
		seg = seg.next_segment
	query.exclude = excludes
	var result := space.intersect_ray(query)
	if not result.is_empty():
		return  # Blocked by ceiling

	var stalk := _create_segment(attacker, next_pos)
	if not stalk:
		return

	_last_segment.next_segment = stalk
	stalk.prev_segment = _last_segment
	_last_segment = stalk


func _create_segment(attacker: Node3D, pos: Vector3, is_first := false) -> Beanstalk:
	var team_val: int = int(attacker.get("team"))
	var peer_id: int = int(attacker.get("peer_id"))
	var stalk: Beanstalk = NetworkManager.spawn_projectile("res://src/monsters/beanstalk.gd", {
		"position": pos,
		"yaw": randf_range(-PI, PI),  # server-random, carried in spawn data for consistency
		"owner_peer_id": peer_id,
		"team": team_val,
		"is_first": is_first,
	}, attacker)
	if is_instance_valid(_platform):
		stalk.reparent(_platform, true)
	return stalk


func _freeze_player(attacker: Node3D) -> void:
	if "speed_multiplier" in attacker:
		attacker.set_meta("beanstalk_saved_speed", attacker.speed_multiplier)
		attacker.speed_multiplier = 0.0


func _unfreeze_player(attacker: Node3D) -> void:
	if "speed_multiplier" in attacker:
		var saved: float = attacker.get_meta("beanstalk_saved_speed", 1.0)
		attacker.speed_multiplier = saved
		if attacker.has_meta("beanstalk_saved_speed"):
			attacker.remove_meta("beanstalk_saved_speed")


func stop_firing(attacker: Node3D, _secondary: bool = false) -> void:
	if _is_building:
		_end_build(attacker)


func cleanup(attacker: Node3D) -> void:
	if _is_building:
		_end_build(attacker)


func _end_build(attacker: Node3D) -> void:
	if not _is_building:
		return
	_is_building = false
	_last_segment = null
	_platform = null
	_unfreeze_player(attacker)
