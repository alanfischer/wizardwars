class_name HolidayProp
extends Node3D
## What a weapon hits of one holiday prop, on the server only: any blow pops it (HolidayGroup.pop).
## Damageable but unhunted, so nothing aims at it, and team NONE, so nobody is its ally.

const SOLID := GameConsts.MASK_HITBOX | GameConsts.MASK_TRAP

var team := GameConsts.Team.NONE
var health := 1.0  # read by the spells that hurt by a share of it (sacrifice)
var is_dead := false
var index := 0
var _group: HolidayGroup
var _body: StaticBody3D


static func make(group: HolidayGroup, prop_idx: int, at: Vector3, radius: float, height: float) -> HolidayProp:
	var prop := HolidayProp.new()
	prop._group = group
	prop.index = prop_idx
	prop.name = "Prop%d" % prop_idx
	prop.position = at
	prop.set_meta(&"_collision_center_local", Vector3(0, height * 0.5, 0))
	# Shootable, not walkable, as the siege altar is: hitscan reads the hitbox layer, a staff swing
	# the trap layer, and movement neither. A body, not an area, since a swing traces bodies only.
	# Under a plain Node3D rather than being one, or the blast sweep's fallback would skip it.
	prop._body = StaticBody3D.new()
	prop._body.collision_layer = SOLID
	prop._body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = radius
	cylinder.height = height
	shape.shape = cylinder
	shape.position = Vector3(0, height * 0.5, 0)
	prop._body.add_child(shape)
	prop.add_child(prop._body)
	prop.add_to_group(&"damageable")
	prop.add_to_group(&"unhunted")
	return prop


func take_damage(_amount: float, _type: int = 0, _attacker: Node3D = null) -> void:
	if not is_dead:
		_group.pop(index)


## Gone (popped) or back: out of every search and every trace while gone.
func set_gone(gone: bool) -> void:
	is_dead = gone
	_body.collision_layer = 0 if gone else SOLID
	if gone:
		remove_from_group(&"damageable")
	else:
		add_to_group(&"damageable")
