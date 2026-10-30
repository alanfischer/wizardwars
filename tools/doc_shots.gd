extends Node
## Screenshots for docs/wizards.md and docs/combo_spells.md: a listen-host match on ww_2fort's rope
## bridge, with brainless bots posed by hand and their spells cast through the same server path a
## player's shots take (ServerRequests.attack). Each shot saves a burst of frames to pick from.
##
##   SHOT_DIR=/tmp/docshots SHOT_ONLY=fire_fireball,ice_freezeray "$GODOT" --path . \
##       res://tools/doc_shots.tscn -- --host --map ww_2fort
##
## It renders with the shipped renderer (gl_compatibility), so the pictures are what players see.
##
## SHOT_ONLY takes shot ids (see SHOTS) or a set name: portraits, spells, combos. Combo summons
## outlive their shot, so run each combo in its own process. SHOT_CAMS (e.g. over,close,wide) saves
## every frame from each of those cameras too, for choosing one; SHOT_TIMEOUT (s, default 180)
## caps a run.

const InputCommand = preload("res://addons/pmove/input_command.gd")
const ServerRequests = preload("res://src/systems/server_requests.gd")
const E := GameConsts.Element

## GoldSrc units. The deck is z -64, x -100..100, y -450..450.
const DECK_Z := -64.0
const CASTER_AT := Vector2(0.0, -120.0)
const TARGET_AT := Vector2(0.0, 280.0)

