class_name Wombat
extends RigidBody3D

## Wombat summon — the Wizard Wars combo spell "weapon_wombatspell". A snark by another name:
## thrown underarm, it lands running and hunts on four feet — picking whoever it can see and
## leaping at them, over and over, for forty seconds.
##
## It is the only summon in the set that does anything for your own side. What it does to an
## enemy it lands on is bite them for 100; what it does to a teammate it lands on is heal them
## 200 and burn off whatever is poisoning or burning them. So it is thrown into a fight rather
## than at a person, and which of those two things it does next is not up to the caster.
##
## 1000 HP, and hurting it makes it yours: it drops whatever it was chasing and comes for
## whoever hit it.

const SCALE := GameConsts.SCALE_FACTOR
const LAUNCH_SPEED := 450.0 * SCALE     # WOMBAT_VELOCITY, a raw unit speed — 11.25 m/s
const BITE_DAMAGE := 100.0
const BLESS_HEAL := 200.0
const MAX_HEALTH := 1000.0
const LIFETIME := 40.0
const SIGHT_RANGE := 1024.0 * SCALE     # 25.6 m — the length of a fight, not of a room
const HUNT_INTERVAL := 0.5              # how often it looks for someone better to jump on
const LEAP_COOLDOWN := 0.3              # a beat on its feet between one leap and the next
const LEAP_RISE := 4.0                  # up-speed of a leap; with half gravity, ~0.8 s in the air
const MAX_RISE := 8.0                   # unless it is leaping at something above it
const WANDER_SPEED := 3.5               # a hop in a random direction when it can't see anyone
const WANDER_PAUSE := Vector2(0.6, 1.2) # and it takes its time between those, unlike a hunt
const TOUCH_COOLDOWN := 0.5             # between one bite or blessing and the next
const TOUCH_RANGE := 1.0                # reach of the lunge, from its hull to a standing body
const NEAR_RANGE := 100.0 * SCALE       # 2.5 m — close enough to be winding up at someone
const STUCK_INTERVAL := 2.0             # how often it asks whether it is getting anywhere
const STUCK_DISTANCE := 1.0 * SCALE     # moved less than this since? it is wedged
const RADIUS := 0.1                     # GoldSrc hull was 8 units across
const GRAVITY_SCALE := 0.5              # pev->gravity 0.5 — it hangs in the air between bounces
const GRAVITY := 20.0 * GRAVITY_SCALE   # world gravity (project default_gravity) at that scale
const BOUNCE := 0.2                     # it lands on its feet; it does not bounce like a ball
const FRICTION := 0.5                   # pev->friction 0.5
const TURN_RATE := 10.0                 # rad/s the body swings round to face where it is going
const MODEL := "models/combo/wombat.mdl"
const LAUNCH_SOUND := "monster/wombat/wblaunch.wav"
const BLESS_SOUND := "monster/wombat/wbstrength.wav"
const BITE_SOUNDS := ["monster/wombat/wbattack1.wav", "monster/wombat/wbattack2.wav",
	"monster/wombat/wbattack3.wav"]

var owner_node: Node3D
var owner_peer_id := 0  # 0 = nobody's (a /spawn'd wombat); bots own theirs with negative ids
var team: int = GameConsts.Team.NONE
var is_dead: bool:
	get: return _summon.is_dead
var health: float:
	get: return _summon.health
var max_health: float:
	get: return _summon.max_health

var _summon := SummonBehavior.new()
## Every clip wombat.mdl carries loops, and the model says so — nothing to override.
var _rig := ModelRig.new()
var _nav := MonsterNav.new()
## Somewhere to be when there is nobody to fight. A summoned wombat has none and bounces about
## where it was thrown; a siege sets it to the altar and it leaps its way across the map. Same
## contract as Skeleton.objective. INF = no objective.
var objective := Vector3.INF

