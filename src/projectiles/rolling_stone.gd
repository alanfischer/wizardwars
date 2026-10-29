class_name RollingStone
extends RigidBody3D

## Rolling stone projectile — thrown forward, affected by gravity, bounces off
## surfaces losing 25% speed each time. Deals 80 damage on direct hit.

const DAMAGE := 80.0
## ROLLINGSTONE_VELOCITY, 700 GS * 0.025. Launch speed, and the reference the damage scale
## and the animation rate are both measured against.
const SPEED := 17.5
const MIN_BOUNCE_SPEED := SPEED / 8.0  # below this, no bounce effect
const FADE_TIME := 0.6
## The hole a stone punches in a pool, against LiquidSounds' 1.0 = a person.
const SPLASH_SIZE := 0.4

var direction := Vector3.FORWARD
var speed := SPEED
var lifetime := 2.0
var exclude_rid: RID
var owner_node: Node3D

var _entity := EntityBehavior.new()
var _age := 0.0
var _was_in_contact := false
var _model: Node3D
var _anim_player: AnimationPlayer
var _entry := LiquidEntry.new()
var _rng := RandomNumberGenerator.new()


func setup(data: Dictionary, is_host := true) -> void:
	position = data.get("position", Vector3.ZERO)
	direction = data.get("direction", Vector3.FORWARD).normalized()
	speed = data.get("speed", SPEED)
	lifetime = data.get("lifetime", 2.0)
	exclude_rid = data.get("exclude_rid", RID())
	_entity.initialize(self, is_host)
	_entry.size = SPLASH_SIZE
	linear_velocity = direction * speed
	add_to_group("projectile")
	contact_monitor = true
	max_contacts_reported = 1
	add_child(BlobShadow.new(0.3))



func _ready() -> void:
	collision_layer = GameConsts.MASK_DYNAMIC if _entity.is_host else 0
	collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY | GameConsts.MASK_PLAYER
	freeze = not _entity.is_host
	continuous_cd = true
	# gravity_scale stays 1.0 — the project default gravity is the world's 20 m/s².
	var physics_material := PhysicsMaterial.new()
	physics_material.bounce = 0.75
	physics_material_override = physics_material
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.2
	col.shape = sphere
	add_child(col)

	_model = AssetLoader.load_model("models/rollingstone.mdl")
	if _model:
		add_child(_model)
		_anim_player = _model.find_child("AnimationPlayer")
		_entity.set_anim_player(_anim_player)
		if _anim_player:
			var anims := _anim_player.get_animation_list()
			if anims.size() > 0:
				var anim_name: String = anims[0]
				var anim_res := _anim_player.get_animation(anim_name)
				anim_res.loop_mode = Animation.LOOP_LINEAR
				_anim_player.play(anim_name)

	SoundSystem.play_3d("spells/stone_cast.wav", global_position)

	# Creation + replication handled by the dynamic-entity MultiplayerSpawner (spawn_projectile).


func _physics_process(delta: float) -> void:
	# It outlives its caster, so a freed owner must not reach target filtering or damage credit:
	# a freed object at a typed `attacker: Node3D` parameter drops the whole damage call.
	if not is_instance_valid(owner_node):
		owner_node = null
	var age = _age
	_age += delta
	if age < lifetime and _age >= lifetime:
		var tween := create_tween()
		tween.tween_method(func(alpha): AssetLoader.set_model_alpha(_model, alpha), 1.0, 0.0, FADE_TIME)
		tween.tween_callback(_destroy)
		return

	if _anim_player and _anim_player.is_playing():
		var new_scale := linear_velocity.length() / speed
		if not is_equal_approx(_anim_player.speed_scale, new_scale):
			_anim_player.speed_scale = new_scale


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not _entity.is_host:
		return
	# Broadcast: a client's stone is frozen and runs none of this.
	_entry.check(self, state.transform.origin, state.get_linear_velocity().length(), _rng, true)
	var in_contact := state.get_contact_count() > 0
	if in_contact and not _was_in_contact:
		var impact_speed := state.get_linear_velocity().length()
		var impact_pos := state.get_contact_local_position(0)
		var collider := state.get_contact_collider_object(0)
		_on_physics_collision(impact_pos, collider, impact_speed)
	_was_in_contact = in_contact


func _on_physics_collision(_pos: Vector3, target: Object, impact_speed: float) -> void:
	if impact_speed > MIN_BOUNCE_SPEED:
		SoundSystem.play_3d("spells/stone_bounce.wav", global_position)
		StoneDustEffect.spawn(get_tree().current_scene, global_position, NetworkManager.is_online())

	if target and target.is_in_group("damageable"):
		if not target.get("is_dead") and not Teams.nodes_friendly(owner_node, target):
			var damage := DAMAGE * (impact_speed / speed)
			target.take_damage(damage, GameConsts.DamageType.PHYSICAL, owner_node)
			_destroy()


func _destroy() -> void:
	_entity.destroy()


## Animation rides the shared NetInterp slot (see EntityBehavior.set_anim_player).
func net_sync_properties() -> PackedStringArray:
	return PackedStringArray(["NetInterp:net_anim"])
