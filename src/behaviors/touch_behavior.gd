class_name TouchBehavior
extends RefCounted

## Ground-pickup plumbing: the touch volume, the host-side overlap poll, GoldSrc's
## DROP_TO_FLOOR settle, and the taken/respawn latch.
##
## A behavior rather than a base class because the pickups don't share one: item_healthkit,
## item_weapon and item_dm_pickup extend EntityBase, while item_tfgoal extends TFGoalBase.
## They also disagree on how a touch is noticed — a box polled every POLL_INTERVAL for the
## three that can be touched while standing still, a sphere on body_entered for the goal item.
##
## Host builds its volume with add_box()/add_sphere() from _ready(), then either calls tick()
## per physics frame (polled) or connects area.body_entered itself (signalled).

## GoldSrc sizes CItem (-16,-16,0)..(16,16,16). Kept that wide, but taller: a 16-unit-high box
## is easy for a running player's capsule to skip past between physics frames, and Area3D has no
## swept touch trace to fall back on.
const DEFAULT_EXTENTS := Vector3(32.0, 48.0, 32.0) * GameConsts.SCALE_FACTOR

## Seconds between host-side overlap checks.
const POLL_INTERVAL := 0.1

## The touch volume, once built. Hosts that toggle monitoring on their own terms read it directly.
var area: Area3D

## False between a taken pickup and its respawn. tick() stops polling while it is down.
var available := true

## Seconds until a taken pickup comes back; 0 leaves it gone (the host frees itself instead).
var respawn_time := 0.0

## GoldSrc settles pickups mappers placed floating. Cleared for anything spawned at a
## deliberate height.
var drops_to_floor := true

var _host: Node3D
var _on_touch: Callable
var _on_respawn: Callable
var _poll_accum := 0.0
var _needs_drop := true


## on_touch is called with each overlapping body until one returns true — the same contract the
## items' _try_give() already had; leave it off for a signalled host, which never calls tick().
## on_respawn fires just before a respawned pickup is shown again, for hosts that re-dress
## themselves on the way back.
func initialize(host: Node3D, on_touch := Callable(), on_respawn := Callable()) -> void:
	_host = host
	_on_touch = on_touch
	_on_respawn = on_respawn


## Box volume standing on the entity origin, like GoldSrc's floor-aligned CItem.
func add_box(extents := DEFAULT_EXTENTS) -> Area3D:
	var box := BoxShape3D.new()
	box.size = extents
	return _add_area(box, Vector3(0, extents.y * 0.5, 0))


## Sphere volume centred on the entity origin.
func add_sphere(radius: float) -> Area3D:
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	return _add_area(sphere, Vector3.ZERO)


func _add_area(shape: Shape3D, offset: Vector3) -> Area3D:
	area = Area3D.new()
	area.name = "TouchArea"
	area.collision_layer = 0
	area.collision_mask = GameConsts.MASK_PLAYER
	area.monitoring = true
	area.monitorable = false
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = offset
	area.add_child(col)
	_host.add_child(area)
	return area


## Per-physics-frame half of a polled pickup: the one-shot floor settle, then the overlap check.
##
## Polled rather than driven by body_entered: a player standing on a pickup they had no room for
## has already "entered" it, so the signal never fires again once they spend the health or mana.
## GoldSrc re-touches every frame; this is the cheap version.
func tick(delta: float) -> void:
	# A host that bailed out of _ready() before building its volume (an unknown weapon key, say)
	# still gets a physics frame or two before queue_free() takes it.
	if area == null:
		return
	# Deferred to the first physics frame, when the world is collidable. Runs on clients too —
	# the settle is a function of map geometry both ends share, and item_weapon carries no
	# transform sync to correct a client copy that stayed where the mapper left it.
	if drops_to_floor and _needs_drop:
		_needs_drop = false
		drop_to_floor()

	if not available or _is_client():
		return
	_poll_accum += delta
	if _poll_accum < POLL_INTERVAL:
		return
	_poll_accum = 0.0
	for body in area.get_overlapping_bodies():
		if _on_touch.call(body):
			return


## Host calls this once a touch is accepted: the pickup goes away, and comes back when
## respawn_time says so.
func take() -> void:
	available = false
	_set_visible(false)
	set_monitoring(false)
	if respawn_time <= 0.0:
		return
	_host.get_tree().create_timer(respawn_time).timeout.connect(_respawn, CONNECT_ONE_SHOT)


func _respawn() -> void:
	if not is_instance_valid(_host) or available:
		return
	available = true
	if _on_respawn.is_valid():
		_on_respawn.call()
	_set_visible(true)
	set_monitoring(true)


func set_monitoring(on: bool) -> void:
	if area:
		area.set_deferred("monitoring", on)


func drop_to_floor() -> void:
	var y := SpatialQuery.ground_y_below(_host, _host.global_position)
	if y != INF:
		_host.global_position.y = y


## Goes through the host so _game_visible stays in step and clients hear about it — see
## EntityBase._set_game_visible_synced.
func _set_visible(on: bool) -> void:
	if _host.has_method("_set_game_visible_synced"):
		_host._set_game_visible_synced(on)


func _is_client() -> bool:
	if _host.has_method("_is_network_client"):
		return _host._is_network_client()
	return not NetworkManager.is_authority()