var _model: Node3D
var _target: Node3D
## Where the route says to go, refreshed every frame so the nav's own clocks run at frame rate —
## a leap asks only when it fires, which is seconds apart.
var _nav_dir := Vector3.ZERO
var _age := 0.0
## 0 = forever. A summon is a spell that wears off; a siege attacker is not, and the altar would
## otherwise outlast every wave by standing still for forty seconds.
var _lifetime := LIFETIME
## Starts unreachable: the original held the first hunt off until the wombat had bounced once,
## so a throw carries where it was aimed instead of curving away in mid-air.
var _hunt_timer := INF
var _touch_timer := 0.0
var _leap_timer := 0.0
var _stuck_timer := STUCK_INTERVAL
var _hold_anim := ""
var _hold_timer := 0.0
var _prev_hunt_pos := Vector3.ZERO
var _prev_pos := Vector3.ZERO
var _grounded := false
var _bounced := false


func setup(data: Dictionary, is_host := true) -> void:
	owner_peer_id = data.get("owner_peer_id", 0)
	team = data.get("team", GameConsts.Team.NONE)
	_summon.setup(self, data, is_host, MAX_HEALTH, _die)
	_nav.setup(self)
	_lifetime = float(data.get("lifetime", LIFETIME))
	linear_velocity = data.get("velocity", Vector3.FORWARD * LAUNCH_SPEED)
	add_to_group("projectile")


func _ready() -> void:
	_model = AssetLoader.load_model(MODEL)
	_rig.initialize(self, _model.find_child("AnimationPlayer") if _model else null)
	if _model:
		add_child(_model)
		_summon.set_anim_player(_rig.anim_player)  # publishes the played clip via NetInterp:net_anim
		_rig.play("idle")

	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = RADIUS
	col.shape = sphere
	add_child(col)
	collision_layer = GameConsts.MASK_ENTITY
	collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_CLIP
	gravity_scale = GRAVITY_SCALE
	# A wombat has feet. Its hull is a sphere, and hop spins any body with an inertia tensor,
	# so without this it rolls end over end and the model rolls with it — the yaw below is the
	# only rotation it is allowed.
	lock_rotation = true
	var mat := PhysicsMaterial.new()
	mat.bounce = BOUNCE
	mat.friction = FRICTION
	physics_material_override = mat
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_bounce)

	_prev_hunt_pos = global_position
	_prev_pos = global_position
	if _summon.is_host:  # play_3d reaches the clients; theirs would be a second, and late, copy
		SoundSystem.play_3d(LAUNCH_SOUND, global_position, 1.5)  # pitch 150, as the original threw it


func _physics_process(delta: float) -> void:
	_summon.tick(delta)
	_rig.tick(delta)
	if not _summon.is_host:
		return

	# It outlives its caster, so a freed owner must not reach target filtering or damage credit.
	if not is_instance_valid(owner_node):
		owner_node = null

	_age += delta
	if _lifetime > 0.0 and _age >= _lifetime:
		_die()
		return

	# Landing on someone is checked every frame rather than on the hunt: it is travelling at
	# 11 m/s and the hunt is half a second apart, so anything slower would pass clean through.
	_touch_timer -= delta
	_hold_timer -= delta
	_check_landing()
	_prev_pos = global_position

	_hunt_timer -= delta
	if _hunt_timer <= 0.0:
		_hunt_timer = HUNT_INTERVAL
		_hunt()

	var goal := _goal()
	_nav_dir = _nav.desired_dir(delta, goal) if goal != Vector3.INF else Vector3.ZERO

	_grounded = _on_ground()
	_leap_timer -= delta
	if _bounced and _grounded and _leap_timer <= 0.0:
		_leap()

	_face(delta)
	_update_anim()

	_stuck_timer -= delta
	if _stuck_timer <= 0.0:
		_stuck_timer = STUCK_INTERVAL
		# Wedged in a corner, or sitting in one: throw itself somewhere and let it work it out.
		if global_position.distance_to(_prev_hunt_pos) < STUCK_DISTANCE:
			_wander_hop()
		_prev_hunt_pos = global_position


## Who it is going for. Kept fresh rather than picked once: a wombat that loses sight of one
## wizard should be after the next before it lands.
func _hunt() -> void:
	if not (is_instance_valid(_target) and _target.is_inside_tree()) or _target.get("is_dead"):
		_target = null
	if _target != null \
			and global_position.distance_to(SpatialQuery.collision_center(_target)) <= SIGHT_RANGE:
		return
	# No cone: it looks all the way round, and from head height so a step doesn't blind it.
	_target = Combat.find_homing_target(self, owner_node, team, SIGHT_RANGE,
			get_rid(), global_position + Vector3.UP * RADIUS * 2.0)


