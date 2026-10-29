class_name SpiritWiz
extends CharacterBody3D

## Spirit wizard summon — the Wizard Wars combo spell "weapon_spiritwizspell". The ghost of a
## wizard, wailing, that drifts where it was left until it lays eyes on someone.
##
## It is the only combo summon that can be killed and the only one that has to be looking at you:
## 600 HP, no armour of team-discount, and a field of view rather than the all-round sense the
## plant and the tornado hunt with. Get behind it and it does not know you are there. Shoot it and
## it turns to face you, which is the same thing as pointing its stare at you.
##
## That stare is what does the work — a beam of 20 every tenth of a second at anything in front
## of it, out to 25 m. Catching a body is a different matter: it hits for 600 and burns 200 of
## itself doing it, so it can take three wizards with it at the very most and usually fewer.

const SCALE := GameConsts.SCALE_FACTOR
const SPEED := 8.0 * 0.3               # sv_maxspeed * SPIRITWIZ_VELOCITY — 2.4 m/s
const DRIFT_SPEED := SPEED * 0.25      # 0.6 m/s when it has nothing to chase
const MAX_HEALTH := 600.0
const TOUCH_DAMAGE := 600.0
const TOUCH_COST := 200.0              # what taking a body costs it out of its own 600
const TOUCH_RANGE := 0.9               # its hull is 0.9 m across
## The original had no cooldown on taking a body — it leaned on the victim dying of the 600 to
## stop the touch repeating. Anything that survives one (a summon, someone mid-invincibility)
## would otherwise drain the spirit's whole 600 in three frames.
const TOUCH_COOLDOWN := 0.5
const LIT_DAMAGE := 20.0               # per think, so 200/s to stand in front of
const LIT_RANGE := 1000.0 * SCALE      # 25 m
const SIGHT_RANGE := 784.0 * SCALE     # 19.6 m
const LIFETIME := 30.0
const THINK_INTERVAL := 0.1
const WANDER_INTERVAL := 0.5
const TURN_RATE := 4.0                 # rad/s the body swings round; it drifts, it does not snap
const RADIUS := 18.0 * SCALE           # GoldSrc hull was 36 units across...
const HEIGHT := 60.0 * SCALE           # ...and 60 tall, centred on the origin rather than the feet
const EYE_HEIGHT := 16.0 * SCALE       # where it aims from, as the original offset its chase vector
const BEAM_ORIGIN := 30.0 * SCALE      # and where the beam leaves it
const MODEL := "models/combo/spiritwiz.mdl"
const ALPHA := 160.0 / 255.0           # renderamt 160
const WAIL_SOUND := "spells/combos/spritwiz_wail.wav"
const BEAM_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const BEAM_WIDTH := 0.025              # beam width 10, in GoldSrc tenths of a unit
const BEAM_NOISE := 1.25               # beam noise 50, likewise
const BEAM_SEGMENTS := 10
const BEAM_FADE := 0.2                 # beam life 2

var owner_node: Node3D
var owner_peer_id := 0  # 0 = nobody's (a /spawn'd spirit); bots own theirs with negative ids
var team: int = GameConsts.Team.NONE
var is_dead: bool:
	get: return _summon.is_dead
var health: float:
	get: return _summon.health
var max_health: float:
	get: return _summon.max_health

## Somewhere to be when there is nobody to fight. A summoned spirit has none and drifts where it
## was cast; a siege sets it to the altar. Same contract as Skeleton.objective. INF = none.
var objective := Vector3.INF

var _summon := SummonBehavior.new()
## Both of spiritwiz.mdl's clips loop and the model says so — nothing to override.
var _rig := ModelRig.new()
## A route for something that flies. It needs no MonsterBody — nothing it does touches the
## ground — but it still cannot see through a wall, and a spirit sent at an altar on the far side
## of a base would otherwise press into the first one it met. The nav answers in the horizontal,
## which is all a drift at a fixed height wants.
var _nav := MonsterNav.new()
var _model: Node3D
var _target: Node3D
var _heading := Vector3.FORWARD
var _age := 0.0
## 0 = forever. A summon is a spell that wears off; a siege attacker is not.
var _lifetime := LIFETIME
var _think_timer := 0.0
var _wander_timer := 0.0
var _beam_timer := 0.0
var _nav_dir := Vector3.ZERO    # the route's answer, refreshed per frame (see _physics_process)
var _own_rids: Array[RID] = []  # body + the model's own hitboxes; see _lit_ray
var _touch_timer := 0.0


