extends CharacterBody3D
## Minimal damageable stand-in for hitscan tests: records what take_damage receives.

var damage_taken := 0.0
var last_damage_type := -1
var last_attacker: Node = null


func take_damage(amount: float, damage_type: int, attacker: Node3D = null) -> void:
	damage_taken += amount
	last_damage_type = damage_type
	last_attacker = attacker
