class_name EnvBeam
extends EntityBase
# env_beam — beam/lightning effect between two named point entities
# (LightningStart/LightningEnd). On/off state is server-authoritative and
# synced via the entity "visible" state. Endpoints are re-read every frame
# so beams anchored to moving entities (golem cockpit) follow along.

const SF_START_ON := 1
const SF_RANDOM_STRIKE := 4
const SF_SHADE_START := 128
const SF_SHADE_END := 256

const SCALE := GameConsts.SCALE_FACTOR
const DAMAGE_INTERVAL := 0.5    # seconds between damage ticks while the beam is on

# GoldSrc R_DrawSegs sways the beam by `amplitude * length`, where length is the
# beam's own length in map units * 0.01 (floored at 0.5). Sway scales with beam
# length and is perpendicular to the beam, not free in all three axes. NoiseAmplitude
# is GoldSrc's "0.1 units" convention (10 -> amplitude 1); dividing by 100 instead
# leaves beams looking rigid.
const NOISE_AMPLITUDE_DIVISOR := 10.0
const NOISE_LENGTH_FACTOR := 0.01
const NOISE_MIN_LENGTH := 0.5
const NOISE_WAVES := 2.5        # wave crests along the beam
const NOISE_SCROLL := 1.5       # crests/second travelling along it

var _start_name := ""
var _end_name := ""
var _start_node: Node3D
var _end_node: Node3D
var _resolve_attempted := false

var _material: StandardMaterial3D
var _color := Color.WHITE
var _width := 0.25        # half-width in meters
var _noise_raw := 0.0     # GoldSrc NoiseAmplitude, as authored
var _noise_amp := 0.0     # metres of sway, derived from _noise_raw and the beam's length
var _noise_phase := 0.0
var _noise_axis_a := Vector3.ZERO  # the two directions perpendicular to the beam
var _noise_axis_b := Vector3.ZERO
var _scroll := 0.0        # GoldSrc TextureScroll units
var _shade_start := false
var _shade_end := false

var _random_strike := false
var _life := 0.0          # strike duration (seconds); 0 = permanent while on
var _strike_time := 1.0   # delay between strikes
var _damage := 0.0        # damage per tick while the beam is on

var _active := false      # trigger target state (server-authoritative)
var _strike_timer := 0.0
var _life_timer := 0.0
var _damage_timer := 0.0

var _beam_id := -1
var _linked_from := Vector3.INF  # endpoints the PVS footprint was last linked at
var _linked_to := Vector3.INF
var _holder: Node3D       # top_level parent so world-space verts aren't re-offset
var _segments := 8


func _ready() -> void:
	super()
	_register_for_sync()
	_start_name = ent.get("LightningStart", "")
	_end_name = ent.get("LightningEnd", "")
	_width = parse_float(ent, "BoltWidth", 20.0) * 0.1 * SCALE * 0.5  # GoldSrc BoltWidth is 0.1-unit steps
	_noise_raw = parse_float(ent, "NoiseAmplitude", 0.0)
	_scroll = parse_float(ent, "TextureScroll", 0.0)
	_life = parse_float(ent, "life", 0.0)
	_strike_time = parse_float(ent, "StrikeTime", 1.0)
	_damage = parse_float(ent, "damage", 0.0)

	var flags := parse_spawnflags(ent)
	_random_strike = flags & SF_RANDOM_STRIKE != 0
	_shade_start = flags & SF_SHADE_START != 0
	_shade_end = flags & SF_SHADE_END != 0

	_color = parse_color(ent.get("rendercolor", "255 255 255"))
	# Additive black is invisible; GoldSrc maps use "0 0 0" to mean the default white beam.
	if _color.r + _color.g + _color.b < 0.01:
		_color = Color.WHITE
	_color.a = parse_float(ent, "renderamt", 255.0) / 255.0

	_material = AssetLoader.create_additive_material()
	var sprite_data := AssetLoader.load_sprite(ent.get("texture", ""))
	var textures: Array = sprite_data.get("textures", [])
	if not textures.is_empty():
		_material.albedo_texture = textures[0]

	_holder = Node3D.new()  # world-space beam verts must not inherit this node's transform
	_holder.name = "BeamHolder"
	_holder.top_level = true
	add_child(_holder)
	_holder.global_transform = Transform3D.IDENTITY

	# GoldSrc: no targetname = always on; otherwise on iff Start On flag.
	_active = ent.get("targetname", "").is_empty() or (flags & SF_START_ON != 0)
	# Random-strike beams start dark even when active; the strike loop lights them.
	visible = _active and not _random_strike
	_seed_game_visible()


