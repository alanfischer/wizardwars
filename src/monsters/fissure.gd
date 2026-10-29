class_name Fissure
extends Node3D

## Fissure entity — plays seq "long" 1s, then "wide" 1s, then detonates for 500 fire
## damage in a 3m radius, activates nearby GA_DETPACK_EXPLOSION goals, and dies.

const DAMAGE := 500.0
const RADIUS := 3.0
const PHASE_LONG_DURATION := 1.0
const PHASE_WIDE_DURATION := 1.0

var owner_node: Node3D

var _entity := EntityBehavior.new()
var _model: Node3D
var _anim_player: AnimationPlayer
var _age := 0.0
var _phase := 0  # 0 = long (seq 1), 1 = wide (seq 2), 2 = done
var _team: int = GameConsts.Team.NONE
var _direction := Vector3.FORWARD


func setup(data: Dictionary, is_host := true) -> void:
	position = data.get("position", Vector3.ZERO)
	_team = data.get("team", GameConsts.Team.NONE)
	_entity.initialize(self, is_host)

	var dir: Vector3 = data.get("direction", Vector3.FORWARD)
	if dir.length_squared() > 0.001:
		_direction = dir.normalized()

	# faces away from the caster: local -Z points along the aim direction
	transform.basis = Basis.looking_at(_direction, GeomUtil.safe_up(_direction))


func _ready() -> void:
	_model = AssetLoader.load_model("models/fissure.mdl")
	if _model:
		add_child(_model)
		_anim_player = _model.find_child("AnimationPlayer")
		_entity.set_anim_player(_anim_player)
		_play_seq(1)  # seq 1 = index 0 = going long

	# replication handled by the dynamic-entity MultiplayerSpawner (spawn_projectile)


func _physics_process(delta: float) -> void:
	# It outlives its caster, so a freed owner must not reach target filtering or damage credit:
	# a freed object at a typed `attacker: Node3D` parameter drops the whole damage call.
	if not is_instance_valid(owner_node):
		owner_node = null
	_age += delta

	match _phase:
		0:
			if _age >= PHASE_LONG_DURATION:
				_phase = 1
				_age -= PHASE_LONG_DURATION
				_play_seq(2)  # seq 2 = index 1 = going wide
		1:
			if _age >= PHASE_WIDE_DURATION:
				_phase = 2
				if _entity.is_host:
					_detonate()


## Plays by 0-based MDL sequence index, using ResourceConverter's sequences metadata for
## correct ordering and falling back to the animation-list index if that's absent.
func _play_seq(seq_index: int) -> void:
	if not _anim_player or not _model:
		return
	var anim_name := ""
	if _model.has_meta("sequences"):
		var seqs: Array = _model.get_meta("sequences")
		if seq_index < seqs.size():
			anim_name = seqs[seq_index]["name"]
	if anim_name.is_empty():
		var anims := _anim_player.get_animation_list()
		if seq_index >= anims.size():
			return
		anim_name = anims[seq_index]
	if not _anim_player.has_animation(anim_name):
		return
	var anim_res := _anim_player.get_animation(anim_name)
	anim_res.loop_mode = Animation.LOOP_NONE
	_anim_player.play(anim_name)


func _detonate() -> void:
	var origin := global_position

	# sound only, no sprite
	SoundSystem.play_3d("spells/fissure_boom.wav", origin)

	for node in SpatialQuery.nodes_near(&"damageable", origin, RADIUS):
		if not node.is_inside_tree():
			continue
		if node == owner_node:
			continue
		if Teams.nodes_friendly(owner_node, node):
			continue
		if node.get("is_dead"):
			continue
		var center: Vector3 = SpatialQuery.collision_center(node)
		if origin.distance_to(center) > RADIUS:
			continue
		if node.has_method("take_damage"):
			node.take_damage(DAMAGE, GameConsts.DamageType.FIRE, owner_node)

	for goal in GoalSystem.get_all_goals():
		if not (goal.goal_activation & TFGoalBase.GA_DETPACK_EXPLOSION):
			continue
		if goal.global_position.distance_to(origin) > RADIUS:
			continue
		if goal.has_method("goal_activate"):
			goal.goal_activate(owner_node)

	_die()


func _die() -> void:
	_entity.destroy()


## Animation rides the shared NetInterp slot (see EntityBehavior.set_anim_player).
func net_sync_properties() -> PackedStringArray:
	return PackedStringArray(["NetInterp:net_anim"])