func setup(data: Dictionary, is_host := true) -> void:
	owner_peer_id = data.get("owner_peer_id", 0)
	team = data.get("team", GameConsts.Team.NONE)
	_summon.setup(self, data, is_host, MAX_HEALTH, _die)
	_nav.setup(self)
	_lifetime = float(data.get("lifetime", LIFETIME))
	var dir: Vector3 = data.get("direction", Vector3.FORWARD)
	dir.y = 0.0
	if dir.length_squared() > 0.0001:
		_heading = dir.normalized()
	rotation.y = atan2(-_heading.x, -_heading.z)


func _ready() -> void:
	# No yaw correction on the model: both sequences loop and one is always playing, so the
	# imported rest pose never shows and the spirit faces the node's own forward.
	_model = AssetLoader.load_model(MODEL)
	_rig.initialize(self, _model.find_child("AnimationPlayer") if _model else null)
	if _model:
		add_child(_model)
		AssetLoader.set_model_alpha(_model, ALPHA)
		_summon.set_anim_player(_rig.anim_player)  # publishes the played clip via NetInterp:net_anim
		_rig.play("idle")

	# Solid on both peers so the client's predicted player collides with it too; only the
	# authority flies it, so only the authority needs a world mask (mirrors GiantPlant).
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	col.shape = cyl
	add_child(col)  # centred on the origin: the GoldSrc hull was -30..+30, not 0..60
	collision_layer = GameConsts.MASK_ENTITY
	collision_mask = (GameConsts.MASK_WORLD | GameConsts.MASK_CLIP) if _summon.is_host else 0

	SoundSystem.spawn_on(self, WAIL_SOUND, true, 30.0, "Wail")


func _physics_process(delta: float) -> void:
	_summon.tick(delta)
	_rig.tick(delta)

	# The stare is drawn on every peer rather than sent: the beam runs along the spirit's own
	# forward, and its transform and the clip it is playing are already synced, so each peer
	# can work out the same beam for itself and none of it has to ride the wire.
	_beam_timer -= delta
	if _beam_timer <= 0.0:
		_beam_timer = THINK_INTERVAL
		_show_lit_beam()

	if not _summon.is_host:
		return

	# It outlives its caster, so a freed owner must not reach target filtering or damage credit.
	if not is_instance_valid(owner_node):
		owner_node = null

	_age += delta
	if _lifetime > 0.0 and _age >= _lifetime:
		_die()
		return

	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_INTERVAL
		_think()
	# The route's own clocks want frame rate; the think that uses it is a tenth of a second apart.
	if _target == null and objective != Vector3.INF:
		_nav_dir = _nav.desired_dir(delta, objective)

	_face(delta)

	# Checked every frame rather than on the think, so a spirit flying through someone at
	# 2.4 m/s cannot pass clean between two of them.
	_touch_timer -= delta
	move_and_slide()
	_take_a_body()


