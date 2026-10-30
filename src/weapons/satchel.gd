class_name Satchel
extends RigidBody3D

## Thrown satchel entity — bounces via engine physics, detonates on fuse timer.
## Every wizard has one, activated by F key. Not a weapon slot.

const THROW_SPEED := 12.0
const FUSE_TIME := 3.0
const AOE_RADIUS := 3.2  # 128 GS * 0.025
const WIND_KNOCKBACK := 20.0  # 800 GS u/s at the blast centre
const COLLISION_RADIUS := 0.05
## Degrees/sec the pouch tumbles while airborne. The HUD icons spin at this too.
const SPIN_SPEED := 720.0

var element: int = GameConsts.Element.FIRE
var owner_node: Node3D
var team := 0

var _entity := EntityBehavior.new()
var _scene_root: Node
var _fuse_remaining := FUSE_TIME
var _det_count := 0
var _det_max := 1
var _det_interval := 0.0
var _det_timer := 0.0
var _model: Node3D

# Per-element specs: [explosion_count, det_interval, min_damage, max_damage, damage_type]
enum Spec { COUNT, INTERVAL, MIN_DMG, MAX_DMG, DMG_TYPE }

const SPECS := {
	GameConsts.Element.FIRE:      [1, 0.0, 0.0, 0.0, GameConsts.DamageType.FIRE],
	GameConsts.Element.ICE:       [1, 0.0, 0.0, 0.0, GameConsts.DamageType.ICE],
	GameConsts.Element.LIGHTNING: [3, 0.4, 40.0, 75.0, GameConsts.DamageType.LIGHTNING],
	GameConsts.Element.EARTH:     [3, 0.5, 40.0, 75.0, GameConsts.DamageType.PHYSICAL],
	GameConsts.Element.LIFE:      [1, 0.0, 10.0, 50.0, GameConsts.DamageType.PHYSICAL],
	GameConsts.Element.WIND:      [1, 0.0, 10.0, 50.0, GameConsts.DamageType.PHYSICAL],
	GameConsts.Element.NATURE:    [1, 0.0, 10.0, 50.0, GameConsts.DamageType.PHYSICAL],
	GameConsts.Element.DEATH:     [1, 0.0, 10.0, 50.0, GameConsts.DamageType.DEATH],
	GameConsts.Element.ARCHMAGE:  [1, 0.0, 0.0, 0.0, -1],
}

const ELEMENT_SOUNDS := {
	GameConsts.Element.FIRE: "spells/satchels/pyro_satchel.wav",
	GameConsts.Element.ICE: "spells/satchels/aqua_satchel.wav",
	GameConsts.Element.LIGHTNING: "spells/satchels/volt_satchel.wav",
	GameConsts.Element.EARTH: "spells/satchels/geo_satchel.wav",
	GameConsts.Element.LIFE: "spells/satchels/life_satchel.wav",
	GameConsts.Element.WIND: "spells/satchels/aero_satchel.wav",
	GameConsts.Element.NATURE: "spells/satchels/burr_satchel.wav",
	GameConsts.Element.DEATH: "spells/satchels/necro_satchel.wav",
	GameConsts.Element.ARCHMAGE: "spells/satchels/life_satchel.wav",
}

# death element uses the "poison" model
const ELEMENT_MODELS := {
	GameConsts.Element.FIRE: "fire",
	GameConsts.Element.ICE: "ice",
	GameConsts.Element.LIGHTNING: "lightning",
	GameConsts.Element.EARTH: "earth",
	GameConsts.Element.LIFE: "life",
	GameConsts.Element.WIND: "wind",
	GameConsts.Element.NATURE: "nature",
	GameConsts.Element.DEATH: "poison",
	GameConsts.Element.ARCHMAGE: "life",
}

