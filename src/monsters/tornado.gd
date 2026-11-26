class_name Tornado
extends CharacterBody3D

## Tornado summon — the Wizard Wars combo spell "weapon_tornadospell". A whirlwind that drifts
## out of the caster's hands, turns toward the nearest enemy it can see and grinds along the
## ground for half a minute. It is not solid and nothing can hurt it: the only way out of one
## is to outrun it, and it moves at better than half a wizard's top speed.
##
## It is wind, the same air the weather blows (WeatherSystem.airflow): it drags everything near
## it along the ground into its middle, round, up its core and out over the top — wizards and
## monsters, spells in flight, corpses, satchels, sparks. Anything hostile inside its reach is
## ground down on the way through.
##
## Like the giant plant it belongs to the world once cast: the caster dying, changing class or
## leaving takes nothing away from it, and it simply expires.

const SCALE := GameConsts.SCALE_FACTOR
const SPEED := 8.0 * 0.55              # sv_maxspeed * TORNADO_VELOCITY — 4.4 m/s
const LIFETIME := 30.0
const SIGHT_RANGE := 1024.0 * SCALE    # 25.6 m
const REACH := 100.0 * SCALE           # 2.5 m — the funnel's own width
const DAMAGE := 8.0                    # per think, 80/s: a catch is about a second in it
const THINK_INTERVAL := 0.1
const EYE_HEIGHT := 36.0 * SCALE       # chest height: what it sees and grabs with
const RISE := 10.0 * SCALE             # 0.25 m/s — it never climbs faster than this
const GRAVITY := 20.0                  # 800 sv_units, as MovementConfig.gravity
## Its air (m/s; see airflow). Along the ground it pulls in hard enough at REACH that only a
## wizard running flat out gets away, up its core it lifts harder than gravity until LIFT_TOP, and
## over the top it throws out sideways, so a victim comes down beside it, not back into it.
const FIELD := REACH * 2.0             # no air of its own beyond
const INFLOW := 40.0
const INFLOW_TOP := 1.5                # ...fading out a metre above this
const SWIRL := 12.0
const CORE := 1.2
const UPDRAFT := 32.0
const LIFT_TOP := 3.0                  # ...fading out a metre above this
const OUTFLOW := 25.0
const OUTFLOW_BAND := Vector2(LIFT_TOP - 0.5, LIFT_TOP + 2.5)
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

	add_to_group(WeatherSystem.WIND_SOURCES)

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


## The grind: everything hostile inside its reach, on the ground or thrown up its core. No falloff
## and no line of sight. Its air throws a victim clear within about a second, so the bite is
## what one catch costs, not a way to hold anyone up and grind them out.
func _whirl() -> void:
	var attacker: Node3D = owner_node if owner_node else self
	var eye := _eye()
	for node in SpatialQuery.nodes_near(&"damageable", eye, REACH):
		if not (node is Node3D) or not node.is_inside_tree() or node == self:
			continue
		if node.get("is_dead") or Teams.summon_spares(team, owner_node, node):
			continue
		if (eye - SpatialQuery.collision_center(node)).length() > REACH:
			continue
		if node.has_method("take_damage"):
			node.take_damage(DAMAGE, GameConsts.DamageType.PHYSICAL, attacker)


## The air it moves at `p` (m/s), for WeatherSystem.airflow: in along the ground, round, up the
## core and out over the top, none beyond FIELD. It spares no one: wind has no side.
func airflow(p: Vector3) -> Vector3:
	var off := p - global_position
	var h := off.y
	off.y = 0.0
	var r := off.length()
	if r >= FIELD or h < -1.0 or h > OUTFLOW_BAND.y:
		return Vector3.ZERO
	var out := off / r if r > 0.001 else Vector3.ZERO
	var ring := r / REACH if r < REACH else (FIELD - r) / REACH  # 0 on the axis, 1 at REACH, 0 at FIELD
	var air := Vector3.UP.cross(out) * (SWIRL * ring)
	air -= out * (INFLOW * ring * _below(h, INFLOW_TOP))
	if r < CORE:
		air.y += UPDRAFT * (1.0 - (r * r) / (CORE * CORE)) * _below(h, LIFT_TOP)
	if h > OUTFLOW_BAND.x:
		air += out * (OUTFLOW * minf(r / 0.5, 1.0) * (FIELD - r) / FIELD)
	return air


## 1 up to `top`, down to 0 a metre above it.
static func _below(h: float, top: float) -> float:
	return clampf(top + 1.0 - h, 0.0, 1.0)


func _eye() -> Vector3:
	return global_position + Vector3(0.0, EYE_HEIGHT, 0.0)