## One tenth of a second of being a ghost: look for someone in front of it, charge them if there
## is one, and otherwise wander off in a slightly new direction every half second.
func _think() -> void:
	_target = Combat.find_homing_target(self, owner_node, team, SIGHT_RANGE,
			get_rid(), _eye(), _forward())

	if _target == null:
		_rig.play("idle")
		if objective != Vector3.INF:
			_head_for_objective()
			return
		_wander_timer -= THINK_INTERVAL
		if _wander_timer <= 0.0:
			_wander_timer = WANDER_INTERVAL
			# Nudged off its heading rather than pointed somewhere new — the original jittered
			# the velocity it already had, which is what makes one look like it is adrift.
			_heading = (_heading + Vector3(randf_range(-0.75, 0.75), 0.0, randf_range(-0.75, 0.75))).normalized()
		# Along its facing rather than its heading, so a spirit still coming round on a new
		# heading drifts where it is looking instead of sliding sideways into the turn.
		velocity = _forward() * DRIFT_SPEED
		return

	_rig.play("attack")
	var to_target := (SpatialQuery.collision_center(_target) - _eye()).normalized()
	velocity = to_target * SPEED
	# Yaw only — it never tilts, so a target above or below is chased but stared past.
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	if flat.length_squared() > 0.0001:
		_heading = flat.normalized()
	_burn()


## Nobody to chase and somewhere to be: it crosses the map at its full speed rather than its
## drift, because an attacker taking forty seconds over the approach is one nobody ever meets.
## The route when there is one, the straight line when there is not — the same fallback the
## skeleton makes, and the reason it can be sent at an altar it cannot see.
func _head_for_objective() -> void:
	var dir := _nav_dir
	if dir == Vector3.ZERO:
		var flat := objective - global_position
		flat.y = 0.0
		if flat.length_squared() < 0.0001:
			velocity = Vector3.ZERO
			return
		dir = flat.normalized()
	_heading = dir
	# It climbs and sinks to the altar's own height as it comes, so a crystal up a tower is
	# something it arrives level with rather than something it stares past from the floor.
	var rise := clampf(objective.y - global_position.y, -1.0, 1.0)
	velocity = (dir + Vector3.UP * rise).normalized() * SPEED


## The stare's damage half, host-side. A flat ray along the spirit's facing that burns the first
## thing it meets — level, so a victim it is chasing up or down a stairwell is not being burned
## while it closes, only rammed when it arrives.
func _burn() -> void:
	var ray := _lit_ray()
	if ray.result.is_empty():
		return
	Combat.apply_hitscan_damage(ray, LIT_DAMAGE, GameConsts.DamageType.PHYSICAL,
		owner_node if owner_node else self)


## The stare's visible half, drawn on every peer. Only while the attack clip is playing, and only
## when the ray actually reaches a body — the original drew nothing at a bare wall.
func _show_lit_beam() -> void:
	# The mixer, not the rig's clip: this runs on every peer, and a client's copy is showing
	# whatever clip name the snapshot delivered rather than one it chose.
	if not (_rig.anim_player and _rig.anim_player.current_animation == "attack"):
		return
	var ray := _lit_ray()
	if ray.result.is_empty():
		return
	var scene_root := get_tree().current_scene
	if not scene_root:
		return
	BeamSystem.create_oneshot(scene_root, global_position + Vector3(0.0, BEAM_ORIGIN, 0.0),
		ray.impact_pos, {
			"color": BEAM_COLOR,
			"width": BEAM_WIDTH,
			"segments": BEAM_SEGMENTS,
			"noise_fn": _bolt_noise(),
			"fade_time": BEAM_FADE,
		})


## Both halves trace the same line, so they agree about whether there is anything to burn.
## Every RID the spirit owns is excluded, not just its body: the model arrives with 46 hitbox
## Area3Ds of its own, and the beam leaves from inside them — excluding the body alone had it
## burning itself the moment it opened its eyes.
func _lit_ray() -> Dictionary:
	if _own_rids.is_empty():
		_own_rids = Combat.collision_rids(self)
	return Combat.raycast_world(self, global_position + Vector3(0.0, BEAM_ORIGIN, 0.0),
		_forward(), LIT_RANGE, get_rid(),
		GameConsts.MASK_WORLD | GameConsts.MASK_HITBOX | GameConsts.MASK_ENTITY, true, _own_rids)


