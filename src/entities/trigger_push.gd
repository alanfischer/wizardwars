class_name TriggerPush
extends EntityBase
# trigger_push — area that applies velocity to players and loose rigid bodies
# (satchels, cockleburrs, rolling stones) while inside.

const SF_PUSH_ONCE := 1

var _push_dir: Vector3
var _push_speed: float
var _area: Area3D
var _spawnflags: int


func _ready() -> void:
	super()
	_push_speed = parse_float(ent, "speed", 40.0) * GameConsts.SCALE_FACTOR * GameConsts.PUSH_SPEED_SCALE
	_push_dir = parse_movedir(ent)
	_spawnflags = parse_spawnflags(ent)

	_area = GoldSrcEntity.use_volume_as_trigger(self, GameConsts.MASK_FIELD_TRIGGER)


func _physics_process(_delta: float) -> void:
	if not _area:
		return
	# MASK_FIELD_TRIGGER already filters overlaps to bodies this peer owns, so no
	# authority check is needed.
	for body in _area.get_overlapping_bodies():
		if not is_instance_valid(body):
			continue
		var rigid := body as RigidBody3D
		if not rigid and (not body is CharacterBody3D or not body.is_alive):
			continue

		if _spawnflags & SF_PUSH_ONCE:
			if rigid:
				rigid.linear_velocity += _push_dir * _push_speed
			else:
				body.velocity += _push_dir * _push_speed
			queue_free()
			return
		elif rigid:
			_push_rigid(rigid)
		else:
			# Permanently lift body.velocity.y to at least the push's vertical speed (scaled
			# to 1/3 — raw GoldSrc jump-pad speeds overshoot in this engine's physics), giving
			# a lasting launch that survives leaving the zone, matching GoldSrc jump pads.
			var push_y: float = _push_dir.y * _push_speed * (1.0 / 3.0)
			if push_y > body.velocity.y:
				body.velocity.y = push_y
			# Horizontal component: signal via _push_base_vel so simulate_tick applies it
			# as basevelocity — added to body for the physics tick then subtracted back out,
			# so the player's own horizontal velocity is never permanently altered.
			body.set("_push_base_vel", _push_dir * _push_speed)


# Rigid bodies have no basevelocity, and this runs every tick, so the push is a
# velocity floor rather than an accumulating add: raise the body up to the push
# speed along each axis and leave anything faster alone. Vertical gets the same
# 1/3 scale the player path uses.
func _push_rigid(rigid: RigidBody3D) -> void:
	var vel := rigid.linear_velocity
	var push_y := _push_dir.y * _push_speed * (1.0 / 3.0)
	if push_y > vel.y:
		vel.y = push_y
	var horiz := Vector3(_push_dir.x, 0.0, _push_dir.z) * _push_speed
	var speed := horiz.length()
	if speed > 0.01:
		var dir := horiz / speed
		var along := vel.dot(dir)
		if along < speed:
			vel += dir * (speed - along)
	rigid.linear_velocity = vel