const FUSE_TIMES := {
	GameConsts.Element.FIRE: FUSE_TIME,
	GameConsts.Element.ICE: FUSE_TIME,
	GameConsts.Element.LIGHTNING: FUSE_TIME,
	GameConsts.Element.EARTH: FUSE_TIME,
	GameConsts.Element.LIFE: FUSE_TIME,
	GameConsts.Element.WIND: FUSE_TIME,
	GameConsts.Element.NATURE: FUSE_TIME,
	GameConsts.Element.DEATH: FUSE_TIME,
	GameConsts.Element.ARCHMAGE: 0.05,
}


## Warm every element's pouch and blast at map load, not on the first throw.
static func precache() -> void:
	for model_name in ELEMENT_MODELS.values():
		AssetLoader.precache_model("models/satchels/%s.mdl" % model_name)
	for sound_path in ELEMENT_SOUNDS.values():
		SoundSystem.precache(sound_path)
	AssetLoader.precache_sprite("sprites/fexplo1.spr")  # fire spiral
	SoundSystem.precache(FireSpiral.SOUND)
	AssetLoader.precache_model("models/npc/cocklebur.mdl")
	SoundSystem.precache("spells/satchels/cocklebur.wav")
	SatchelBurstEffect.precache()


func setup(data: Dictionary, is_host := true) -> void:
	position = data.get("position", Vector3.ZERO)
	linear_velocity = data.get("velocity", Vector3.ZERO)
	element = data.get("element", GameConsts.Element.FIRE)
	team = data.get("team", 0)
	_fuse_remaining = data.get("fuse_remaining", FUSE_TIME)
	_entity.initialize(self, is_host)
	add_to_group("projectile")
	add_child(BlobShadow.new(0.25))


func _ready() -> void:
	_scene_root = get_tree().current_scene

	collision_layer = GameConsts.MASK_DYNAMIC if _entity.is_host else 0
	collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY | GameConsts.MASK_PLAYER
	continuous_cd = true  # prevent tunneling through thin floors
	lock_rotation = true
	# Deliberately 9.8, not the world's 20 — preserves the satchel's original tuned throw arc.
	gravity_scale = 9.8 / 20.0
	var phys_mat := PhysicsMaterial.new()
	phys_mat.bounce = 0.55
	physics_material_override = phys_mat
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = COLLISION_RADIUS
	col.shape = sphere
	add_child(col)

	var model_name: String = ELEMENT_MODELS.get(element, "fire")
	_model = AssetLoader.load_model("models/satchels/%s.mdl" % model_name)
	if _model:
		_model.position.y = -COLLISION_RADIUS * 2
		add_child(_model)

	# Creation + replication handled by the dynamic-entity MultiplayerSpawner (spawn_projectile).


func _physics_process(delta: float) -> void:
	if _entity.is_host:
		_host_physics(delta)
	_update_visuals(delta)


func _host_physics(delta: float) -> void:
	# It outlives its caster, so a freed owner must not reach target filtering or damage credit:
	# a freed object at a typed `attacker: Node3D` parameter drops the whole damage call.
	if not is_instance_valid(owner_node):
		owner_node = null
	_fuse_remaining -= delta
	if _fuse_remaining <= 0.0 and _det_count == 0:
		var spec: Array = SPECS.get(element, SPECS[GameConsts.Element.FIRE])
		_det_max = spec[Spec.COUNT]
		_det_interval = spec[Spec.INTERVAL]
		_det_timer = 0.0
		_det_count = 0
		_detonate_tick()
	elif _det_count > 0 and _det_count < _det_max:
		_det_timer += delta
		if _det_timer >= _det_interval:
			_det_timer -= _det_interval
			_detonate_tick()

	if global_position.y < -100.0:
		_die()


func _update_visuals(delta: float) -> void:
	if _model and linear_velocity.length() > 1.0:
		_model.rotate_y(deg_to_rad(SPIN_SPEED) * delta)