## Missing endpoint names are permanent (logged once) — the beam never renders.
func _resolve_endpoints() -> void:
	_resolve_attempted = true
	var starts := TriggerSystem.get_nodes(_start_name)
	var ends := TriggerSystem.get_nodes(_end_name)
	if not starts.is_empty():
		_start_node = starts[0] as Node3D
	if not ends.is_empty():
		_end_node = ends[0] as Node3D
	if not _start_node or not _end_node:
		Log.info("env_beam '%s': unresolved endpoints %s -> %s" % [name, _start_name, _end_name])


## GoldSrc links a beam into the leaves its start-end box touches (CBeam::RelinkBeam). Left to the
## visual subtree, the footprint is the strip's holder at the world origin — and on a dedicated
## server, with no camera to build the strip, it stays there.
func _relink() -> void:
	if not is_instance_valid(_start_node) or not is_instance_valid(_end_node):
		return
	var from := _start_node.global_position
	var to := _end_node.global_position
	if from == _linked_from and to == _linked_to:
		return
	_linked_from = from
	_linked_to = to
	var inv := global_transform.affine_inverse()
	VisibilitySystem.set_entity_local_aabb(_entity.entity_id, AABB(inv * from, Vector3.ZERO).expand(inv * to))


## Sway perpendicular to the beam, as a wave travelling along it (GoldSrc walks a
## scrolling noise table, which reads as a snaking rope).
func _make_noise_fn() -> Callable:
	return func(t: float) -> Vector3:
		if _noise_amp <= 0.0:
			return Vector3.ZERO
		var a := sin(t * TAU * NOISE_WAVES + _noise_phase)
		# Second axis out of step with the first, so it snakes instead of flapping in a plane.
		var b := cos(t * TAU * NOISE_WAVES * 0.7 + _noise_phase * 1.3)
		# Pin the endpoints; full amplitude mid-beam like GoldSrc lightning.
		return (_noise_axis_a * a + _noise_axis_b * b) * (_noise_amp * sin(t * PI))


## GoldSrc R_DrawSegs: sway = (NoiseAmplitude/100) * max(length_in_units * 0.01, 0.5).
func _noise_amplitude_for(length_m: float) -> float:
	if _noise_raw <= 0.0:
		return 0.0
	var length_units := length_m / SCALE
	var length_factor := maxf(length_units * NOISE_LENGTH_FACTOR, NOISE_MIN_LENGTH)
	return (_noise_raw / NOISE_AMPLITUDE_DIVISOR) * length_factor * SCALE


## The plane perpendicular to the beam, which the sway is applied in.
func _update_noise_axes(from: Vector3, to: Vector3) -> void:
	var dir := (to - from)
	if dir.length_squared() < 1e-8:
		return
	dir = dir.normalized()
	var up := GeomUtil.safe_up(dir, Vector3.RIGHT)
	_noise_axis_a = dir.cross(up).normalized()
	_noise_axis_b = dir.cross(_noise_axis_a).normalized()


func _make_color_fn() -> Callable:
	if not _shade_start and not _shade_end:
		return Callable()
	return func(t: float) -> Color:
		var c := _color
		if _shade_start:
			c.a *= t
		if _shade_end:
			c.a *= 1.0 - t
		return c


