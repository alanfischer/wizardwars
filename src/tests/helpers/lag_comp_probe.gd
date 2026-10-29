extends CharacterBody3D
## Minimal stand-in for LagCompensation tests: carries the two things rewind() looks for on a
## damageable node (peer_id + get_hitbox_areas) and the shot stamp it looks for on a shooter.

var peer_id := 0
var lag_comp_shot_time_ms := 0

var _hitboxes: Array[Area3D] = []


func get_hitbox_areas() -> Array[Area3D]:
	return _hitboxes


## Attach one hitbox Area3D at a body-local offset, like a bone-attached box on a wizard model.
func add_hitbox(offset: Vector3, size := Vector3.ONE) -> Area3D:
	var area := Area3D.new()
	area.collision_layer = GameConsts.MASK_HITBOX
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	area.set_meta("hitbox_group", 0)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	area.add_child(cs)
	add_child(area)
	area.position = offset
	_hitboxes.append(area)
	return area
