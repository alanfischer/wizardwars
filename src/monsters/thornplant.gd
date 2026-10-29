class_name Thornplant
extends Node3D

const LEVELS := [
	{ "hp": 100.0, "damage": 13.0, "fire_rate": 0.5, "range": 12.8, "touch_dmg": 10.0, "knockback": 0.0,
	  "model": "models/npc/thornbush1.mdl", "grow": "thornplant2_grow", "attack": "thornplant2_attack", "idle": "thornplant2_idle1" },
	{ "hp": 200.0, "damage": 15.0, "fire_rate": 0.375, "range": 19.2, "touch_dmg": 11.0, "knockback": 3.0,
	  "model": "models/npc/thornbush2.mdl", "grow": "thornplant2_2_grow", "attack": "thornplant2_2_attack", "idle": "thornplant2_2_idle1" },
	{ "hp": 300.0, "damage": 20.0, "fire_rate": 0.25, "range": 22.4, "touch_dmg": 13.0, "knockback": 7.0,
	  "model": "models/npc/thornbush3.mdl", "grow": "thornplant2_3_grow", "attack": "thornplant2_3_attack", "idle": "thornplant2_3_idle1" },
]

const HEALTH_REGEN := 3.0
const HEALTH_REGEN_TIME := 2.0
const SPORE_DAMAGE := 12.0
const SPORE_SPEED := 20.0  # 800 GS * 0.025
const TOUCH_COOLDOWN := 1.0

## 0-based index into LEVELS. Rides the snapshot (net_sync_properties) the way the original's model
## swap (SET_MODEL) rode the entity, so a client that first sees the plant after it grew builds the
## grown one. The setter is the client's apply point; the host regrows in upgrade().
var level := 0:
	set(value):
		if value == level:
			return
		level = value
		_stats = LEVELS[level]
		if is_node_ready() and not _summon.is_host:
			_regrow()
var owner_node: Node3D
var owner_peer_id := -1
var team: int = GameConsts.Team.NONE
var is_dead: bool:
	get: return _summon.is_dead
var health: float:
	get: return _summon.health
var max_health: float:
	get: return _summon.max_health

var _summon := SummonBehavior.new()
var _stats: Dictionary  # current LEVELS[level] entry
var _model: Node3D
var _anim_player: AnimationPlayer
var _collision_body: StaticBody3D
var _touch_area: Area3D
var _skip_fade := false
var _scan_timer := 0.0
var _touch_cooldowns: Dictionary = {}  # node -> time of last touch damage
var _attacking := false  # true while attack anim is playing
var _growing := true     # true while grow anim is playing


func setup(data: Dictionary, is_host := true) -> void:
	level = data.get("level", 0)
	_skip_fade = data.get("skip_fade", false)
	_stats = LEVELS[level]
	owner_peer_id = data.get("owner_peer_id", -1)
	team = data.get("team", GameConsts.Team.NONE)
	_summon.setup(self, data, is_host, _stats.hp, _die)
	_summon.set_regen(HEALTH_REGEN, HEALTH_REGEN_TIME)


func _ready() -> void:
	_load_model(_skip_fade)

	_collision_body = StaticBody3D.new()
	_collision_body.collision_layer = GameConsts.MASK_ENTITY
	_collision_body.collision_mask = 0
	var col_shape := CollisionShape3D.new()
	var col_box := BoxShape3D.new()
	col_box.size = Vector3(0.8, 1.2, 0.8)
	col_shape.shape = col_box
	col_shape.position.y = 0.6
	_collision_body.add_child(col_shape)
	_collision_body.set_meta("parent_entity", self)
	add_child(_collision_body)

	_touch_area = Area3D.new()
	_touch_area.collision_layer = 0
	_touch_area.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY | GameConsts.MASK_PLAYER
	_touch_area.monitorable = false
	_touch_area.monitoring = true
	var touch_shape := CollisionShape3D.new()
	var touch_box := BoxShape3D.new()
	touch_box.size = Vector3(1.2, 1.4, 1.2)
	touch_shape.shape = touch_box
	touch_shape.position.y = 0.7
	_touch_area.add_child(touch_shape)
	add_child(_touch_area)

	if _summon.is_host:  # play_3d reaches the clients; theirs would be a second, and late, copy
		SoundSystem.play_3d("spells/beanstalk_grow.wav", global_position)

	# Creation + replication ride the dynamic-entity MultiplayerSpawner; a level change rides the
	# snapshot (net_sync_properties) rather than a re-create, so there is nothing to register.


