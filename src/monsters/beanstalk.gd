class_name Beanstalk
extends Node3D

const SCALE := GameConsts.SCALE_FACTOR
const HEIGHT := 45.0 * SCALE        # 1.125m per segment
const AREA := 32.0 * SCALE          # 0.8m collision width
const HEALTH := 80.0
const HEALTH_REGEN := 5.0             # HP per tick (simplified, no illumination query)
const HEALTH_REGEN_TIME := 1.0

var owner_node: Node3D
var owner_peer_id := -1
var team: int = GameConsts.Team.NONE
var next_segment: Beanstalk  # segment stacked above us
var prev_segment: Beanstalk  # segment below us (toward root)

var _is_first := true  # first segment in chain (plays sound)
var _summon := SummonBehavior.new()
var _model: Node3D
var _ladder_area: Area3D
var _collision_body: StaticBody3D


func setup(data: Dictionary, is_host := true) -> void:
	owner_peer_id = data.get("owner_peer_id", -1)
	team = data.get("team", GameConsts.Team.NONE)
	_is_first = data.get("is_first", false)
	_summon.setup(self, data, is_host, HEALTH, _kill_chain)
	_summon.set_regen(HEALTH_REGEN, HEALTH_REGEN_TIME)


func _ready() -> void:
	_model = AssetLoader.load_model("models/beanstalk.mdl")
	if _model:
		_model.rotation_degrees.y = 90.0
		add_child(_model)
		AssetLoader.set_model_alpha(_model, 0.0)
		create_tween().tween_method(func(alpha): AssetLoader.set_model_alpha(_model, alpha), 0.0, 1.0, 1.25)

	# LAYER_LADDER so the player's LadderDetector picks it up
	_ladder_area = Area3D.new()
	_ladder_area.collision_layer = GameConsts.MASK_LADDER
	_ladder_area.collision_mask = 0
	_ladder_area.monitorable = true
	_ladder_area.monitoring = false
	var ladder_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# shorter than the segment (stand on top), wider than the trunk (jumping detaches easily)
	var ladder_height := HEIGHT * 0.9
	box.size = Vector3(AREA * 1.0, ladder_height, AREA * 1.0)
	ladder_shape.shape = box
	ladder_shape.position.y = ladder_height * 0.5
	_ladder_area.add_child(ladder_shape)
	add_child(_ladder_area)

	# solid trunk — blocks movement, takes raycast damage
	_collision_body = StaticBody3D.new()
	_collision_body.collision_layer = GameConsts.MASK_WORLD
	_collision_body.collision_mask = 0
	var col_shape := CollisionShape3D.new()
	var col_box := BoxShape3D.new()
	col_box.size = Vector3(AREA * 0.5, HEIGHT, AREA * 0.5)
	col_shape.shape = col_box
	col_shape.position.y = HEIGHT * 0.5
	_collision_body.add_child(col_shape)
	_collision_body.set_meta("parent_entity", self)
	add_child(_collision_body)

	if _is_first:
		SoundSystem.spawn_on(self, "spells/beanstalk_grow.wav")

	# replication is handled by the dynamic-entity MultiplayerSpawner (spawn_projectile)


func _physics_process(delta: float) -> void:
	# It outlives its caster, so a freed owner must not reach the plant registry or damage
	# credit: a freed object at a typed parameter drops the whole call.
	if not is_instance_valid(owner_node):
		owner_node = null

	_summon.tick(delta)


## Weakest segment in the chain — any segment dying takes the whole stalk down.
func chain_health() -> Vector2:
	var seg: Beanstalk = self
	while seg.prev_segment and is_instance_valid(seg.prev_segment):
		seg = seg.prev_segment
	var worst := Vector2(HEALTH, HEALTH)
	while seg:
		if seg._summon.health < worst.x:
			worst = Vector2(seg._summon.health, seg._summon.max_health)
		seg = seg.next_segment if is_instance_valid(seg.next_segment) else null
	return worst


func take_damage(amount: float, _type: int = GameConsts.DamageType.PHYSICAL, attacker: Node3D = null) -> void:
	_summon.take_damage(amount, _type, attacker)


func _kill_chain(notify_owner := true) -> void:
	var root_seg := self
	while root_seg.prev_segment and is_instance_valid(root_seg.prev_segment):
		root_seg = root_seg.prev_segment

	var owner_plants := PlantBehavior.of(owner_node)
	if owner_plants:
		owner_plants.on_beanstalk_destroyed()

	# only when destroyed by enemies, not by the owner replacing it
	if notify_owner:
		_summon.tell_owner(owner_peer_id, "Your beanstalk was destroyed!")

	var seg := root_seg
	while seg:
		var next = seg.next_segment if is_instance_valid(seg) else null
		seg._summon.destroy()
		seg = next


## Outward climbing normal — horizontal direction from center toward the player.
func get_ladder_normal(player_pos: Vector3) -> Vector3:
	var to_player := player_pos - global_position
	to_player.y = 0.0
	if to_player.length_squared() < 0.001:
		return Vector3.BACK
	return to_player.normalized()
