class_name GiantPlant
extends CharacterBody3D

## Giant plant summon — the Wizard Wars combo spell "weapon_giantplantspell". Grows where
## it's cast, then stalks the nearest enemy it can see and bites; a bite kills outright.
## Unlike the rooted plants it belongs to the world rather than to the wizard who cast it: the
## caster dying, switching class, leaving, or casting another plant takes nothing away from it.
## Casts are wholly independent of one another. Nothing but LIFETIME reclaims one, though —
## without it every plant ever cast would still be stalking at the end of the round.

const SCALE := GameConsts.SCALE_FACTOR
const MAX_HEALTH := 250.0
const HEALTH_REGEN := 20.0
const HEALTH_REGEN_TIME := 5.0
const LIFETIME := 60.0                 # seconds it stalks before withering on its own
const MOVE_SPEED := 100.0 * SCALE      # 2.5 m/s
const SIGHT_RANGE := 782.0 * SCALE     # 19.55 m
const BITE_RANGE := 125.0 * SCALE      # 3.125 m
const BITE_DAMAGE := 600.0             # gibs whatever it lands on, as in the original
const BITE_COOLDOWN := 0.5
const RETARGET_INTERVAL := 0.5
const RADIUS := 50.0 * SCALE           # GoldSrc hull was 100 units across...
const HEIGHT := 90.0 * SCALE           # ...and 90 tall
const STEP_HEIGHT := 18.0 * SCALE      # GoldSrc monster step
const GRAVITY := 20.0                  # 800 sv_units, as MovementConfig.gravity
const MODEL := "models/combo/giantplant.mdl"
const BITE_SOUND := "zombie/claw_strike3.wav"
const IDLE_ANIMS := ["idle1", "idle2", "idle3"]

var owner_node: Node3D
var owner_peer_id := 0  # 0 = nobody's (a /spawn'd plant); bots own theirs with negative ids
var team: int = GameConsts.Team.NONE
var is_dead: bool:
	get: return _summon.is_dead
var health: float:
	get: return _summon.health
var max_health: float:
	get: return _summon.max_health

var _summon := SummonBehavior.new()
## "move" is the only clip allowed to loop: the idles have to end for a fresh one to be drawn,
## which is how the original cycled its three, and giantplant.mdl marks all three as looping.
var _rig := ModelRig.new()
var _model: Node3D
var _target: Node3D
var _retarget_timer := 0.0
var _bite_timer := 0.0
var _biting := false
var _age := 0.0
var _withered := false


func setup(data: Dictionary, is_host := true) -> void:
	owner_peer_id = data.get("owner_peer_id", 0)
	team = data.get("team", GameConsts.Team.NONE)
	_summon.setup(self, data, is_host, MAX_HEALTH, _die)
	_summon.set_regen(HEALTH_REGEN, HEALTH_REGEN_TIME)


func _ready() -> void:
	# No yaw correction on the model: the imported rest pose has the head down +X, but every
	# sequence animates the root back to -Z, and _ready starts one immediately — so the plant
	# faces the node's own forward and each yaw below is an ordinary look-at.
	_model = AssetLoader.load_model(MODEL)
	_rig.initialize(self, _model.find_child("AnimationPlayer") if _model else null,
			ModelRig.Loop.LISTED, PackedStringArray(["move"]))
	if _model:
		add_child(_model)
		add_child(BlobShadow.new(RADIUS))
		_summon.set_anim_player(_rig.anim_player)  # publishes the played clip via NetInterp:net_anim
		_rig.play(IDLE_ANIMS[0])

	# Solid on both peers so the client's predicted player collides with it too; only the
	# authority walks it, so only the authority needs a world mask (mirrors Dragon).
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	col.shape = cyl
	col.position.y = HEIGHT * 0.5
	add_child(col)
	collision_layer = GameConsts.MASK_ENTITY
	collision_mask = (GameConsts.MASK_WORLD | GameConsts.MASK_CLIP) if _summon.is_host else 0
	floor_snap_length = STEP_HEIGHT

	if _summon.is_host:  # play_3d reaches the clients; theirs would be a second, and late, copy
		SoundSystem.play_3d("spells/combos/giantplant_cast.wav", global_position)