## Where it is headed: whoever it is chasing, else its objective, else nowhere.
func _goal() -> Vector3:
	if is_instance_valid(_target):
		return SpatialQuery.collision_center(_target)
	return objective


## Off its back feet at whatever it is going for, or a hop somewhere if it has nothing.
func _leap() -> void:
	var goal := _goal()
	if goal == Vector3.INF:
		_wander_hop()
		return
	var to_target := goal - global_position
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	if flat.length_squared() < 0.0001:
		_wander_hop()
		return
	# Enough height to clear a target standing above it — a ledge, a step, a staircase.
	var rise := clampf(LEAP_RISE + maxf(to_target.y, 0.0) * 1.5, LEAP_RISE, MAX_RISE)
	# Round a corner rather than bouncing off it. The route only answers when the target is far
	# enough to need one, and then the hop is sized for the waypoint ahead, not for a target on
	# the wrong side of a wall.
	if _nav_dir != Vector3.ZERO:
		flat = _nav_dir * minf(flat.length(), SIGHT_RANGE * 0.25)
	# Cleared to land on the mark: how fast it has to cross the ground in its time in the air.
	var speed := clampf(flat.length() / (2.0 * rise / GRAVITY), WANDER_SPEED, LAUNCH_SPEED)
	_leap_toward(flat, speed, rise)


## Nobody in sight, or wedged: a hop somewhere else, and it looks again from there.
func _wander_hop() -> void:
	var angle := randf() * TAU
	_leap_toward(Vector3(sin(angle), 0.0, cos(angle)), WANDER_SPEED, LEAP_RISE)
	_leap_timer = randf_range(WANDER_PAUSE.x, WANDER_PAUSE.y)


func _leap_toward(dir: Vector3, speed: float, rise: float) -> void:
	_leap_timer = LEAP_COOLDOWN
	linear_velocity = dir.normalized() * speed + Vector3.UP * rise
	_rig.play("jump")


## Something under its feet within a hull's reach — hop reports contacts, but a wombat that has
## settled on the floor isn't reporting anything, so ask the world instead.
func _on_ground() -> bool:
	var ray := Combat.raycast_world(self, global_position, Vector3.DOWN, RADIUS + 0.15,
			get_rid(), GameConsts.MASK_WORLD | GameConsts.MASK_CLIP)
	return not ray.result.is_empty()


## Faces where it is going: at its quarry if it has one, along its own flight if it doesn't.
## Yaw only — the body is rotation-locked, so this is the whole of its orientation.
func _face(delta: float) -> void:
	var dir := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	if _target != null and is_instance_valid(_target):
		var to_target := SpatialQuery.collision_center(_target) - global_position
		dir = Vector3(to_target.x, 0.0, to_target.z)
	if dir.length_squared() < 0.0001:
		return
	# Only when it actually turns: every write is a transform pushed at the physics server, and
	# a settled entity that stops publishing costs nothing on the wire.
	var next := rotate_toward(rotation.y, atan2(-dir.x, -dir.z), TURN_RATE * delta)
	if absf(angle_difference(rotation.y, next)) > 0.001:
		rotation.y = next


## Teeth for whoever it just bit, the leap while it is off the ground, and the scurry it does
## on its feet the rest of the time.
func _update_anim() -> void:
	if _hold_timer > 0.0:
		_rig.play(_hold_anim)
		return
	if not _grounded:
		_rig.play("jump")
		return
	if _target and is_instance_valid(_target) \
			and global_position.distance_to(SpatialQuery.collision_center(_target)) < NEAR_RANGE:
		_rig.play("attack")
		return
	_rig.play("idle")


## A clip that has to finish being seen — the bite and the blessing both land in a single
## frame, and the leap it is already in the middle of would paint over them.
func _hold(anim_name: String, seconds: float) -> void:
	_hold_anim = anim_name
	_hold_timer = seconds
	_rig.play(anim_name)


