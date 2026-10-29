class_name Tornado
extends CharacterBody3D

## Tornado summon — the Wizard Wars combo spell "weapon_tornadospell". A whirlwind that drifts
## out of the caster's hands, turns toward the nearest enemy it can see and grinds along the
## ground for half a minute. It is not solid and nothing can hurt it: the only way out of one
## is to outrun it, and it moves at better than half a wizard's top speed.
##
## Anything hostile it passes over is ground down and thrown — the funnel drags a victim in and
## the lift rises the closer they get, so being caught means being flung, and the fall is as
## dangerous as the wind. What it kills it goes on throwing: a fresh corpse is picked up and
## heaved with everyone else until it has lain still long enough to settle for good.
##
## Like the giant plant it belongs to the world once cast: the caster dying, changing class or
## leaving takes nothing away from it, and it simply expires.

const SCALE := GameConsts.SCALE_FACTOR
const SPEED := 8.0 * 0.55              # sv_maxspeed * TORNADO_VELOCITY — 4.4 m/s
const LIFETIME := 30.0
const SIGHT_RANGE := 1024.0 * SCALE    # 25.6 m
const REACH := 100.0 * SCALE           # 2.5 m — the funnel's own width
const DAMAGE := 15.0                   # per think — 150/s, but only while it has you grounded
const THINK_INTERVAL := 0.1
const EYE_HEIGHT := 36.0 * SCALE       # chest height: what it sees and grabs with
const RISE := 10.0 * SCALE             # 0.25 m/s — it never climbs faster than this
const GRAVITY := 20.0                  # 800 sv_units, as MovementConfig.gravity
const PULL := 3.0                      # the vortex, applied to both axes at once
const LIFT := 500.0 * SCALE * SCALE    # 500 u/s at one unit out, in m/s at one metre out
const MAX_LIFT := 1200.0 * SCALE       # 30 m/s
const TOSS_DELAY := 0.5                # the funnel heaves whoever it has hold of this often
const TOSS_LIFT := 12.0                # 480 u/s — what a throw is worth: about 3.6 m of air
const TOSS_OUT := 4.0                  # 160 u/s outward with it, so the arc clears the funnel
const MODEL := "models/combo/tornado.mdl"
const ALPHA := 160.0 / 255.0           # renderamt 160, as the original spawned it
const CAST_SOUND := "spells/combos/tornado_cast.wav"
const WIND_SOUND := "spells/combos/tornado_spin.wav"
const WIND_RANGE := 40.0               # heard well outside the room it is wrecking

var owner_node: Node3D
var owner_peer_id := 0  # 0 = nobody's (a /spawn'd tornado); bots own theirs with negative ids
var team: int = GameConsts.Team.NONE

var _entity := EntityBehavior.new()
var _model: Node3D
var _target: Node3D
var _toss_ready := TOSS_DELAY  # counts down to the next throw; see _whirl
var _heading := Vector3.FORWARD  # horizontal unit: where it wanders when nothing is in sight
var _age := 0.0
var _think_timer := 0.0


func setup(data: Dictionary, is_host := true) -> void:
	position = data.get("position", Vector3.ZERO)
	owner_peer_id = data.get("owner_peer_id", 0)
	team = data.get("team", GameConsts.Team.NONE)
	var dir: Vector3 = data.get("direction", Vector3.FORWARD)
	dir.y = 0.0
	if dir.length_squared() > 0.0001:
		_heading = dir.normalized()
	_entity.initialize(self, is_host)


