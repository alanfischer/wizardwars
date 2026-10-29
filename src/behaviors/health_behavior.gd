class_name HealthBehavior
extends RefCounted

## Manages health, death, and optional regen. Call initialize() then tick(delta) per physics frame.

var health: float = 100.0
var max_health: float = 100.0
var is_dead: bool = false
var regen_amount: float = 0.0   # HP per regen tick; 0 disables regen
var regen_interval: float = 1.0  # seconds between regen ticks
## How big the blow that landed last was. What it is for is the death that reads it: a dragon
## comes apart over GameConsts.GIB_DAMAGE and leaves a body under it. A kill() that isn't an
## injury CLEARS it — a body that took a hit and was later put down some other way must not
## read that old hit as the one that killed it.
var last_damage: float = 0.0

var _host: Node
var _is_host: bool = false
var _on_death: Callable
var _regen_timer: float = 0.0


func initialize(host: Node, hp: float, is_host: bool = true, on_death: Callable = Callable()) -> void:
	_host = host
	_is_host = is_host
	health = hp
	max_health = hp
	is_dead = false
	last_damage = 0.0
	_regen_timer = 0.0
	_on_death = on_death
	host.add_to_group("damageable")


func take_damage(amount: float, _type: int = 0, attacker: Node3D = null) -> void:
	if not _is_host or is_dead:
		return
	health -= amount
	last_damage = amount
	if attacker:
		NetworkManager.send_hit_confirmed_to(attacker, health <= 0.0)
	if health <= 0.0:
		_kill()


func tick(delta: float) -> void:
	if not _is_host or is_dead or regen_amount <= 0.0:
		return
	_regen_timer -= delta
	if _regen_timer <= 0.0:
		_regen_timer = regen_interval
		if health < max_health:
			health = minf(health + regen_amount, max_health)


## Kill outright, skipping the damage path — for a death that isn't an injury (a summon whose
## time ran out). Same one-shot guard and death callback as taking the last point of damage,
## and no blow behind it: see last_damage.
func kill() -> void:
	if _is_host:
		last_damage = 0.0
		_kill()


func _kill() -> void:
	if is_dead:
		return
	is_dead = true
	_host.remove_from_group("damageable")
	if _on_death.is_valid():
		_on_death.call()
