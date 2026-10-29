extends "res://src/tests/test_base.gd"
## NetInterpBridge publishes a velocity for the client to extrapolate along. A
## reposition (a cocklebur attaching to its victim) implies a huge one, and the stream
## falls quiet straight after — so the client extrapolated it and stranded the entity
## metres away. Also checks the interval spans skipped frames, not one frame's dt.

const BridgeScript = preload("res://src/net_interp_bridge.gd")
const DT := 1.0 / 60.0


var _parent: Node3D
var _bridge: NetInterpBridge


## Drive publishing by hand so the assertions don't race the authority's per-tick publish.
## _ready already published once; a real move establishes a known baseline.
func _rig() -> void:
	_parent = Node3D.new()
	_root().add_child(_parent)
	_bridge = BridgeScript.new()
	_parent.add_child(_bridge)
	_bridge.set_physics_process(false)
	_parent.global_position = Vector3(0.0, 0.5, 0.0)
	_bridge._publish(DT)


func _move_to(y: float) -> void:
	_parent.global_position = Vector3(0.0, y, 0.0)
	_bridge._publish(DT)


func test_normal_motion_derives_velocity() -> void:
	_rig()
	# 0.1 units in one frame = 6 units/s.
	_move_to(0.6)
	assert_almost_eq(_bridge.net_vel.length(), 6.0, 0.5, "ordinary motion derives its velocity")
	_parent.queue_free()


func test_teleport_carries_no_velocity() -> void:
	_rig()
	# 3 units in one frame implies 180 units/s — a reposition, not travel.
	_move_to(3.5)
	assert_eq(_bridge.net_vel, Vector3.ZERO, "a teleport publishes no velocity to extrapolate")
	assert_almost_eq(_bridge.net_pos.y, 3.5, 0.001, "but the new position is still published")
	_parent.queue_free()


func test_skipped_frames_do_not_inflate_velocity() -> void:
	_rig()
	# Settled: below the movement epsilon, so _publish early-outs and banks the time.
	for i in 3:
		_bridge._publish(DT)
	# Then one real move of 0.1 units — spanning 4 frames, not 1.
	_move_to(0.6)
	assert_almost_eq(_bridge.net_vel.length(), 1.5, 0.2,
		"velocity spans the skipped frames (got %.2f, one-frame maths gives 6.0)"
			% _bridge.net_vel.length())
	_parent.queue_free()


## A mover that STOPS must say so once, or the client extrapolates the last velocity past
## the real stop and freezes there — a dragon landing at 6.5 m/s parked its client copy
## 1.6 m under the floor, unmountable.
func test_coming_to_rest_publishes_zero_velocity() -> void:
	_rig()
	_move_to(0.6)
	assert_true(_bridge.net_vel != Vector3.ZERO, "moving publishes a velocity to extrapolate along")
	# Stop: position stops changing, so the eps gate early-outs from here on.
	_bridge._publish(DT)
	assert_eq(_bridge.net_vel, Vector3.ZERO, "the first still tick clears the velocity")
	assert_almost_eq(_bridge.net_pos.y, 0.6, 0.001, "and keeps the resting position")
	_parent.global_position = Vector3(0.0, 0.9, 0.0)  # a later move must still derive a velocity
	_bridge._publish(DT)
	assert_true(_bridge.net_vel != Vector3.ZERO, "moving again resumes publishing a velocity")
	_parent.queue_free()