## The first thing it bounces off starts its clock — see _hunt_timer.
func _on_bounce(_body: Node) -> void:
	if not _bounced:
		_bounced = true
		_hunt_timer = 0.0


## What it does when it lands on somebody, which is the whole spell. An enemy is bitten; one of
## its own side is healed and cleaned of whatever was eating them. Either way it will not do it
## again for half a second.
func _check_landing() -> void:
	if _touch_timer > 0.0 or _summon.is_dead:
		return
	var touched := _nearest_each_side(TOUCH_RANGE)
	var foe: Node3D = touched[0]
	if foe:
		_touch_timer = TOUCH_COOLDOWN
		SoundSystem.play_3d(BITE_SOUNDS[randi() % BITE_SOUNDS.size()], global_position)
		if foe.has_method("take_damage"):
			foe.take_damage(BITE_DAMAGE, GameConsts.DamageType.PHYSICAL,
				owner_node if owner_node else self)
		_hold("attack", TOUCH_COOLDOWN)
		return

	var friend: Node3D = touched[1]
	if friend and friend.has_method("heal"):
		_touch_timer = TOUCH_COOLDOWN
		SoundSystem.play_3d(BLESS_SOUND, global_position)
		friend.heal(BLESS_HEAL, owner_node if owner_node else self)  # heal() also clears statuses
		_hold("jump", TOUCH_COOLDOWN)


## Nearest enemy and nearest ally within `reach` of the ground it covered this frame, as
## [foe, friend] — measured to the whole path, since a leap crosses a body in less than a frame.
## The wombat is the only summon here with any use for its own side, and it wants both answers
## on the tick it lands: one pass, since the search and the distance to the path are the same
## question for either side and only where the answer lands differs.
func _nearest_each_side(reach: float) -> Array[Node3D]:
	var foe: Node3D = null
	var friend: Node3D = null
	var foe_dist := reach
	var friend_dist := reach
	for node in SpatialQuery.nodes_near_segment(&"damageable", _prev_pos, global_position, reach):
		if node == self or not is_instance_valid(node) or not (node is Node3D):
			continue
		if not node.is_inside_tree() or node.get("is_dead"):
			continue
		var center: Vector3 = SpatialQuery.collision_center(node)
		var dist := GeomUtil.dist_to_segment(center, _prev_pos, global_position)
		if Teams.summon_spares(team, owner_node, node):
			if dist < friend_dist:
				friend_dist = dist
				friend = node
		elif dist < foe_dist:
			foe_dist = dist
			foe = node
	return [foe, friend]


## Hurting it makes it yours — it drops whatever it was chasing and comes for you instead.
func take_damage(amount: float, type: int = GameConsts.DamageType.PHYSICAL, attacker: Node3D = null) -> void:
	if attacker and is_instance_valid(attacker) and _summon.is_host \
			and not Teams.summon_spares(team, owner_node, attacker):
		_target = attacker
		_hunt_timer = HUNT_INTERVAL  # it has its quarry; don't look past them on the next tick
		_leap_timer = 0.0
	_summon.take_damage(amount, type, attacker)


func _die() -> void:
	var pos := global_position
	_death_effect(pos)
	SoundSystem.play_3d(BITE_SOUNDS[0], pos, 0.5)  # to every peer, whether or not the event reaches them
	_summon.die_at(pos)


## Death is a one-shot event, not a property that converges.
func _apply_sync_state(state: Dictionary) -> void:
	if "death_pos" in state:
		_death_effect(state.death_pos)


## The original burst it into blood and played common/bodysplat.wav, neither of which shipped
## with the assets. Flesh gibs fall back to wood inside GibEffect and will upgrade themselves
## for free if the model ever turns up; the cry is its own bite, dropped an octave (_die).
func _death_effect(pos: Vector3) -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	GibEffect.spawn(3, pos, Vector3(0.4, 0.4, 0.4), scene_root)


## Animation rides the shared NetInterp slot (see EntityBehavior.set_anim_player).
func net_sync_properties() -> PackedStringArray:
	return PackedStringArray(["NetInterp:net_anim"])