## id: [element, slot or combo key, options]. Options: hold (s of held fire), casts (taps),
## frames (s after the first cast), cam (over | close | wide | front), target_m (enemy distance),
## aim (target | ground | feet), charge, extra (enemies placed around the caster), no_target, special,
## from / toward / up (GoldSrc xy to stand at and face, and height over the deck, for a spell the deck
## cannot hold).
const SHOTS := {
	"portrait_fire": [E.FIRE, -1, {}],
	"portrait_ice": [E.ICE, -1, {}],
	"portrait_lightning": [E.LIGHTNING, -1, {}],
	"portrait_earth": [E.EARTH, -1, {}],
	"portrait_wind": [E.WIND, -1, {}],
	"portrait_nature": [E.NATURE, -1, {}],
	"portrait_life": [E.LIFE, -1, {}],
	"portrait_death": [E.DEATH, -1, {}],
	"portrait_archmage": [E.ARCHMAGE, -1, {}],

	"fire_missile": [E.FIRE, 1, {target_m = 12.0, casts = 2, frames = [0.03, 0.06, 0.09, 0.12, 0.15, 0.2, 0.25]}],
	"fire_flamelick": [E.FIRE, 2, {target_m = 6.0, casts = 3, frames = [0.05, 0.15, 0.55, 0.65, 1.05]}],
	"fire_fireball": [E.FIRE, 3, {frames = [0.2, 0.35, 0.5, 0.6, 0.7, 0.85]}],
	"fire_fissure": [E.FIRE, 4, {target_m = 3.5, cam = "close", frames = [1.0, 1.6, 1.9, 2.0, 2.05, 2.1, 2.2, 2.4]}],

	"ice_mindmissile": [E.ICE, 1, {casts = 2, frames = [0.04, 0.08, 0.12, 0.16, 0.2, 1.28, 1.32, 1.36]}],
	"ice_icepoke": [E.ICE, 2, {target_m = 11.0, frames = [0.03, 0.06, 0.09, 0.12]}],
	"ice_freezeray": [E.ICE, 3, {hold = 2.0, frames = [0.5, 1.0, 1.5]}],
	"ice_invisibility": [E.ICE, 4, {hold = 3.0, cam = "close", no_target = true, frames = [0.03, 0.08, 0.13, 0.2, 0.3, 0.45]}],

	"lightning_bolt": [E.LIGHTNING, 1, {hold = 2.0, frames = [0.3, 0.55, 0.8, 1.3]}],
	"lightning_spotbolt": [E.LIGHTNING, 2, {charge = 1.0, frames = [0.03, 0.08, 0.15, 0.25, 0.4]}],

	"earth_rollingstone": [E.EARTH, 1, {target_m = 9.0, casts = 2, frames = [0.1, 0.2, 0.3, 0.4, 1.15, 1.25, 1.35]}],
	"earth_pebbleblast": [E.EARTH, 2, {target_m = 6.0, casts = 2, frames = [0.03, 0.08, 0.15, 1.03, 1.08]}],
	"earth_falconry": [E.EARTH, 3, {target_m = 11.0, cam = "front", frames = [0.02, 0.04, 0.06, 0.08]}],
	"earth_bear": [E.EARTH, 4, {cam = "close", no_target = true, frames = [0.5, 1.0, 2.0]}],

	"wind_mindmissile": [E.WIND, 1, {casts = 2, frames = [0.04, 0.08, 0.12, 0.16, 0.2, 1.28, 1.32, 1.36]}],
	"wind_updraft": [E.WIND, 2, {target_m = 6.0, aim = "feet", frames = [0.1, 0.25, 0.4, 0.6, 0.9]}],
	"wind_levitate": [E.WIND, 3, {hold = 3.0, cam = "wide", no_target = true, frames = [0.3, 0.6, 0.9, 1.3, 1.8, 2.6]}],
	"wind_clone": [E.WIND, 4, {special = "clone", no_target = true, cam = "wide", frames = [0.65, 0.75, 0.85, 1.0, 1.2, 1.5]}],

	"nature_missile": [E.NATURE, 1, {target_m = 12.0, casts = 2, frames = [0.03, 0.06, 0.09, 0.12, 0.15, 0.2, 0.25]}],
	"nature_thornblast": [E.NATURE, 2, {target_m = 6.0, casts = 2, frames = [0.03, 0.08, 0.15, 0.83, 0.88]}],
	"nature_beanstalk": [E.NATURE, 3, {hold = 4.0, aim = "ground", cam = "close", no_target = true, frames = [2.0, 3.0, 4.0, 4.5]}],
	"nature_thornplant": [E.NATURE, 4, {aim = "ground", special = "thornplant", frames = [6.0, 12.0, 13.0, 14.0, 15.0]}],

	"life_dualmissile": [E.LIFE, 1, {target_m = 12.0, hold = 1.0, frames = [0.04, 0.08, 0.12, 0.16, 0.36, 0.4, 0.44]}],
	"life_liferay": [E.LIFE, 2, {hold = 2.0, frames = [0.5, 1.0, 1.5]}],
	"life_forceblast": [E.LIFE, 3, {target_m = 3.0, extra = 2, cam = "close", frames = [0.02, 0.05, 0.1, 0.18, 0.3, 0.5]}],
	"life_sacrifice": [E.LIFE, 4, {target_m = 2.5, extra = 2, frames = [1.0, 3.9, 4.0, 4.1, 4.2, 4.35, 4.5, 4.7]}],

	"death_missile": [E.DEATH, 1, {target_m = 12.0, casts = 2, frames = [0.03, 0.06, 0.09, 0.12, 0.15, 0.2, 0.25]}],
	"death_deathray": [E.DEATH, 2, {hold = 2.0, frames = [0.5, 1.0, 1.5]}],
	"death_skull": [E.DEATH, 3, {target_m = 11.0, cam = "front", frames = [0.02, 0.04, 0.06, 0.08]}],
	"death_grimfeast": [E.DEATH, 4, {target_m = 1.5, cam = "close", special = "corpse", frames = [-0.3, 0.05, 0.3, 0.8]}],

	"archmage_missile": [E.ARCHMAGE, 1, {target_m = 12.0, casts = 2, frames = [0.03, 0.06, 0.09, 0.12, 0.15, 0.2, 0.25]}],
	"archmage_comet": [E.ARCHMAGE, 2, {target_m = 9.0, cam = "wide", frames = [0.2, 0.4, 0.6, 0.8, 1.0, 1.3, 1.6]}],

	"combo_ball_lightning": [E.FIRE, "ball_lightning_weapon", {cam = "wide", frames = [0.05, 0.15, 0.5, 1.5, 3.0, 5.0]}],
	"combo_meteor": [E.FIRE, "meteor_weapon", {target_m = 9.0, cam = "wide", frames = [0.5, 1.0, 1.5, 2.0, 2.3, 2.6, 3.0]}],
	"combo_lightning_cloud": [E.ICE, "lightning_cloud_weapon", {target_m = 9.0, frames = [0.8, 1.4, 2.0, 2.6, 3.2, 4.0]}],
	"combo_giant_plant": [E.ICE, "giant_plant_weapon", {cam = "wide", frames = [1.0, 2.5, 4.0, 6.0, 8.0]}],
	"combo_spirit_wiz": [E.LIFE, "spirit_wiz_weapon", {cam = "wide", frames = [1.0, 2.0, 3.0, 4.5, 6.0]}],
	"combo_wombat": [E.LIFE, "wombat_weapon", {target_m = 3.5, cam = "close", frames = [0.15, 0.3, 0.45, 0.6, 0.8, 1.0, 1.3, 1.6]}],
	"combo_tornado": [E.EARTH, "tornado_weapon", {cam = "wide", frames = [1.0, 2.0, 3.0, 4.5, 6.0]}],
	"combo_raise_dead": [E.DEATH, "raise_dead_weapon", {target_m = 4.0, extra = 2, frames = [0.5, 1.5, 2.5, 3.5, 5.0, 7.0]}],
}