func _physics_process(delta: float) -> void:
	_summon.tick(delta)
	_rig.tick(delta)

	if not _summon.is_host:
		return

	_age += delta
	if _age >= LIFETIME:
		# Through the health behavior rather than straight to _die, for its one-shot guard and its
		# "damageable" bookkeeping — a bite landing this same frame must not kill it twice.
		_withered = true
		_summon.kill()
		return

	# The plant outlives its caster, so a freed owner must not reach target filtering or
	# damage credit — both read properties off it. Tested with is_instance_valid alone: a
	# freed Object is already falsy, so `if owner_node and ...` would never catch one.
	if not is_instance_valid(owner_node):
		owner_node = null

	_bite_timer -= delta
	_retarget_timer -= delta
	if _retarget_timer <= 0.0 or not _has_live_target():
		_retarget_timer = RETARGET_INTERVAL
		_target = Combat.find_homing_target(self, owner_node, team, SIGHT_RANGE,
				get_rid(), global_position + Vector3(0.0, HEIGHT * 0.5, 0.0))

	var horizontal := Vector3.ZERO
	if _has_live_target():
		var to_target := _target.global_position - global_position
		to_target.y = 0.0
		if to_target.length_squared() > 0.0001:
			rotation.y = atan2(-to_target.x, -to_target.z)
		if global_position.distance_to(_target.global_position) <= BITE_RANGE:
			_bite(_target)
		elif not _biting:
			horizontal = to_target.normalized() * MOVE_SPEED

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y = maxf(velocity.y - GRAVITY * delta, -GRAVITY)
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	if horizontal != Vector3.ZERO:
		SpatialQuery.step_up(self, horizontal * delta, STEP_HEIGHT)
	move_and_slide()

	_update_anim(horizontal != Vector3.ZERO)


## Walk loops; the idles are one-shots so a fresh one is drawn each time the last runs out,
## which is how the original cycled its three idle sequences.
func _update_anim(moving: bool) -> void:
	if _biting:
		return
	if moving:
		_rig.play("move")
	elif not (_rig.clip in IDLE_ANIMS and not _rig.clip_over()):
		_rig.play(IDLE_ANIMS[randi() % IDLE_ANIMS.size()])


## Re-checked every tick, not just at acquisition: a target that dies, leaves, or turns friendly
## mid-chase has to release the plant, or it keeps chewing on someone it can no longer hurt.
func _has_live_target() -> bool:
	if not is_instance_valid(_target) or not _target.is_inside_tree() or _target.get("is_dead"):
		return false
	return not Teams.summon_spares(team, owner_node, _target)


func _bite(target: Node3D) -> void:
	if _bite_timer > 0.0:
		return
	_bite_timer = BITE_COOLDOWN
	_biting = true
	_rig.play("bite", true)  # restart: the clip runs longer than the bite cooldown
	var anim_player := _rig.anim_player
	if anim_player and not anim_player.animation_finished.is_connected(_on_bite_finished):
		anim_player.animation_finished.connect(_on_bite_finished, CONNECT_ONE_SHOT)
	SoundSystem.play_3d(BITE_SOUND, global_position)
	if target.has_method("take_damage"):
		target.take_damage(BITE_DAMAGE, GameConsts.DamageType.PHYSICAL, owner_node)


func _on_bite_finished(_anim_name: StringName) -> void:
	_biting = false


## Clients drive the model from NetInterp:net_anim, and the bite noise is a broadcast sound.
func _apply_sync_state(state: Dictionary) -> void:
	if "death_pos" in state:
		_death_effect(state.death_pos)


func take_damage(amount: float, type: int = GameConsts.DamageType.PHYSICAL, attacker: Node3D = null) -> void:
	# Allies chip away at a tenth rate, as in the original — an ally can clear a badly
	# placed plant, but can't casually delete a teammate's summon.
	if attacker and Teams.nodes_friendly(attacker, self):
		amount *= 0.1
	_summon.take_damage(amount, type, attacker)


func _die() -> void:
	var pos := global_position
	_death_effect(pos)
	_summon.tell_owner(owner_peer_id, "Your giant plant withered away!" if _withered else "Your giant plant was destroyed!")
	_summon.die_at(pos)  # the original's death TE_EXPLOSION was MSG_BROADCAST


func _death_effect(pos: Vector3) -> void:
	var scene_root := get_tree().current_scene
	if scene_root:
		ExplosionEffect.spawn(scene_root, pos + Vector3(0.0, HEIGHT * 0.9, 0.0), false,
			ExplosionEffect.DEFAULT_SPR, Color(0.35, 0.9, 0.25), ExplosionEffect.DEFAULT_SOUND, 2.0)


## Animation rides the shared NetInterp slot (see EntityBehavior.set_anim_player).
func net_sync_properties() -> PackedStringArray:
	return PackedStringArray(["NetInterp:net_anim"])
