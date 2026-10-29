class_name SiegeAltar
extends StaticBody3D

## The thing a siege is fought over: a crystal the monsters come to break and the wizards stand
## in front of. One per map, placed by [SiegeSystem], not by anything in the .bsp.
##
## Composed like [FuncBreakable] rather than like a summon — it has no owner and no team-mates,
## only health and a side. It carries the defenders' team so a monster reads it as an enemy
## through the ordinary friend-or-foe path (Teams.summon_spares) and will attack it on
## sight with no special case anywhere, while a defender's own spells pass it by.
##
## Not solid. Player and monster movement both collide against MASK_WORLD_AND_CLIP, so a body
## walks through it — deliberate for now: a 2 m obstruction dropped into a doorway is exactly
## the shape of thing that wedges a walker, and the wedge work is still open.

const GROUP := &"siege_altar"
const MODEL := "models/crystal.mdl"
const DEFAULT_HEALTH := 1500.0
const RADIUS := 1.1
const HEIGHT := 2.2
## Pulse of the light inside it, so the thing you are defending reads at a distance and a glance
## tells you it is still alive.
const PULSE_HZ := 0.6
const LIGHT_RANGE := 14.0
## Air left between the crystal's tip and whatever is over it when the altar has to shrink.
const CEILING_CLEARANCE := 0.2
## A crystal smaller than this is not worth defending, so a room this low keeps a tip through
## its ceiling rather than an ornament on its floor.
const MIN_SCALE := 0.5

var team: int = GameConsts.Team.NONE
var is_dead: bool:
	get: return _health.is_dead
var health: float:
	get: return _health.health
	set(value): _health.health = value      # settable: clients take it off the snapshot
var max_health: float:
	get: return _health.max_health

var _entity := EntityBehavior.new()
var _health := HealthBehavior.new()
var _model: Node3D
var _light: OmniLight3D
var _pulse := 0.0
## Floor-to-ceiling room the host measured at the spot; INF when there is nothing above it.
var _headroom := INF
## What the crystal was shrunk by to fit that. 1.0 on nearly every map.
var _scale := 1.0


static func precache() -> void:
	AssetLoader.precache_model(MODEL)


func setup(data: Dictionary, is_host := true) -> void:
	position = data.get("position", Vector3.ZERO)
	team = int(data.get("team", GameConsts.Team.NONE))
	_headroom = float(data.get("headroom", INF))
	_entity.initialize(self, is_host)
	_health.initialize(self, float(data.get("health", DEFAULT_HEALTH)), is_host, _die)


func _ready() -> void:
	precache()
	# A client runs no siege logic and is never handed this node, but its HUD has to draw the
	# health bar — so the altar announces itself instead.
	add_to_group(GROUP)
	_model = AssetLoader.load_model(MODEL)
	if _model:
		add_child(_model)
		_fit_model()

	# Shootable, not walkable: MASK_HITBOX is what hitscan reads, MASK_ENTITY is what the AoE and
	# homing scans sweep. Neither is in MASK_WORLD_AND_CLIP, which is what movement collides with.
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS * _scale
	cyl.height = HEIGHT * _scale
	col.shape = cyl
	col.position.y = HEIGHT * 0.5 * _scale
	add_child(col)
	collision_layer = GameConsts.MASK_ENTITY | GameConsts.MASK_HITBOX
	collision_mask = 0

	_light = OmniLight3D.new()
	_light.omni_range = LIGHT_RANGE
	_light.light_color = GameConsts.TEAM_COLORS.get(team, Color.WHITE)
	_light.position.y = HEIGHT * 0.6 * _scale
	add_child(_light)


## Stand the crystal on the floor and keep it under the ceiling. Its origin is not its feet —
## the mesh starts 0.4 m above it and reaches 3.1 m — and the rooms a map's objective lives in
## are not all tall enough for that: ww_ravine's grail room is three metres floor to ceiling, and
## the tip came up through the floor of the room above.
func _fit_model() -> void:
	var bounds := _bounds_of(_model)
	if bounds.size.y <= 0.0:
		return
	var room := _headroom - CEILING_CLEARANCE
	if room < bounds.size.y:
		_scale = clampf(room / bounds.size.y, MIN_SCALE, 1.0)
	_model.scale = Vector3.ONE * _scale
	_model.position.y = -bounds.position.y * _scale


## Everything the model draws, in the model's own frame.
func _bounds_of(root: Node3D) -> AABB:
	var out := AABB()
	var inv := root.global_transform.affine_inverse()
	for n in root.find_children("*", "VisualInstance3D", true, false):
		var vis := n as VisualInstance3D
		var box := (inv * vis.global_transform) * vis.get_aabb()
		out = box if out.size == Vector3.ZERO else out.merge(box)
	return out


func _process(delta: float) -> void:
	if _light == null:
		return
	# Dimming as it is worn down: the light is the health bar for anyone not looking at the HUD.
	_pulse += delta * PULSE_HZ * TAU
	var frac := clampf(health / maxf(max_health, 1.0), 0.0, 1.0)
	_light.light_energy = (0.35 + 0.65 * frac) * (0.85 + 0.15 * sin(_pulse))


func _physics_process(delta: float) -> void:
	_health.tick(delta)


func take_damage(amount: float, type: int = GameConsts.DamageType.PHYSICAL, attacker: Node3D = null) -> void:
	_health.take_damage(amount, type, attacker)


func heal(amount: float) -> void:
	if _health.is_dead:
		return
	_health.health = minf(_health.health + amount, _health.max_health)


func _die() -> void:
	_entity.die_at(global_position + Vector3(0.0, HEIGHT * 0.5 * _scale, 0.0))


## Health rides the snapshot rather than a side-channel RPC, so a client's HUD bar comes back with
## a full baseline when the altar re-enters its PVS instead of sitting at whatever it last heard.
func net_sync_properties() -> PackedStringArray:
	return PackedStringArray([":health"])
