class_name Skull
extends Projectile

## Homing skull projectile for the death wizard.
## Flies forward; searches for enemies within range; locks on and chases.
## Explodes on contact or timeout for AoE damage.
## Based on WWSkullHunter from the original Wizard Wars (ww_skull.cpp).
##
## A skull leaves the hand as plain bone, carrying no element: it hits for PHYSICAL and leaves
## nothing behind. An ally's spell is what gives it one — see take_damage.

const SPEED := 10.0          # 400 GS * 0.025
const TURN_SPEED := 360.0    # degrees per second — aggressive homing
const SEARCH_RADIUS := 12.5  # 500 GS * 0.025
const LIFE_NO_TARGET := 1.0  # seconds before expiry with no lock
const LIFE_HUNTING := 5.0    # seconds after acquiring target
const DAMAGE := 15.0
const RADIUS := 1.6          # 64 GS * 0.025
const THINK_INTERVAL := 0.1  # target search tick
const PROJECTILE_HP := 25.0
# Same file ww_feudal's breakable names as its gibmodel. The map hardcodes that path, so it is
# the one copy of the asset that has to exist; pointing here rather than at a duplicate under
# models/npc/ keeps a single 19 KB model serving both.
const MODEL := "models/flyingskull.mdl"
const MODEL_YAW := PI
const DROP_SPEED := 0.5        # fraction of flight speed a spent skull carries into its fall

## A skull can be given any damage type that shows — GameConsts.DAMAGE_TYPE_COLORS is that list,
## and the colour it wears for each. A type that isn't there (a rock, a staff) has nothing to hand
## over, so it leaves the skull plain.
const PLAIN_COLOR := Color(0.6, 0.2, 0.9)  # the necromancer's own purple, worn until something re-elements it
const GLOW_STRENGTH := 0.6

## What this skull hits for, and the one thing about it an ally can change. Replicated on the
## snapshot rather than by an RPC so it can't arrive before the skull it describes, and so a
## client that only sees the skull halfway through its flight still sees it lit correctly.
var damage_type := GameConsts.DamageType.PHYSICAL:
	set(value):
		if damage_type == value:
			return
		damage_type = value
		_dress()

var _health := HealthBehavior.new()
var _homing := HomingBehavior.new()
var _lifetime := LIFE_NO_TARGET
var _exploded := false
var _model: Node3D


func setup(data: Dictionary, is_host := true) -> void:
	speed = SPEED
	super(data, is_host)
	_health.initialize(self, PROJECTILE_HP, is_host, _explode)
	add_to_group("unhunted")  # shot down, never aimed at — Combat.find_homing_target
	_homing.initialize(self, team, _on_target_acquired)
	_homing.search_radius = SEARCH_RADIUS
	_homing.turn_speed = TURN_SPEED
	_homing.think_interval = THINK_INTERVAL
	contact_radius = 0.8


func _ready() -> void:
	_scene_root = get_tree().current_scene

	_orient_to_direction()

	_model = AssetLoader.load_model(MODEL)
	if _model:
		_model.rotation.y = MODEL_YAW
		add_child(_model)

	_create_light(PLAIN_COLOR)
	_create_trail([], 0.15, 0.4)
	_dress()

	_create_ambient_sound("spells/flyingskull.wav")

	if _is_host:
		_register_entity({
			"script_path": "res://src/projectiles/skull.gd",
			"position": position,
			"direction": direction,
			"team": team,
		})


func _update_visuals(_delta: float) -> void:
	_orient_to_direction()
	_feed_trail()


func _host_physics(delta: float) -> void:
	_age += delta
	if _age >= _lifetime:
		_drop(Vector3.ZERO)  # never found anyone: it runs out of flight, it doesn't go off
		return
	direction = _homing.steer(direction, delta)
	_sweep_and_advance(delta)


## A wall is not a target, so the skull doesn't spend its blast on one: it falls out of the air
## and tumbles to the ground instead.
func _on_world_hit(result: Dictionary) -> void:
	_drop(result.get("normal", Vector3.UP))