func _physics_process(delta: float) -> void:
	_summon.tick(delta)

	if not _summon.is_host:
		return

	# It outlives its caster, so a freed owner must not reach target filtering or damage credit:
	# a freed object at a typed `attacker: Node3D` parameter drops the whole damage call.
	if not is_instance_valid(owner_node):
		owner_node = null

	_scan_timer -= delta
	if _scan_timer <= 0.0 and not _attacking and not _growing:
		_scan_timer = _stats.fire_rate
		_scan_for_enemies()

	_process_touch_damage(delta)


func _scan_for_enemies() -> void:
	var from_pos := global_position + Vector3(0, 0.6, 0)
	var target := Combat.find_homing_target(self, null, team,
			_stats.range, _collision_body.get_rid(), from_pos)
	if target:
		_attack_target(target, from_pos)


func _attack_target(target: Node3D, from_pos: Vector3) -> void:
	var target_pos: Vector3 = SpatialQuery.collision_center(target)

	_play_attack_visual(target_pos, from_pos)
	SoundSystem.play_3d("monster/thornplant/thornplant_shoot.wav", global_position)

	_summon.publish_event({"attack_target": target_pos, "attack_from": from_pos})  # TE_BUBBLETRAIL: MSG_BROADCAST

	target.take_damage(_stats.damage, GameConsts.DamageType.PHYSICAL, owner_node)
	_apply_knockback(target, from_pos)
	if level >= 2:
		_fire_spore(target_pos, from_pos)


func _apply_knockback(target: Node3D, from_pos: Vector3) -> void:
	var strength: float = _stats.knockback
	if strength <= 0.0 or not target is CharacterBody3D:
		return
	var target_center: Vector3 = SpatialQuery.collision_center(target)
	var diff := target_center - from_pos
	if diff.length_squared() < 0.0001:
		return
	var push_dir := diff.normalized()
	push_dir = (push_dir + Vector3.UP * 0.4).normalized()
	target.velocity = target.velocity - push_dir * target.velocity.dot(push_dir) + push_dir * strength


## Called on clients via sync_entity_event. Attacks and death are one-shot EVENTS rather than
## replicated properties, since a property converges to its latest value and would drop an attack
## landing between acks.
func _apply_sync_state(state: Dictionary) -> void:
	if "attack_target" in state:
		_play_attack_visual(state.attack_target, state.attack_from)
	if "death_pos" in state:
		var pos: Vector3 = state.death_pos
		_spawn_gibs(pos)


func _play_attack_visual(target_pos: Vector3, from_pos: Vector3) -> void:
	_face_target(target_pos)
	_attacking = true
	_play_anim(_stats.attack)
	if _anim_player and not _anim_player.animation_finished.is_connected(_on_attack_finished):
		_anim_player.animation_finished.connect(_on_attack_finished, CONNECT_ONE_SHOT)
	var scene_root := get_tree().current_scene
	if scene_root:
		BeamSystem.create_oneshot(scene_root, from_pos, target_pos, {
			"color": Color(0.2, 0.8, 0.1),
			"width": 0.06,
			"fade_time": 0.3,
		})


func _fire_spore(target_pos: Vector3, from_pos: Vector3) -> void:
	var dir := (target_pos - from_pos).normalized()
	var spore := NetworkManager.spawn_projectile("res://src/projectiles/spore_projectile.gd", {
		"position": from_pos,
		"direction": dir,
		"speed": SPORE_SPEED,
		"damage": SPORE_DAMAGE,
	}, owner_node, _collision_body.get_rid() if _collision_body else RID())
	if spore:
		spore.exclude_node = self  # server-only Node ref, not serializable