var _pvs_cam: Camera3D = null
var _cam: Camera3D
## BeamSystem faces its ribbons to the root viewport's camera, so it shadows the shot camera.
var _root_cam: Camera3D
var _sub: SubViewport
var _dir := ""
## [bot, yaw, pitch, move_y]: every posed bot gets a command each physics tick.
var _posed: Array = []
var _seq := 1
var _immortal: Array = []
var _frame: Array = []


func _ready() -> void:
	if has_meta("active"):
		return
	var shooter := Node.new()
	shooter.set_script(get_script())
	shooter.name = "DocShooter"
	shooter.set_meta("active", true)
	get_tree().root.add_child.call_deferred(shooter)
	get_tree().change_scene_to_file.call_deferred("res://src/main.tscn")


func _enter_tree() -> void:
	if has_meta("active"):
		process_physics_priority = 1000
		_run.call_deferred()


func _physics_process(delta: float) -> void:
	if _pvs_cam:
		VisibilitySystem.set_local_position(_pvs_cam.global_position)
		if not _root_cam.current:
			_root_cam.make_current()
		var world_env := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
		if world_env and world_env.environment:
			world_env.environment.fog_enabled = false
	for p in _posed:
		var bot = p[0]
		if not is_instance_valid(bot) or bot.is_dead:
			continue
		var sm = bot.get_server_movement()
		if sm == null:
			continue
		var cmd = InputCommand.create(_seq, 0.0, p[3], p[1], p[2], 0, delta)
		_seq += 1
		var w: Weapon = bot.weapon_at(bot.current_weapon_idx)
		if w:
			w.contribute_input_flags(cmd)
		sm.enqueue(cmd)
		bot.mana = bot.max_mana
	for b in _immortal:
		if is_instance_valid(b) and not b.is_dead:
			b.health = 5000.0


func _env(key: String, fallback: String) -> String:
	var v := OS.get_environment(key)
	return v if v != "" else fallback


func _gs(g: Vector3) -> Vector3:
	return Vector3(-g.x, g.z, g.y) * GameConsts.SCALE_FACTOR


func _deck(xy: Vector2, up := 4.0) -> Vector3:
	return _gs(Vector3(xy.x, xy.y, DECK_Z + up))


func _yaw_to(from: Vector3, to: Vector3) -> float:
	var d := to - from
	return atan2(-d.x, -d.z)


