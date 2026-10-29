class_name ProjectileStandIn
extends Node

## The shooter's own straight-flying shot, drawn on the render timeline until its server copy can
## be. A create that lands after render time has passed the copy's spawn shows the copy already
## mid-flight; the stand-in covers that stretch. It appears when the copy would (at a spawn time
## learned from earlier shots), moves onto the copy's own spawn once the create lands, and hands
## over once the copy's interp holds a sample at render time. Visual only: it hits nothing.

## How long past its spawn a stand-in waits for a copy (a shot the server refused) beyond one RTT.
const GIVE_UP_AFTER := 0.25
const _LAG_SAMPLES := 9

static var _waiting := {}  # shot seq -> ProjectileStandIn, until its copy's create lands
## Copy spawn minus the shooter's clock estimate at the shot, for recent shots: the uplink plus
## the server's command queue, in seconds.
static var _lags: Array[float] = []
## The newest command the server has played for this peer, from its own state stream, and when
## it came. A shot whose command it hasn't played may not exist yet (a lost command, resent).
static var _played_seq := 0
static var _played_ms := 0

var _seq := 0
var _script_path := ""
var _data := {}
## Built the first time it is drawn; most shots hand over before that.
var _visual: Projectile
var _copy: Projectile
var _bridge: NetInterpBridge
var _fired_at := 0.0
var _born := 0.0
var _from := Vector3.ZERO
var _dir := Vector3.FORWARD


## The host draws the real projectile at once; only an online client's own shots need one.
static func wanted(shooter: Node3D) -> bool:
	return shooter is LocalPlayer and shooter.shot_seq != 0 and not NetworkManager.is_authority()


static func spawn(script_path: String, data: Dictionary, shooter: Player) -> ProjectileStandIn:
	var stand_in := ProjectileStandIn.new()
	stand_in._seq = shooter.shot_seq
	stand_in._script_path = script_path
	stand_in._data = data
	stand_in._fired_at = NetworkManager.get_estimated_server_time()
	stand_in._born = stand_in._fired_at + _lag()
	stand_in._from = data.get("position", Vector3.ZERO)
	stand_in._dir = data.get("direction", Vector3.FORWARD).normalized()
	_waiting[stand_in._seq] = stand_in
	(Engine.get_main_loop() as SceneTree).current_scene.add_child(stand_in)
	return stand_in


## A client's projectile, from its create: if it is one of this peer's shots, its stand-in takes it.
static func claim(copy: Projectile, data: Dictionary) -> void:
	if _waiting.is_empty() or data.get("owner_peer_id") != NetworkManager.multiplayer.get_unique_id():
		return
	var stand_in: ProjectileStandIn = _waiting.get(data.get("shot_seq", 0))
	if stand_in == null:
		return
	_waiting.erase(stand_in._seq)
	stand_in._pair(copy, data)


## LocalPlayer: a state from the server, for the command `seq`.
static func note_played(seq: int) -> void:
	_played_seq = seq
	_played_ms = Time.get_ticks_msec()


## Whether the server has played the shot's command. A server gone quiet says nothing either way,
## and everything else on screen is extrapolating through the silence, so the stand-in flies too.
static func _played(seq: int) -> bool:
	return seq <= _played_seq or Time.get_ticks_msec() - _played_ms > NetworkManager.INTERP_DELAY * 1000.0


static func _lag() -> float:
	if _lags.is_empty():
		return NetworkManager.net_ping_avg_ms / 2000.0
	var sorted := _lags.duplicate()
	sorted.sort()
	@warning_ignore("integer_division")
	return sorted[sorted.size() / 2]


func _pair(copy: Projectile, data: Dictionary) -> void:
	_copy = copy
	_born = data.get("born_ms", 0) / 1000.0
	_lags.append(_born - _fired_at)
	if _lags.size() > _LAG_SAMPLES:
		_lags.pop_front()
	_from = data.get("position", _from)
	_dir = copy.direction
	if _visual:
		_visual.direction = _dir
		_visual._orient_to_direction()
	copy.visible = false
	copy.tree_exiting.connect(queue_free)


func _process(_delta: float) -> void:
	var render_time := NetworkManager.get_estimated_server_time() - NetworkManager.INTERP_DELAY
	if _copy != null and _copy_drawn(render_time):
		_hand_over()
		return
	var t := render_time - _born
	if _copy == null and t > NetworkManager.net_ping_avg_ms / 1000.0 + GIVE_UP_AFTER:
		queue_free()
		return
	if t < 0.0 or (_copy == null and not _played(_seq)):
		if _visual:
			_visual.visible = false
		return
	var from := _visual.global_position if _visual else _from
	if _visual == null:
		_build_visual()
	var pos := _from + _dir * _visual.speed * t
	var params := PhysicsRayQueryParameters3D.create(from, pos, GameConsts.MASK_WORLD)
	if not _visual.get_world_3d().direct_space_state.intersect_ray(params).is_empty():
		queue_free()
		return
	_visual.global_position = pos
	_visual.visible = true


func _build_visual() -> void:
	_visual = load(_script_path).new()
	_visual.setup(_data, false)
	_visual.remove_from_group("projectile")
	_visual.direction = _dir
	_visual.position = _from
	get_parent().add_child(_visual)


## The copy's interp brackets render time. Before its first sample it would hold the copy where
## it is not yet; past its last it holds or guesses, while the stand-in knows the line.
func _copy_drawn(render_time: float) -> bool:
	if _bridge == null:
		_bridge = _copy.get_node_or_null(^"NetInterp") as NetInterpBridge
	var ms := render_time * 1000.0
	return _bridge != null and _bridge.first_ms > 0 and ms >= _bridge.first_ms and ms <= _bridge.net_stamp


## The copy shows where the stand-in was. A drawn stand-in's trail carries on, in place of the
## copy's own, which only ever held its hidden spawn point.
func _hand_over() -> void:
	_copy.visible = true
	if _visual and is_instance_valid(_visual._trail):
		if is_instance_valid(_copy._trail):
			_copy._trail.queue_free()
		_copy._trail = _visual._trail
		_visual._trail = null
	queue_free()


func _exit_tree() -> void:
	if _waiting.get(_seq) == self:
		_waiting.erase(_seq)
	if is_instance_valid(_visual):
		_visual.queue_free()