func _process(delta: float) -> void:
	if not _resolve_attempted:
		_resolve_endpoints()
	_relink()
	if not visible or not _start_node or not _end_node \
			or not is_instance_valid(_start_node) or not is_instance_valid(_end_node):
		if _beam_id >= 0:
			BeamSystem.destroy(_beam_id)
			_beam_id = -1
		return

	var from := _start_node.global_position
	var to := _end_node.global_position

	_noise_amp = _noise_amplitude_for(from.distance_to(to))
	if _noise_amp > 0.0:
		_update_noise_axes(from, to)
		_noise_phase = fposmod(_noise_phase + delta * NOISE_SCROLL * TAU, TAU)

	if _beam_id < 0:
		var length := from.distance_to(to)
		_segments = clampi(int(length / 0.5), 4, 24) if _noise_amp > 0.0 else 1
		var tile_len := maxf(1.0, _width * 8.0)  # repeat scales with width so wide beams get soft puffs, not thin bands
		_beam_id = BeamSystem.create_tracked(_holder, from, to, {
			"color": _color,
			"color_fn": _make_color_fn(),
			"width": _width,
			"segments": _segments,
			"noise_fn": _make_noise_fn() if _noise_amp > 0.0 else Callable(),
			"material": _material,
			"uv_tiles": maxf(1.0, length / tile_len),
		})
	else:
		BeamSystem.update(_beam_id, from, to)

	if _scroll != 0.0:
		_material.uv1_offset.x = fposmod(_material.uv1_offset.x - _scroll * 0.1 * delta, 1.0)  # GoldSrc TextureScroll ~0.1 tile/sec


func _physics_process(delta: float) -> void:
	# Strike scheduling and damage are authoritative; clients follow the synced "visible" state.
	if _is_network_client():
		return

	if _random_strike and _active:
		if _game_visible:
			_life_timer -= delta
			if _life_timer <= 0.0:
				set_entity_visible(false)
				_strike_timer = _strike_time * randf_range(0.75, 1.25)
		else:
			_strike_timer -= delta
			if _strike_timer <= 0.0:
				set_entity_visible(true)
				_life_timer = maxf(_life, 0.1)

	if _game_visible and _damage > 0.0:
		_damage_timer -= delta
		if _damage_timer <= 0.0:
			_damage_timer = DAMAGE_INTERVAL
			_apply_beam_damage()


func _apply_beam_damage() -> void:
	if not _start_node or not _end_node:
		return
	var space := get_tree().root.get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
		_start_node.global_position, _end_node.global_position)
	params.collision_mask = GameConsts.MASK_PLAYER
	var exclude: Array[RID] = []
	for _i in 8:
		params.exclude = exclude
		var result := space.intersect_ray(params)
		if result.is_empty():
			break
		var body: Object = result.collider
		if body is CharacterBody3D and body.has_method("take_damage"):
			body.call_deferred("take_damage", _damage, GameConsts.DamageType.LIGHTNING)
		exclude.append(result.rid)


## env_render hook (via EntityRender.apply_render_properties). Only keys present in
## `props` are applied; renderamt 0 means "leave alpha alone".
func apply_render_properties(props: Dictionary) -> void:
	if props.has("rendercolor"):
		var c := parse_color(str(props["rendercolor"]))
		if c.r + c.g + c.b >= 0.01:
			_color = Color(c.r, c.g, c.b, _color.a)
	var amt := int(str(props.get("renderamt", "0")))
	if amt > 0:
		_color.a = amt / 255.0
	if _beam_id >= 0:  # recreate so the new color/shading takes effect
		BeamSystem.destroy(_beam_id)
		_beam_id = -1


func trigger(_activator: Node, type: TriggerSystem.Type) -> void:
	if _is_network_client():
		return
	match type:
		TriggerSystem.Type.ON: _active = true
		TriggerSystem.Type.OFF: _active = false
		TriggerSystem.Type.TOGGLE: _active = not _active
	if _random_strike:
		if not _active:  # switching off also kills a live strike
			set_entity_visible(false)
		_strike_timer = 0.0
	else:
		set_entity_visible(_active)
	# set_entity_visible only marks the entity dirty; without this notify, already-
	# connected clients only see the change on next PVS re-entry, not immediately.
	_sync_notify()


func _exit_tree() -> void:
	super()
	if _beam_id >= 0:
		BeamSystem.destroy(_beam_id)
		_beam_id = -1