## Spawn detonation effects as synced entities — clients see them via dynamic entity system.
func _spawn_effects(pos := Vector3.ZERO) -> void:
	if not is_instance_valid(_scene_root):
		return
	if pos == Vector3.ZERO:
		pos = global_position
	var online := NetworkManager.is_online()
	var sound_path: String = ELEMENT_SOUNDS.get(element, "")
	if not sound_path.is_empty():
		SoundSystem.play_3d(sound_path, pos)
	match element:
		GameConsts.Element.ICE, GameConsts.Element.ARCHMAGE, GameConsts.Element.NATURE:
			pass  # no explosion visual
		GameConsts.Element.LIGHTNING:
			SpotBoltStrike.summon(pos, 1.0)
		GameConsts.Element.EARTH:
			ExplosionEffect.spawn(_scene_root, pos, online,
				"", Color(0.8, 0.5, 0.2), "", 1.0,
				Color(0.8, 0.5, 0.2, 0.9))
		GameConsts.Element.LIFE, GameConsts.Element.WIND, GameConsts.Element.DEATH:
			SatchelBurstEffect.spawn(_scene_root, pos, element, online)
		_:
			ExplosionEffect.spawn(_scene_root, pos, online)


func _detonate_tick() -> void:
	_det_count += 1
	var is_last := _det_count >= _det_max

	match element:
		GameConsts.Element.FIRE:
			_detonate_fire()
		GameConsts.Element.ICE:
			_detonate_ice()
		GameConsts.Element.LIGHTNING:
			_detonate_lightning()
		GameConsts.Element.EARTH:
			_detonate_earth()
		GameConsts.Element.LIFE:
			_detonate_life()
		GameConsts.Element.WIND:
			_detonate_wind()
		GameConsts.Element.NATURE:
			_detonate_nature(is_last)
		GameConsts.Element.DEATH:
			_detonate_death()
		GameConsts.Element.ARCHMAGE:
			_detonate_archmage()

	if is_last:
		_die()


func _detonate_fire() -> void:
	SoundSystem.play_3d("spells/satchels/pyro_satchel.wav", global_position)
	if is_instance_valid(_scene_root):
		# start_angle is random but visual, so it's computed here and sent in spawn data —
		# spawn_function runs on both peers and they must agree on the angle.
		NetworkManager.spawn_projectile("res://src/monsters/fire_spiral.gd", {
			"position": global_position + Vector3(0, 0.5, 0),
			"team": team,
			"start_angle": randf() * TAU,
		}, owner_node)


func _detonate_ice() -> void:
	if not is_instance_valid(owner_node):
		_die()
		return

	var dest := _find_ice_teleport_dest()
	if dest == Vector3.INF:
		Log.info("Ice satchel fizzled — no room at target")
		return

	# teleport_to also keeps server-movement sim state (position/velocity/queue) consistent,
	# so PVS + replication follow even while the owner is dead.
	_spawn_effects()
	owner_node.teleport_to(dest, owner_node.rotation.y)
	# send_to_owner dispatches _on_teleport_player locally too, so the host's own
	# first-person view snaps along with the puppet.
	var owner_pid: int = owner_node.get("peer_id")
	NetworkManager.send_to_owner(owner_pid, &"teleport_player",
		[dest, owner_node.rotation.y])


## Try the satchel position and nearby offsets; return the first clear spot or Vector3.INF.
func _find_ice_teleport_dest() -> Vector3:
	var space := get_world_3d().direct_space_state
	# Slightly shrunken capsule — gives tolerance near walls/ceilings
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.6
	capsule.radius = 0.3
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = capsule
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.collision_mask = GameConsts.MASK_WORLD_AND_CLIP
	if owner_node is CharacterBody3D:
		params.exclude = [owner_node.get_rid()]

	var offsets := [
		Vector3.ZERO,
		Vector3(0, 0.5, 0),
		Vector3(0, 1.0, 0),
		Vector3(0.4, 0, 0),
		Vector3(-0.4, 0, 0),
		Vector3(0, 0, 0.4),
		Vector3(0, 0, -0.4),
	]
	for offset in offsets:
		var test_pos = global_position + offset
		params.transform = Transform3D(Basis.IDENTITY, test_pos + Vector3(0, 0.8, 0))
		if space.intersect_shape(params, 1).is_empty():
			return test_pos
	return Vector3.INF