func _ready() -> void:
	_model = AssetLoader.load_model(MODEL)
	if _model:
		add_child(_model)
		AssetLoader.set_model_alpha(_model, ALPHA)
		var anim: AnimationPlayer = _model.find_child("AnimationPlayer")
		if anim and anim.has_animation("idle"):
			anim.get_animation("idle").loop_mode = Animation.LOOP_LINEAR
			anim.play("idle")

	# Not solid — a tornado is wind, and the original was SOLID_NOT. It still needs a hull to
	# scrape along the world with, so it keeps a shape and a world mask on the authority only;
	# nothing collides with it, on any peer.
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = REACH * 0.25
	cyl.height = EYE_HEIGHT * 2.0
	col.shape = cyl
	col.position.y = EYE_HEIGHT
	add_child(col)
	collision_layer = 0
	collision_mask = (GameConsts.MASK_WORLD | GameConsts.MASK_CLIP) if _entity.is_host else 0

	# Both sounds are attached rather than played into the world: the entity exists on every
	# peer, so each plays its own copy and the wind travels with the funnel.
	SoundSystem.spawn_on(self, CAST_SOUND, false, WIND_RANGE)
	SoundSystem.spawn_on(self, WIND_SOUND, true, WIND_RANGE, "Wind")


func _physics_process(delta: float) -> void:
	if not _entity.is_host:
		return

	# It outlives its caster, so a freed owner must not reach target filtering or damage
	# credit — both read properties off it.
	if not is_instance_valid(owner_node):
		owner_node = null

	_age += delta
	if _age >= LIFETIME:
		_entity.destroy()
		return

	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_INTERVAL
		_retarget()
		_whirl()

	_drift(delta)


## Ten times a second, as the original thought: it always chases the nearest enemy it can
## actually see, and keeps its last heading when it can see none.
func _retarget() -> void:
	_target = Combat.find_homing_target(self, owner_node, team, SIGHT_RANGE,
			get_rid(), _eye())
	if not _target:
		return
	var to_target := SpatialQuery.collision_center(_target) - global_position
	to_target.y = 0.0
	if to_target.length_squared() > 0.0001:
		_heading = to_target.normalized()


## It hugs the ground: gravity pulls it down, but it can never climb faster than a crawl, and
## anything it scrapes against gives it that crawl back. So it skims floors, rides down steps
## and pours off ledges without ever taking off.
func _drift(delta: float) -> void:
	velocity.x = _heading.x * SPEED
	velocity.z = _heading.z * SPEED
	velocity.y = minf(velocity.y, RISE) - GRAVITY * delta
	move_and_slide()
	if get_slide_collision_count() > 0:
		velocity.y = RISE
	# Wandering into a wall would otherwise pin it there for the rest of its life; the original
	# was MOVETYPE_BOUNCE and came off. A tornado with a target steers again on the next think.
	if is_on_wall():
		var n := get_wall_normal()
		n.y = 0.0
		if n.length_squared() > 0.0001:
			n = n.normalized()
			_heading = (_heading - 2.0 * _heading.dot(n) * n).normalized()


## The funnel: everything hostile standing inside it is ground down and, on the funnel's clock,
## thrown. No falloff and no line of sight — if you are in it, you are in it — but only while
## your feet are on the ground.
func _whirl() -> void:
	# The funnel throws on its own clock: every half second it heaves whoever it has hold of, and
	# grinds them the rest of the time. Per-victim timers were the obvious way to do this and the
	# wrong one — the clock drains while a victim is in the air, and the funnel slides on and off
	# them between thinks, so the half second almost never banked and the throw kept not coming.
	_toss_ready -= THINK_INTERVAL
	var throwing := _toss_ready <= 0.0
	if throwing:
		_toss_ready = TOSS_DELAY

	var attacker: Node3D = owner_node if owner_node else self
	var eye := _eye()
	for node in SpatialQuery.nodes_near(&"damageable", eye, REACH):
		if not (node is Node3D) or not node.is_inside_tree() or node == self:
			continue
		if node.get("is_dead") or Teams.summon_spares(team, owner_node, node):
			continue
		var to_eye := eye - SpatialQuery.collision_center(node)
		if to_eye.length() > REACH:
			continue
		# Neither grip nor bite on a victim in the air. Being thrown is the relief, and the funnel
		# moves at better than half a wizard's run — it keeps pace under anyone it throws, so
		# left to bite them in flight it just grinds them out anyway and the throw buys nothing.
		var body := node as CharacterBody3D
		if body != null and not _on_ground(body):
			continue
		if node.has_method("take_damage"):
			node.take_damage(DAMAGE, GameConsts.DamageType.PHYSICAL, attacker)
		_grip(node, to_eye, throwing)

	# ...and what it cannot hurt but can still move. A corpse is on nobody's side, so nothing is
	# spared and nothing is bitten: it is picked up and thrown like anything else the funnel has
	# hold of, until it has lain still long enough to have stopped being a simulation at all.
	# Only on the throw — the drag is there to beat a victim's own movement, and a corpse has
	# none to beat; kept up between throws it would hold one hovering instead of letting it fall.
	if throwing:
		for node in SpatialQuery.nodes_near(&"pushable", eye, REACH):
			if not (node is Node3D) or not node.is_inside_tree():
				continue
			var to_eye := eye - SpatialQuery.collision_center(node)
			if to_eye.length() > REACH:
				continue
			_grip(node, to_eye, true)


