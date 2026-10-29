class_name BallLightningWeapon
extends Weapon

## Ball lightning spell — a hitscan bolt for 500 that leaves a homing ball of lightning standing
## in the crater. Two spells in one: the bolt is instant and unavoidable, and whoever it hit is
## then the ball's first candidate.
##
## The spellbook holds one cast. It costs no mana and spends itself instead: a successful cast
## takes the spell back out of the loadout, so another one means finding another book.

const SCALE := GameConsts.SCALE_FACTOR
const RANGE := 8192.0 * SCALE          # 204.8 m — effectively the whole map
const DAMAGE := 500.0
const BALL_OFFSET := 0.3               # off the surface, so the ball can see past what it hit
const SHAKE_AMPLITUDE := 120.0         # GoldSrc units, as NetworkManager.send_screen_shake wants
const SHAKE_RADIUS := 1000.0 * SCALE   # 25 m
const SHAKE_DURATION := 2.0
## The original asked for 1000 shakes/sec, which in GoldSrc drives a sine sampled once a frame.
## Here the frequency is the number of tween steps, so 1000 would build a 2000-step tween for
## one cast. 40 is as fast as the rattle can actually read.
const SHAKE_FREQUENCY := 40.0
const COOLDOWN := 2.0
const CAST_SOUND := "spells/combos/ball_lightning.wav"


func _init() -> void:
	cooldown = COOLDOWN
	# No mana: the book itself is the cost, and it's gone after one cast (see fire).


func precache() -> void:
	AssetLoader.precache_sprite(BallLightning.SPRITE)
	AssetLoader.precache_sprite(BallLightningStrike.BURST_SPRITE)
	AssetLoader.get_beam_material()
	AssetLoader.get_spark_particle_material("lightning")
	SoundSystem.precache(CAST_SOUND)


func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, CAST_SOUND, false, 30.0)


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if not NetworkManager.is_authoritative_fire(attacker):
		_fire_tail(attacker)  # client plays the cast; the host owns the bolt and the ball
		return true

	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var excludes := Combat.collect_hitscan_excludes(attacker)
	var ray := Combat.hitscan(attacker, aim.from, aim.aim_dir, RANGE, RID(),
			GameConsts.MASK_HITSCAN, true, excludes)

	_spend(attacker)

	Combat.apply_hitscan_damage(ray, DAMAGE, GameConsts.DamageType.LIGHTNING, attacker)

	var impact: Vector3 = ray.impact_pos
	BallLightningStrike.summon(impact)
	NetworkManager.send_screen_shake(impact, SHAKE_AMPLITUDE, SHAKE_RADIUS, SHAKE_DURATION, SHAKE_FREQUENCY)

	NetworkManager.spawn_projectile("res://src/projectiles/ball_lightning.gd", {
		"position": _ball_spot(ray, aim.aim_dir),
		"direction": aim.aim_dir,
		"team": int(attacker.get("team")),
	}, attacker)

	_fire_tail(attacker)
	return true


## Where the ball is left standing: lifted off whatever the bolt landed on. It dies the instant
## it can't see anyone, so one sitting flush against a wall would spend its first think looking
## into that wall. A bolt that hit nothing has no surface to back off from.
func _ball_spot(ray: Dictionary, aim_dir: Vector3) -> Vector3:
	var normal: Vector3 = ray.impact_norm
	if normal.length_squared() < 0.001:
		normal = -aim_dir
	return ray.impact_pos + normal * BALL_OFFSET


## Take the spell back out of the caster's loadout — one book, one ball. Deferred because the
## server is mid-fire: it still has to stamp last_fired_weapon_idx and broadcast the shot by slot
## index, and dropping a slot now would renumber the loadout under both.
func _spend(attacker: Node3D) -> void:
	if attacker.has_method("revoke_weapon"):
		attacker.call_deferred(&"revoke_weapon", SpawnRegistry.name_for(get_script()))


func cleanup(_attacker: Node3D) -> void:
	pass  # nothing to tear down: the ball is the world's once cast, not the loadout's
