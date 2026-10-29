class_name Projectile
extends Node3D

## Base class for projectiles (fireball, magic missile, skull, comet, ice shard, bird).
## RollingStone extends RigidBody3D directly and does not use this base class.

var direction := Vector3.FORWARD
var speed := 0.0
var lifetime := 5.0
var exclude_rid: RID
var owner_node: Node3D
## Set from spawn data. Drives homing target selection; contact deliberately ignores it.
var team: int = GameConsts.Team.NONE
## Extra node the contact check ignores, beyond owner_node — e.g. a spore's parent thornplant.
var exclude_node: Node3D

var _is_host: bool:
	get: return _entity.is_host
@warning_ignore("unused_private_class_variable")
var _entity_id: int:
	get: return _entity.entity_id
	set(value): _entity.entity_id = value
@warning_ignore("unused_private_class_variable")
var _age := 0.0
var _trail: TrailFader
var _light: OmniLight3D
@warning_ignore("unused_private_class_variable")
var _scene_root: Node
var _entity := EntityBehavior.new()
var _pending_death := false
var _death_timer := 0.0

## The projectile's own effect materials, re-sorted when it crosses a liquid surface. Filled by
## _create_sprite; a model-based projectile (skull, ice shard, bird) leaves it empty and needs
## nothing, because opaque geometry is drawn before the water and blended over already.
var _liquid_sorted: Array = []
var _submerged := false

## How long the projectile stays alive server-side after _die(), so the final impact
## position reaches clients before the entity is unregistered.
var death_delay := 0.05

## The hurt volume this projectile is currently inside, so entering one is an edge rather than a
## state — see _check_hazards.
var _hazard_volume: Node = null

## Segment travelled by the last _trace_step, for _player_contact and the post-move write.
var _step_from := Vector3.ZERO
var _step_to := Vector3.ZERO

## Radius around the swept segment that counts as touching an actor — the projectile's own
## girth. The bigger spells (a skull, a bird) widen it; the small fast ones narrow it.
var contact_radius := 0.6


func setup(data: Dictionary, is_host := true) -> void:
	position = data.get("position", Vector3.ZERO)
	direction = data.get("direction", Vector3.FORWARD).normalized()
	speed = data.get("speed", speed)
	lifetime = data.get("lifetime", lifetime)
	exclude_rid = data.get("exclude_rid", RID())
	team = data.get("team", GameConsts.Team.NONE)
	_entity.initialize(self, is_host)
	if not is_host:
		ProjectileStandIn.claim(self, data)
	add_to_group("projectile")
	add_child(BlobShadow.new(0.25))



## Sweep this tick's motion against world geometry and entity colliders. Returns the ray
## hit, empty when the path is clear; either way the segment travelled is left in
## _step_from/_step_to, so callers finish the move with `global_position = _step_to`.
func _trace_step(delta: float) -> Dictionary:
	_step_from = global_position
	_step_to = _step_from + direction * speed * delta
	var params := PhysicsRayQueryParameters3D.create(_step_from, _step_to)
	params.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY
	if exclude_rid.is_valid():
		params.exclude = [exclude_rid]
	return get_world_3d().direct_space_state.intersect_ray(params)


## First damageable actor within `radius` of the segment travelled this host tick, ignoring
## the owner. Every projectile detonates on the first live body it touches regardless of team
## — friendly fire is rejected by the target (player.take_damage / dragon.take_damage), not here.
func _player_contact(seg_from: Vector3, seg_to: Vector3, radius := 0.6) -> Node3D:
	for node in SpatialQuery.nodes_near_segment(&"damageable", seg_from, seg_to, radius):
		# Skull and bird are damageable themselves (they can be shot down), so they are in
		# this very group — self first, or they detonate on tick one at the caster.
		if node == self or node == owner_node or node == exclude_node or not is_instance_valid(node):
			continue
		if node.get("is_dead"):
			continue
		var center: Vector3 = SpatialQuery.collision_center(node)
		if GeomUtil.dist_to_segment(center, seg_from, seg_to) <= radius:
			return node
	return null


## One host tick of straight-line flight: expire, sweep the path, advance. Every projectile
## that flies in a line runs this rather than repeating the sweep, and says what each outcome
## means by overriding the three hooks below.
func _fly_step(delta: float, life: float) -> void:
	_age += delta
	if _age >= life:
		_on_expired()
		return
	_sweep_and_advance(delta)


## The sweep half of _fly_step, without the clock. Split out for the projectiles that age on
## their own schedule (the bird fades out over its last half-second).
func _sweep_and_advance(delta: float) -> void:
	var result := _trace_step(delta)
	if not result.is_empty():
		global_position = result.position
		_on_world_hit(result)
		return
	var victim := _player_contact(_step_from, _step_to, contact_radius)
	if victim != null:
		global_position = SpatialQuery.collision_center(victim)
		_on_actor_hit(victim)
		return
	global_position = _step_to
	_check_hazards()


## A projectile is a bare Node3D: a trigger_hurt's Area3D has no collider to touch, so it would
## fly through a fire jet untouched. It reports itself instead, on the tick it enters a volume —
## the same one hit a player gets from body_entered. Only a projectile that can be damaged at all
## asks (the skull, the bird); for the rest this is a has_method and nothing more.
func _check_hazards() -> void:
	if not has_method("take_damage"):
		return
	var volume: Node = SpatialQuery.hurt_volume_at(self, global_position)
	if volume == _hazard_volume:
		return  # still in the one it was in, or still in none
	_hazard_volume = volume
	if volume:
		volume.hurt(self)