## Being caught is a cycle, not a place you are held: dragged along the floor toward the middle,
## heaved up and outward on the funnel's clock, and picked up again wherever you come down.
##
## What decides the throw is that clock, not how near the eye you are. The original threw on
## distance — a lift of 1/d, which only means anything within a few centimetres of a point that
## moves 0.4 m between thinks. Whether any think ever lands inside that window is a coin flip, so
## the throw almost never fired and the funnel just held its victim and ground them to death.
##
## Who may be grabbed at all is _whirl's question, not this one — a living victim only while
## their feet are on the ground, a corpse whenever the funnel reaches it. What is grabbed moves
## however its own kind of body moves (Combat.push_body). Once thrown a victim is ballistic
## until they land, and safe until then.
func _grip(node: Node3D, to_eye: Vector3, throwing: bool) -> void:
	var pull := Vector3(to_eye.x, 0.0, to_eye.z)
	if not throwing:
		# Dragged toward the middle, feet still down. No lift: GoldSrc leaves you standing below
		# 180 u/s and throws a standing player's vertical velocity away anyway, and a victim
		# nudged gently upward drifts out of the funnel's reach before it can do anything with them.
		Combat.push_body(node, Vector3(pull.x * PULL, 0.0, pull.z * PULL))
		return

	# Up, and outward rather than inward — flung clear you land beside the funnel and have to be
	# run down again, where the original's inward throw just returned you to the eye to die.
	# A throw is worth TOSS_LIFT wherever it catches you; dead centre still throws harder.
	var lift := clampf(PULL * LIFT / maxf(pull.length(), 0.01), TOSS_LIFT, MAX_LIFT)
	var out := _toss_direction(pull)
	Combat.push_body(node, Vector3(out.x * TOSS_OUT, lift, out.z * TOSS_OUT))


## Which way "out" is. At the eye there is no direction to speak of — the offset is centimetres
## of noise — so the throw picks one, which is the honest answer for being dead centre.
func _toss_direction(pull: Vector3) -> Vector3:
	if pull.length_squared() > 0.0025:  # 5 cm
		return -pull.normalized()
	var angle := randf() * TAU
	return Vector3(cos(angle), 0.0, sin(angle))


## GoldSrc's `onground`. netmove owns the authoritative flag for anything it drives — a
## CharacterBody3D's own is_on_floor() is left corrupted by walk_move's elevated move_and_slide
## (see movement.gd) — so ask the simulation when the victim has one, and the body otherwise.
func _on_ground(body: CharacterBody3D) -> bool:
	if body.has_method("has_server_movement") and body.has_server_movement():
		return body.get_server_movement().state.on_floor
	return body.is_on_floor()


func _eye() -> Vector3:
	return global_position + Vector3(0.0, EYE_HEIGHT, 0.0)