func _ids() -> Array:
	var want := _env("SHOT_ONLY", "spells").split(",")
	var out := []
	for w in want:
		if SHOTS.has(w):
			out.append(w)
			continue
		var prefix: String = {"portraits": "portrait_", "combos": "combo_"}.get(w, "")
		for id in SHOTS:
			if (prefix != "" and id.begins_with(prefix)) or \
					(w == "spells" and not id.begins_with("portrait_") and not id.begins_with("combo_")):
				out.append(id)
	return out


func _run() -> void:
	_dir = _env("SHOT_DIR", "user://docshots")
	var limit := float(_env("SHOT_TIMEOUT", "180"))
	get_tree().create_timer(limit).timeout.connect(func() -> void:
		push_error("[DocShots] gave up after %.0fs" % limit)
		get_tree().quit(2))
	DirAccess.make_dir_recursive_absolute(_dir)
	while not Game.game_active:
		await get_tree().create_timer(0.5).timeout
	await get_tree().create_timer(float(_env("SHOT_WARMUP", "8"))).timeout
	# The host's own wizard spawns on no team in the open, where homing spells and raise dead take
	# it for an enemy. On the casters' team it stands in their fort, out of shot and out of reach.
	ServerRequests.join_team(1, 1, GameConsts.Element.WIND)
	await get_tree().create_timer(1.0).timeout
	var root := get_tree().root
	_sub = SubViewport.new()
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub.msaa_3d = Viewport.MSAA_4X
	_sub.screen_space_aa = root.screen_space_aa
	_sub.use_debanding = root.use_debanding
	root.add_child(_sub)
	_cam = Camera3D.new()
	_cam.far = 400.0
	_sub.add_child(_cam)
	_cam.make_current()
	_root_cam = Camera3D.new()
	_root_cam.far = _cam.far
	root.add_child(_root_cam)
	_root_cam.make_current()
	_pvs_cam = _cam
	for id in _ids():
		await _shoot(id)
		await _clear()
	get_tree().quit()


func _spawn(element: int, team: int, at: Vector3, face: Vector3) -> RemotePlayer:
	var id := BotSystem.add_bot(element, team, 1.0)
	var bot: RemotePlayer = null
	for b in BotSystem._bots:
		if is_instance_valid(b) and b.peer_id == id:
			bot = b
	if bot == null:
		push_error("[DocShots] could not add a bot for element %d team %d" % [element, team])
		return null
	for brain in BotSystem._brains.duplicate():
		if is_instance_valid(brain) and brain.get_parent() == bot:
			BotSystem._brains.erase(brain)
			brain.queue_free()
	if bot.element != element:
		bot.spawn_at(SpawnSystem.get_spawn_for_team(team), element, true)
	bot.teleport_to(at, _yaw_to(at, face))
	_posed.append([bot, _yaw_to(at, face), 0.0, 0.0])
	return bot


func _pose(bot: RemotePlayer, yaw: float, pitch: float, move := 0.0) -> void:
	for p in _posed:
		if p[0] == bot:
			p[1] = yaw
			p[2] = pitch
			p[3] = move


func _clear() -> void:
	_posed.clear()
	_immortal.clear()
	BotSystem.remove_all_bots()
	await get_tree().create_timer(2.0).timeout