## Ran out of life without touching anything.
func _on_expired() -> void:
	_die()


## Hit world geometry (or an entity collider). Position is already at the impact point.
## Deliberately NOT chained into _on_actor_hit: what a wall gets is not what a body gets, and
## `result.collider` is usually a StaticBody3D with nothing to take.
func _on_world_hit(_result: Dictionary) -> void:
	_die()


## Reached a live body. Position is already at that body's centre.
func _on_actor_hit(_victim) -> void:
	_die()


func _orient_to_direction() -> void:
	if direction.length_squared() > 0.001:
		look_at(global_position + direction, GeomUtil.safe_up(direction))


## The standard spell-sprite child: a billboard carrying its own copy of the additive template,
## registered so it sinks with the projectile.
func _create_sprite(sprite_path: String, sprite_scale := 1.0) -> Sprite3D:
	var sprite := AssetLoader.load_sprite_node(sprite_path)
	if sprite == null:
		return null
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.pixel_size = GameConsts.SCALE_FACTOR * sprite_scale
	sprite.transparent = true
	var mat := AssetLoader.get_sprite_material_template().duplicate()
	if sprite.texture:
		mat.albedo_texture = sprite.texture
	sprite.material_override = mat
	_liquid_sorted.append(mat)
	add_child(sprite)
	return sprite


## Which side of a liquid surface this projectile's sprites are drawn on. Per frame rather than
## per tick: the sprite is a view, and a projectile that dives into a pool between two host ticks
## should not stay on top of it until the next one. See AssetLoader.sort_for_liquid.
func _process(_delta: float) -> void:
	if _liquid_sorted.is_empty():
		return
	var under := SpatialQuery.is_point_in_water(self, global_position)
	if under == _submerged:
		return
	_submerged = under
	AssetLoader.sort_for_liquid(_liquid_sorted, under)
	if is_instance_valid(_trail):
		_trail.set_submerged(under)


func _create_light(color: Color, energy := 2.0, range_val := 2.5) -> OmniLight3D:
	_light = OmniLight3D.new()
	_light.light_color = color
	_light.light_energy = energy
	_light.omni_range = range_val
	_light.omni_attenuation = 1.5
	_light.shadow_enabled = false
	_light.light_cull_mask = GameConsts.LIGHT_CULL_ALL
	add_child(_light)
	return _light


func _create_trail(palette: Array = [], width := 0.1, max_life := 0.3) -> TrailFader:
	_trail = TrailFader.new()
	_trail.width = width
	_trail.max_life = max_life
	if not palette.is_empty():
		_trail.color_palette = palette
	get_tree().current_scene.add_child(_trail)
	return _trail


func _create_ambient_sound(sound_path: String, max_distance := 20.0) -> AudioStreamPlayer3D:
	var stream := AssetLoader.load_sound(sound_path)
	if not stream:
		return null
	var audio := AudioStreamPlayer3D.new()
	audio.stream = stream
	audio.max_distance = max_distance
	audio.bus = SoundSystem.EFFECTS_BUS
	audio.autoplay = true
	add_child(audio)
	return audio


## No-op: replication is handled by the dynamic-entity MultiplayerSpawner (NetworkManager.spawn_projectile),
## so entity_id stays -1 and destroy rides queue_free -> despawn.
func _register_entity(_data: Dictionary) -> void:
	pass


func _feed_trail() -> void:
	if is_instance_valid(_trail):
		_trail.add_point(global_position)


func _stop_trail() -> void:
	if is_instance_valid(_trail):
		_trail.add_point(global_position)
		_trail.stop()


## The host flies the projectile; every peer feeds the visuals from the position it has.
## A subclass with a different flight (homing, a locked target) overrides _host_physics; one
## with more to draw than a trail overrides _update_visuals.
func _physics_process(delta: float) -> void:
	if _is_host:
		_forget_freed_owner()
		if _process_pending_death(delta):
			return
		_host_physics(delta)
	_update_visuals(delta)


## A projectile outlives its caster — a disconnect, a round reset, /killbots — so a freed owner
## must not reach damage credit. GDScript refuses a freed object at a typed `attacker: Node3D`
## parameter, and that refusal drops the WHOLE damage call: the hit then deals nothing at all
## (seen as damage_chain errors from MagicMissile._hit_target). The summons do the same at the
## top of their own tick; every host tick entry here has to call this, including a subclass that
## replaces _physics_process rather than _host_physics (see Bird).
func _forget_freed_owner() -> void:
	if not is_instance_valid(owner_node):
		owner_node = null


func _host_physics(delta: float) -> void:
	_fly_step(delta, lifetime)


func _update_visuals(_delta: float) -> void:
	_feed_trail()


## Called from _physics_process; a subclass that replaces it must return early on true.
func _process_pending_death(delta: float) -> bool:
	if not _pending_death:
		return false
	
	_death_timer += delta
	if _death_timer >= death_delay:
		_perform_die()
	return true


## If death_delay > 0 this only flags delayed removal; see _process_pending_death.
func _die() -> void:
	if not _is_host or death_delay <= 0.0:
		_perform_die()
		return
	
	if _pending_death:
		return
	_pending_death = true
	_death_timer = 0.0


func _perform_die() -> void:
	_entity.destroy()


func _exit_tree() -> void:
	_stop_trail()