func _detonate_lightning() -> void:
	var spec: Array = SPECS[GameConsts.Element.LIGHTNING]
	_spawn_effects()
	_apply_aoe(spec[Spec.MIN_DMG], spec[Spec.MAX_DMG], spec[Spec.DMG_TYPE])


func _detonate_earth() -> void:
	var spec: Array = SPECS[GameConsts.Element.EARTH]
	_spawn_effects()
	_apply_aoe(spec[Spec.MIN_DMG], spec[Spec.MAX_DMG], spec[Spec.DMG_TYPE])


func _detonate_life() -> void:
	var spec: Array = SPECS[GameConsts.Element.LIFE]
	var damage := randf_range(spec[Spec.MIN_DMG], spec[Spec.MAX_DMG])
	_spawn_effects()
	for node in SpatialQuery.nodes_near(&"damageable", global_position, AOE_RADIUS):
		var center: Vector3 = SpatialQuery.collision_center(node)
		var dist := global_position.distance_to(center)
		if dist > AOE_RADIUS:
			continue
		var node_team: int = node.team if "team" in node else 0
		if Teams.teams_friendly(team, node_team):
			if node.has_method("heal"):
				node.heal(damage, owner_node)
		else:
			if node.has_method("take_damage"):
				node.take_damage(damage, spec[Spec.DMG_TYPE], owner_node)


func _detonate_wind() -> void:
	var spec: Array = SPECS[GameConsts.Element.WIND]
	_spawn_effects()
	# The thrower is blown around by their own satchel — that is the aeromancer's rocket jump.
	var pushed := Combat.apply_aoe_knockback(
		get_world_3d().direct_space_state, global_position, WIND_KNOCKBACK, AOE_RADIUS, owner_node, 0.6)
	# Damage rides the same falloff, and the same team and line-of-sight decisions.
	for node in pushed:
		if node.has_method("take_damage"):
			node.take_damage(randf_range(spec[Spec.MIN_DMG], spec[Spec.MAX_DMG]) * pushed[node], spec[Spec.DMG_TYPE], owner_node)


func _detonate_nature(is_last: bool) -> void:
	var spec: Array = SPECS[GameConsts.Element.NATURE]
	_spawn_effects()
	_apply_aoe(spec[Spec.MIN_DMG], spec[Spec.MAX_DMG], spec[Spec.DMG_TYPE])
	# Spawn cockleburrs on last tick
	if is_last and is_instance_valid(_scene_root):
		for i in range(3):
			var offset := Vector3(randf_range(-0.5, 0.5), 0.5, randf_range(-0.5, 0.5))
			NetworkManager.spawn_projectile("res://src/monsters/cockleburr.gd", {
				"position": global_position + offset,
				"team": team,
			}, owner_node)


func _detonate_death() -> void:
	var spec: Array = SPECS[GameConsts.Element.DEATH]
	_spawn_effects()
	_apply_aoe(spec[Spec.MIN_DMG], spec[Spec.MAX_DMG], spec[Spec.DMG_TYPE])


func _detonate_archmage() -> void:
	_spawn_effects()
	if is_instance_valid(owner_node) and owner_node.has_method("heal"):
		owner_node.heal(60.0)


func _apply_aoe(min_dmg: float, max_dmg: float, damage_type: int, pos := Vector3.ZERO) -> void:
	if pos == Vector3.ZERO:
		pos = global_position
	var damage := randf_range(min_dmg, max_dmg)
	var space := get_world_3d().direct_space_state
	Combat.apply_aoe_damage(
		space, pos, damage, AOE_RADIUS, {},
		damage_type, owner_node
	)



## Remove a live satchel without detonating it (owner respawn / round reset).
func cancel() -> void:
	_die()


func _die() -> void:
	_entity.destroy()


func _exit_tree() -> void:
	pass