## Flying into a body is the spirit's other weapon and its clock: 600 to them and 200 out of its
## own 600, so three is the most it can ever take and it usually meets a gun before then.
func _take_a_body() -> void:
	if _summon.is_dead or _touch_timer > 0.0:
		return
	for node in SpatialQuery.nodes_near(&"damageable", _centre(), TOUCH_RANGE):
		if node == self or not is_instance_valid(node):
			continue
		if not (node is Node3D) or not node.is_inside_tree() or node.get("is_dead"):
			continue
		if Teams.summon_spares(team, owner_node, node):
			continue
		if SpatialQuery.collision_center(node).distance_to(_centre()) > TOUCH_RANGE:
			continue
		if node.has_method("take_damage"):
			node.take_damage(TOUCH_DAMAGE, GameConsts.DamageType.PHYSICAL,
				owner_node if owner_node else self)
		_touch_timer = TOUCH_COOLDOWN
		take_damage(TOUCH_COST, GameConsts.DamageType.PHYSICAL, null)
		return  # one body at a time; the next costs it another 200


## Being hurt turns it to face whoever did it — which, for something that only sees and only
## burns what is in front of it, is the same as pointing its stare at them.
func take_damage(amount: float, type: int = GameConsts.DamageType.PHYSICAL, attacker: Node3D = null) -> void:
	if attacker and is_instance_valid(attacker) and _summon.is_host:
		var to_attacker := SpatialQuery.collision_center(attacker) - global_position
		to_attacker.y = 0.0
		if to_attacker.length_squared() > 0.0001:
			_heading = to_attacker.normalized()
			# It no longer turns on the spot, so hold the new heading for a full wander interval:
			# a course nudge landing mid-turn would otherwise undo being shot.
			_wander_timer = WANDER_INTERVAL
	_summon.take_damage(amount, type, attacker)


func _die() -> void:
	var wail := get_node_or_null("Wail")
	if wail:
		wail.stop()
	var pos := _centre()
	_death_effect(pos)
	_summon.die_at(pos)


## Death is a one-shot event, not a property that converges — it would be dropped if it rode
## the synchronizer between two acks.
func _apply_sync_state(state: Dictionary) -> void:
	if "death_pos" in state:
		var wail := get_node_or_null("Wail")
		if wail:
			wail.stop()
		_death_effect(state.death_pos)


func _death_effect(pos: Vector3) -> void:
	var scene_root := get_tree().current_scene
	if scene_root:
		ExplosionEffect.spawn(scene_root, pos, false, ExplosionEffect.DEFAULT_SPR,
			Color(0.7, 0.75, 1.0), ExplosionEffect.DEFAULT_SOUND, 1.5)


## Fixed per-segment jitter, sampled by BeamSystem along the beam.
func _bolt_noise() -> Callable:
	var offsets: Array[Vector3] = []
	offsets.resize(BEAM_SEGMENTS + 1)
	offsets[0] = Vector3.ZERO
	offsets[BEAM_SEGMENTS] = Vector3.ZERO
	for i in range(1, BEAM_SEGMENTS):
		offsets[i] = Vector3(
			randf_range(-BEAM_NOISE, BEAM_NOISE),
			randf_range(-BEAM_NOISE, BEAM_NOISE),
			randf_range(-BEAM_NOISE, BEAM_NOISE))
	return func(t: float) -> Vector3:
		return offsets[clampi(int(t * BEAM_SEGMENTS), 0, BEAM_SEGMENTS)]


## Swings the body round to _heading at TURN_RATE. Facing is what the stare is aimed along, so
## turning takes time: something that steps behind it has a moment before the beam catches up.
func _face(delta: float) -> void:
	var next := rotate_toward(rotation.y, atan2(-_heading.x, -_heading.z), TURN_RATE * delta)
	if absf(angle_difference(rotation.y, next)) > 0.001:
		rotation.y = next


func _forward() -> Vector3:
	return -global_transform.basis.z


func _centre() -> Vector3:
	return global_position


func _eye() -> Vector3:
	return global_position + Vector3(0.0, EYE_HEIGHT, 0.0)


## Animation rides the shared NetInterp slot (see EntityBehavior.set_anim_player), which is also
## how every peer knows whether to draw the stare.
func net_sync_properties() -> PackedStringArray:
	return PackedStringArray(["NetInterp:net_anim"])