func _process_touch_damage(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for body in _touch_area.get_overlapping_bodies():
		if not is_instance_valid(body):
			continue
		var target: Node = body
		while target:
			if target.has_method("take_damage") and target.is_in_group("damageable"):
				break
			target = target.get_parent()
		if not target or target == self:
			continue
		if target.get("is_dead"):
			continue
		var target_team: int = target.get("team") if "team" in target else GameConsts.Team.NONE
		if Teams.teams_friendly(team, target_team):
			continue
		var last_touch: float = _touch_cooldowns.get(target, 0.0)
		if now - last_touch < TOUCH_COOLDOWN:
			continue
		_touch_cooldowns[target] = now
		target.take_damage(_stats.touch_dmg, GameConsts.DamageType.PHYSICAL, owner_node)


func is_growing() -> bool:
	return _growing


## Levels up if not maxed and the caster can afford the full cost; otherwise heals with
## whatever mana is on hand (1 mana per HP) if the plant is damaged. Returns mana spent.
func upgrade(full_mana_cost: float, available_mana: float) -> float:
	if _growing:
		return 0.0
	if level < LEVELS.size() - 1 and available_mana >= full_mana_cost:
		level += 1
		_stats = LEVELS[level]
		_summon.max_health = _stats.hp
		_summon.health = _summon.max_health

		# Clear _attacking too: the old anim_player is about to be freed, so its
		# CONNECT_ONE_SHOT animation_finished -> _on_attack_finished will never fire,
		# which would otherwise leave _attacking stuck true and gate out all scans.
		_growing = true
		_attacking = false
		_skip_fade = true
		if _model:
			_model.queue_free()
			_model = null
		_anim_player = null
		_load_model(true)
		return full_mana_cost

	if health < max_health:
		var heal_amount: float = minf(max_health - health, available_mana)
		if heal_amount <= 0.0:
			return 0.0
		_summon.health = minf(_summon.health + heal_amount, _summon.max_health)
		return heal_amount

	return 0.0


func take_damage(amount: float, _type: int = GameConsts.DamageType.PHYSICAL, attacker: Node3D = null) -> void:
	_summon.take_damage(amount, _type, attacker)


func _die() -> void:
	var pos := global_position

	_spawn_gibs(pos)
	SoundSystem.play_3d("spells/beanstalk_grow.wav", pos, 0.7)

	_summon.tell_owner(owner_peer_id, "Your thornplant was destroyed!")
	_release_owner()
	_summon.die_at(pos, {}, true)  # TE_BREAKMODEL: MSG_PVS


func destroy_plant() -> void:
	## Clean removal by owner (no gibs, no HUD message).
	_release_owner()
	_summon.destroy()


## The caster tracks its one live plant, so it has to hear about either way of losing it.
func _release_owner() -> void:
	var owner_plants := PlantBehavior.of(owner_node)
	if owner_plants:
		owner_plants.on_thornplant_destroyed()


func _face_target(target_pos: Vector3) -> void:
	var dir := target_pos - global_position
	dir.y = 0.0
	if dir.length_squared() > 0.001:
		# global_rotation, not rotation: when placed on a rotating platform the
		# plant is parented to it, and local rotation would compound with the
		# platform's yaw.
		global_rotation.y = atan2(dir.x, dir.z)


## Not [ModelRig] like the other summons: a thornplant drives its growth and its attack off
## `animation_finished`, which a rig that can sleep must never do, and it restarts its attack clip
## unconditionally. Two call sites, and nothing to gain until the signals go.
func _play_anim(anim_name: String) -> void:
	if _anim_player and _anim_player.has_animation(anim_name):
		var anim_res := _anim_player.get_animation(anim_name)
		anim_res.loop_mode = Animation.LOOP_NONE
		_anim_player.stop()
		_anim_player.play(anim_name)


func _on_grow_finished(_anim_name: StringName) -> void:
	_growing = false
	if _anim_player and _anim_player.has_animation(_stats.idle):
		var idle_res := _anim_player.get_animation(_stats.idle)
		idle_res.loop_mode = Animation.LOOP_LINEAR
		_anim_player.play(_stats.idle)


func _on_attack_finished(_anim_name: StringName) -> void:
	_attacking = false
	_on_grow_finished(_anim_name)


func _load_model(skip_fade := false) -> void:
	_model = AssetLoader.load_model(_stats.model)
	if _model:
		add_child(_model)
		_anim_player = _model.find_child("AnimationPlayer")
		_summon.set_anim_player(_anim_player)
		if _anim_player:
			_anim_player.speed_scale = 1.5
			_play_anim(_stats.grow)
			if not _anim_player.animation_finished.is_connected(_on_grow_finished):
				_anim_player.animation_finished.connect(_on_grow_finished, CONNECT_ONE_SHOT)
		if not skip_fade:
			AssetLoader.set_model_alpha(_model, 0.0)
			create_tween().tween_method(func(alpha): AssetLoader.set_model_alpha(_model, alpha), 0.0, 1.0, 0.83)


func _spawn_gibs(pos: Vector3) -> void:
	var gib_model := AssetLoader.load_model("models/bushgibs.mdl")
	if not gib_model:
		return
	var scene_root := get_tree().current_scene
	var origin := pos + Vector3(0, 0.5, 0)

	var meshes: Array[MeshInstance3D] = []
	for child in gib_model.get_children():
		if child is MeshInstance3D:
			meshes.append(child)

	if meshes.is_empty():
		# Single-mesh model — animate as one piece
		scene_root.add_child(gib_model)
		gib_model.global_position = origin
		_animate_gib(gib_model)
		return

	for mesh in meshes:
		mesh.reparent(scene_root)
		mesh.global_position = origin
		_animate_gib(mesh)
	gib_model.queue_free()


func _animate_gib(node: Node3D) -> void:
	var lifetime := 2.0
	var fade_time := 0.5

	# node may not be in tree yet, so global_position isn't valid until reparented
	var spawn_pos := node.position if node.get_parent() == null else node.global_position

	var body := RigidBody3D.new()
	body.collision_layer = 0
	body.collision_mask = GameConsts.MASK_WORLD
	# gravity_scale 1.0 — fall at the world's 20 m/s², like func_breakable gibs.
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.1
	col.shape = sphere
	body.add_child(col)

	if node.get_parent():
		node.get_parent().remove_child(node)
	node.position = Vector3.ZERO
	body.add_child(node)

	get_tree().current_scene.add_child(body)
	body.global_position = spawn_pos

	var angle := randf() * TAU
	body.apply_impulse(Vector3(cos(angle) * randf_range(0.5, 1.5), randf_range(1.0, 2.5), sin(angle) * randf_range(0.5, 1.5)))

	# duplicate materials so fading this gib doesn't fade the shared source material
	var mats: Array[BaseMaterial3D] = []
	var mesh_insts: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		mesh_insts.append(node)
	for child in node.get_children():
		if child is MeshInstance3D:
			mesh_insts.append(child)
	for mi in mesh_insts:
		for i in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(i)
			if src is BaseMaterial3D:
				var mat: BaseMaterial3D = src.duplicate()
				mi.set_surface_override_material(i, mat)
				mats.append(mat)

	var tween := body.create_tween()
	tween.tween_interval(lifetime - fade_time)
	tween.tween_method(func(alpha: float) -> void:
		for mat in mats:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = alpha
	, 1.0, 0.0, fade_time)
	tween.tween_callback(body.queue_free)


## Animation rides the shared NetInterp slot (see EntityBehavior.set_anim_player).
func net_sync_properties() -> PackedStringArray:
	return PackedStringArray([":level", "NetInterp:net_anim"])


## Client: the spawner doesn't re-create a plant that levels up, so swap the model in place.
func _regrow() -> void:
	_growing = true
	_attacking = false
	if is_instance_valid(_model):
		_model.queue_free()
	_model = null
	_anim_player = null
	_load_model(true)