func _frame_cam(kind: String, caster: Vector3, target: Vector3) -> void:
	_frame = [kind, caster, target]
	var fwd := (target - caster)
	fwd.y = 0.0
	fwd = fwd.normalized()
	var side := fwd.cross(Vector3.UP).normalized()
	_sub.size = Vector2i(1920, 1080)
	_cam.fov = 55.0
	var eye := Vector3.ZERO
	var look := Vector3.ZERO
	match kind:
		"portrait":
			_sub.size = Vector2i(1200, 1600)
			_cam.fov = 34.0
			eye = caster + fwd * 3.4 + side * 1.6 + Vector3(0, 1.3, 0)
			look = caster + Vector3(0, 0.95, 0)
		"close":
			_cam.fov = 40.0
			eye = caster + fwd * 1.8 + side * 3.0 + Vector3(0, 1.5, 0)
			look = caster + fwd * 0.9 + Vector3(0, 1.0, 0)
		"front":
			_cam.fov = 40.0
			eye = caster + fwd * 6.5 + side * 1.2 + Vector3(0, 1.7, 0)
			look = caster + fwd * 2.0 + Vector3(0, 1.3, 0)
		"wide":
			_cam.fov = 50.0
			eye = caster - fwd * 3.0 + side * 2.0 + Vector3(0, 2.8, 0)
			look = caster.lerp(target, 0.6) + Vector3(0, 0.6, 0)
		_:
			_cam.fov = 44.0
			eye = caster - fwd * 2.2 + side * 1.5 + Vector3(0, 1.7, 0)
			look = caster.lerp(target, 0.7) + Vector3(0, 0.8, 0)
	_cam.global_position = eye
	_cam.look_at(look, Vector3.UP)
	_root_cam.fov = _cam.fov
	_root_cam.global_transform = _cam.global_transform


func _shoot(id: String) -> void:
	var spec: Array = SHOTS[id]
	var element: int = spec[0]
	var opts: Dictionary = spec[2]
	var caster_at := _deck(opts.get("from", CASTER_AT), opts.get("up", 4.0))
	var target_m: float = opts.get("target_m", 7.0)
	var fwd := (_deck(opts.get("toward", TARGET_AT)) - _deck(opts.get("from", CASTER_AT))).normalized()
	var target_at := caster_at + fwd * target_m

	if spec[1] is int and spec[1] < 0:
		_spawn(element, 1, caster_at, caster_at + fwd * 3.4 + fwd.cross(Vector3.UP).normalized() * 1.6)
		_frame_cam("portrait", caster_at, target_at)
		await get_tree().create_timer(2.5).timeout
		for i in 3:
			await _save(id, i)
			await get_tree().create_timer(0.7).timeout
		return

	var caster := _spawn(element, 1, caster_at, target_at)
	var target: RemotePlayer = null
	if not opts.get("no_target", false):
		target = _spawn(GameConsts.Element.EARTH, 2, target_at, caster_at)
	var extras: Array = []
	for i in int(opts.get("extra", 0)):
		var off := fwd.cross(Vector3.UP).normalized() * (1.6 if i % 2 == 0 else -1.6)
		var at := target_at + off - fwd * 0.6
		var e := _spawn([GameConsts.Element.FIRE, GameConsts.Element.ICE][i % 2], 2, at, caster_at)
		extras.append(e)
	if opts.get("special", "") not in ["corpse"] and id != "combo_raise_dead":
		if target:
			_immortal.append(target)
		_immortal.append_array(extras)
	_frame_cam(opts.get("cam", "over"), caster_at, target_at)
	await get_tree().create_timer(2.0).timeout

	var slot := -1
	if spec[1] is String:
		caster.grant_weapon(spec[1])
		await get_tree().create_timer(0.5).timeout
		for i in caster.weapons.size():
			if caster.weapons[i].get_script().resource_path.ends_with("/%s.gd" % spec[1]):
				slot = i
		if slot < 0:
			push_error("[DocShots] %s: combo %s not granted" % [id, spec[1]])
			return
	else:
		slot = spec[1]
	ServerRequests.switch_weapon(caster, slot)
	await get_tree().create_timer(0.6).timeout

	if opts.get("special", "") == "corpse":
		target.health = 1.0
		target.take_damage(5.0, GameConsts.DamageType.PHYSICAL, caster)
		await get_tree().create_timer(2.5).timeout

	var aim_point: Vector3 = SpatialQuery.collision_center(target) if target else target_at
	match opts.get("aim", "target"):
		"ground":
			aim_point = caster_at + fwd * 2.0
		"feet":
			aim_point = target.global_position if target else target_at
	var eye := caster.global_position + Vector3(0, 1.5, 0)
	var aim_dir := (aim_point - eye).normalized()
	_pose(caster, _yaw_to(caster.global_position, aim_point), asin(clampf(aim_dir.y, -1.0, 1.0)))
	await get_tree().create_timer(0.3).timeout
	# The deck's planks have gaps; step forward until the spell has somewhere to land.
	var w: Weapon = caster.weapon_at(slot)
	for i in 8:
		if opts.get("special", "") == "clone" or w.can_fire(caster, aim_dir):
			break
		caster.teleport_to(caster.global_position + fwd * 0.4, caster.rotation.y)
		await get_tree().create_timer(0.3).timeout
		eye = caster.global_position + Vector3(0, 1.5, 0)
		aim_dir = (aim_point - eye).normalized()

	var frames: Array = opts.get("frames", [0.2, 0.5, 1.0])
	var t0 := Time.get_ticks_msec() / 1000.0
	if frames[0] < 0.0:
		await _save(id, 0)
		frames = frames.slice(1)
		t0 = Time.get_ticks_msec() / 1000.0
	_cast(caster, opts, aim_dir, id)
	var n := 0
	for t in frames:
		var wait: float = t0 + float(t) - Time.get_ticks_msec() / 1000.0
		if wait > 0.0:
			await get_tree().create_timer(wait).timeout
		await _save(id, n + 1)
		n += 1


