class_name EffectBehavior
extends RefCounted

## Lifecycle and part builders for one-shot visual effects — impact sparks, explosions,
## flame bursts. The host assembles its parts from _build() with the add_* helpers, then
## calls start() from _ready(): that plays every part, fades the lights, and frees the
## effect once `lifetime` runs out.

## Seconds before the effect frees itself. 0 hands the timing to the host, which then
## calls finish() itself (a fade that decides its own length, a persistent flame).
var lifetime := 1.0

## Network id when this effect is spawner-created; -1 detaches it from the despawn path.
var entity_id: int:
	get: return _entity.entity_id
	set(value): _entity.entity_id = value

var _host: Node3D
var _entity := EntityBehavior.new()
var _flashes: Array = []  # [light, fade_seconds] — start() fades each on its own clock
var _rings: Array = []    # [mesh_instance, expand_to, duration, alpha]
## This effect's own materials, sorted against the liquid it goes off in — see start().
var _liquid_sorted: Array = []


func initialize(host: Node3D) -> void:
	_host = host


# --- Parts, built from the host's _build() ---

## Dynamic light flash, faded to dark over `fade` seconds once the effect starts.
func add_flash(color: Color, energy := 2.0, omni_range := 2.5, fade := 0.2) -> OmniLight3D:
	var flash := OmniLight3D.new()
	flash.light_color = color
	flash.light_energy = energy
	flash.omni_range = omni_range
	flash.shadow_enabled = false
	flash.light_cull_mask = GameConsts.LIGHT_CULL_ALL
	_host.add_child(flash)
	_flashes.append([flash, fade])
	return flash


## One-shot spark burst. `type` selects the process material — see AssetLoader.
func add_sparks(type: String, amount: int, particle_life: float, size: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.emitting = false
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.amount = amount
	particles.lifetime = particle_life
	particles.fixed_fps = 30
	particles.process_material = AssetLoader.get_spark_particle_material(type)
	particles.draw_pass_1 = AssetLoader.get_spark_quad(Vector2(size, size))
	_host.add_child(particles)
	return particles


## Positional one-shot sound. Null when the file is missing.
func add_sound(path: String, max_distance := 20.0) -> AudioStreamPlayer3D:
	var stream := AssetLoader.load_sound(path)
	if not stream:
		return null
	var audio := AudioStreamPlayer3D.new()
	audio.stream = stream
	audio.max_distance = max_distance
	audio.bus = SoundSystem.EFFECTS_BUS
	_host.add_child(audio)
	return audio


## Sprite billboard, animated when the .spr carries frames and `fps` is set.
## Null when the sprite is missing.
func add_sprite(path: String, billboard := BaseMaterial3D.BILLBOARD_ENABLED, scale := 1.0,
		fps := 0.0, loop := false) -> Node:
	var sprite := AssetLoader.load_sprite_node(path)
	if not sprite:
		return null
	sprite.billboard = billboard
	sprite.pixel_size = GameConsts.SCALE_FACTOR * scale
	sprite.transparent = true
	if fps > 0.0:
		var sap = sprite.get_node_or_null(^"SpriteAnimationPlayer")
		if sap:
			sap.fps = fps
			sap.loop_animation = loop
	var mat := AssetLoader.get_sprite_material_template(billboard).duplicate()
	if sprite.texture:
		mat.albedo_texture = sprite.texture
	sprite.material_override = mat
	_liquid_sorted.append(mat)
	_host.add_child(sprite)
	return sprite


## Expanding shockwave ring, flared out and faded over `duration` once the effect starts.
func add_ring(color: Color, expand_to := 8.0, duration := 0.5) -> MeshInstance3D:
	var torus_mesh := TorusMesh.new()
	torus_mesh.inner_radius = 0.2
	torus_mesh.outer_radius = 0.6
	torus_mesh.rings = 24
	torus_mesh.ring_segments = 12
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b)
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.render_priority = AssetLoader.EFFECT_PRIORITY
	_liquid_sorted.append(mat)
	var inst := MeshInstance3D.new()
	inst.mesh = torus_mesh
	inst.material_override = mat
	inst.name = "Toroid"
	_host.add_child(inst)
	_rings.append([inst, expand_to, duration, color.a])
	return inst


# --- Lifecycle ---

## Play the assembled effect. `register_path` hands it to the dynamic-entity spawner so
## every peer sees it — online that frees this local copy in favour of the replicated one.
func start(register_path := "", register_data := {}) -> void:
	_entity.initialize(_host)
	# A one-shot never moves, so which side of a liquid surface it goes off on is settled once,
	# here. An explosion under water otherwise flashes on top of it — see AssetLoader.sort_for_liquid.
	if not _liquid_sorted.is_empty() and SpatialQuery.is_point_in_water(_host, _host.global_position):
		AssetLoader.sort_for_liquid(_liquid_sorted, true)
	if not register_path.is_empty():
		NetworkManager.register_effect(_host, register_path, register_data)
	for child in _host.get_children():
		if child is AudioStreamPlayer3D:
			child.play()
		elif child is GPUParticles3D:
			child.emitting = true
	for f in _flashes:
		fade_light(f[0], f[1])
	for r in _rings:
		_flare_ring(r[0], r[1], r[2], r[3])
	if lifetime > 0.0:
		finish(lifetime)


## Fade one light to dark. Exposed for effects that dim on their own schedule
## (a persistent flame told to stop) rather than at start().
func fade_light(light: OmniLight3D, seconds: float) -> void:
	if seconds <= 0.0 or not is_instance_valid(light):
		return
	_host.create_tween().tween_property(light, "light_energy", 0.0, seconds)


## Free the effect, after `delay` seconds when given. Client replicas of a spawner-created
## effect no-op on the free itself — the despawn RPC owns that (see EntityBehavior.destroy).
func finish(delay := 0.0) -> void:
	if delay <= 0.0:
		_entity.destroy()
		return
	_host.create_tween().tween_callback(_entity.destroy).set_delay(delay)


func _flare_ring(inst: MeshInstance3D, expand_to: float, duration: float, alpha: float) -> void:
	var t := _host.create_tween()
	t.set_parallel(true)
	t.tween_property(inst, "scale", Vector3.ONE * expand_to, duration).from(Vector3.ONE)
	t.tween_property(inst.mesh, "inner_radius", 0.39, duration)
	t.tween_property(inst.mesh, "outer_radius", 0.41, duration)
	t.tween_property(inst.material_override, "albedo_color:a", 0.0, duration).from(alpha)
