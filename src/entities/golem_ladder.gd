extends Node3D
# Invisible ladder volume for golem legs. Provides get_ladder_normal()
# so the player's ladder detection system recognizes it as climbable.

# The normal must be measured from this shape's world position (the leg's true
# vertical axis), NOT from this wrapper node — the wrapper sits at the leg body's
# origin-brush pivot, which is often offset sideways from the leg's geometric
# centre, and measuring from it makes the player drift around the leg instead of
# climbing straight up.
var _col: CollisionShape3D


func _ready() -> void:
	for area in get_children():
		if area is Area3D:
			for c in area.get_children():
				if c is CollisionShape3D:
					_col = c
					return


func get_ladder_normal(player_pos: Vector3) -> Vector3:
	var axis := _col.global_position if _col else global_position
	var to_player := player_pos - axis
	to_player.y = 0.0
	if to_player.length_squared() < 0.001:
		return Vector3.FORWARD
	return to_player.normalized()