func _on_actor_hit(_victim) -> void:
	_explode()


func _on_target_acquired() -> void:
	_lifetime = _age + LIFE_HUNTING  # extend lifetime on lock


## A skull carries whatever damage it last survived, and who dealt it decides only whether it is
## hurt by it. So a flamelick makes a fire skull, a freeze ray an ice one, a necromancer's satchel
## a poisoned one — and so does flying through a trigger_hurt that burns, which nobody casts at
## all. Damage with no element to hand over (a rock, a crusher) leaves the skull dressed as it was.
##
## Its own side is the exception to the hurting: a teammate can re-dress your skull but never
## shoot it down. Everything else — an enemy, the map — takes its 25 HP off as before.
func take_damage(amount: float, type: int = 0, attacker: Node3D = null) -> void:
	if _exploded:
		return
	if GameConsts.DAMAGE_TYPE_COLORS.has(type):
		damage_type = type as GameConsts.DamageType
	if _cast_by_ally(attacker):
		return
	_health.take_damage(amount, type, attacker)


## True when `node` is the wizard who cast this skull, or fights alongside them. summon_spares
## answers both halves — teams where there are teams, the caster's own ownership where there are
## none — and is_same_player covers the host's two bodies for one player in that teamless case.
func _cast_by_ally(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if Teams.summon_spares(team, owner_node, node):
		return true
	return Teams.is_same_player(owner_node, node)


## Light, trail and glow shell, all from the one colour the current damage type is worth. A plain
## skull wears no shell at all — strength 0 hands the model back its shared material.
func _dress() -> void:
	var color: Color = GameConsts.DAMAGE_TYPE_COLORS.get(damage_type, PLAIN_COLOR)
	if _light:
		_light.light_color = color
	if is_instance_valid(_trail):
		_trail.color_palette = [
			Color(color.r, color.g, color.b, 1.0),
			Color(color.r * 0.6, color.g * 0.6, color.b * 0.6, 0.8),
			Color(color.r * 0.3, color.g * 0.3, color.b * 0.3, 0.5),
			Color(color.r * 0.1, color.g * 0.1, color.b * 0.1, 0.0),
		]
	if _model:
		AssetLoader.set_model_glow(_model, color,
			GLOW_STRENGTH if GameConsts.DAMAGE_TYPE_COLORS.has(damage_type) else 0.0)


func net_sync_properties() -> PackedStringArray:
	return PackedStringArray([":damage_type"])


func _explode() -> void:
	if _exploded:
		return
	_exploded = true

	# Registered online (like the satchel's): _explode runs on the host alone, so every other
	# peer needs the replicated effect — and a skull that drops instead has nothing to replicate.
	if is_instance_valid(_scene_root):
		var flash: Color = GameConsts.DAMAGE_TYPE_COLORS.get(damage_type, ExplosionEffect.DEFAULT_LIGHT)
		ExplosionEffect.spawn(_scene_root, global_position, NetworkManager.is_online(),
			ExplosionEffect.DEFAULT_SPR, flash)

	if _is_host:
		Combat.apply_aoe_damage(
			get_world_3d().direct_space_state,
			global_position, DAMAGE, RADIUS, {},
			damage_type, owner_node
		)

	_die()


## Swap the skull for a spent body that falls where it stopped. `normal` is the surface it
## struck, or zero when it simply ran out of life mid-air and keeps drifting forward.
func _drop(normal: Vector3) -> void:
	if _exploded:
		return
	_exploded = true  # the same latch _explode sets: this skull has spent itself, one way or the other
	if normal.length_squared() > 0.001:
		TumblingCorpse.spawn_deflected(MODEL, global_position, direction, SPEED, normal, MODEL_YAW)
	else:
		TumblingCorpse.spawn(MODEL, global_position, direction * SPEED * DROP_SPEED, MODEL_YAW)
	_perform_die()


func _exit_tree() -> void:
	_stop_trail()