## Casts land inside a physics tick, as a player's do (FireControl): an effect's deferred add_child
## then runs before register_effect's queue_free, where from an idle-step timer it ran after.
func _cast(caster: RemotePlayer, opts: Dictionary, aim_dir: Vector3, id: String) -> void:
	var w: Weapon = caster.weapon_at(caster.current_weapon_idx)
	var special: String = opts.get("special", "")
	if special == "clone":
		_pose(caster, caster.rotation.y, 0.0, 1.0)
		await get_tree().create_timer(0.6).timeout
		await get_tree().physics_frame
		w.fire(caster, Vector3.INF, aim_dir, 0.0, false)
		return
	var hold: float = opts.get("hold", 0.0)
	if hold > 0.0:
		var t_end := Time.get_ticks_msec() / 1000.0 + hold
		while Time.get_ticks_msec() / 1000.0 < t_end and is_instance_valid(caster):
			await get_tree().physics_frame
			ServerRequests.attack(caster, Vector3.INF, aim_dir, 0.0, false, 0)
			await get_tree().create_timer(maxf(w.cooldown, 0.1)).timeout
		if is_instance_valid(caster):
			ServerRequests.stop_attack(caster)
		return
	for i in int(opts.get("casts", 1)):
		if not is_instance_valid(caster):
			return
		await get_tree().physics_frame
		var shot := ServerRequests.attack(caster, Vector3.INF, aim_dir, float(opts.get("charge", 0.0)), false, 0)
		print("[DocShots] %s cast %d -> %s" % [id, i, FireControl.Shot.keys()[shot]])
		await get_tree().create_timer(maxf(w.cooldown, 0.1) + 0.05).timeout
	if special == "thornplant":
		await get_tree().create_timer(5.5).timeout
		for i in 2:
			await get_tree().physics_frame
			ServerRequests.attack(caster, Vector3.INF, aim_dir, 0.0, false, 0)
			await get_tree().create_timer(2.5).timeout


func _save(id: String, n: int) -> void:
	var cams := _env("SHOT_CAMS", "").split(",", false)
	if cams.is_empty():
		await _render()
		_write("%s_%d" % [id, n])
		return
	var keep: Array = _frame.duplicate()
	for c in cams:
		_frame_cam(c, keep[1], keep[2])
		await _render()
		await _render()
		_write("%s_%d_%s" % [id, n, c])
	_frame_cam(keep[0], keep[1], keep[2])


## Renders the frame by hand: macOS stops drawing a covered or minimised window, and
## frame_post_draw with it, so a shot waiting on one would wait forever.
func _render() -> void:
	await get_tree().process_frame
	RenderingServer.force_draw(false)


func _write(stem: String) -> void:
	var path := "%s/%s.png" % [_dir, stem]
	_sub.get_texture().get_image().save_png(path)
	print("[DocShots] ", path)
