extends "res://src/tests/test_base.gd"
## A client's own straight-flying shot is drawn by a ProjectileStandIn on the render timeline until
## the server copy's interp can draw it, so a late create no longer pops the copy in mid-flight.
##
## Scene-run only (needs the NetworkManager autoload): res://src/tests/run_tests.tscn.

const MISSILE := "res://src/projectiles/magic_missile.gd"
const FROM := Vector3(0.0, 500.0, 0.0)  # clear of anything a ray could hit
const DIR := Vector3(1.0, 0.0, 0.0)


func _setup_test(_test_name: String) -> void:
	NetworkManager.test_authority = NetworkManager.TestAuthority.CLIENT
	ProjectileStandIn.note_played(1000)


func _teardown_test() -> void:
	NetworkManager.test_authority = NetworkManager.TestAuthority.REAL
	ProjectileStandIn._lags.clear()
	ProjectileStandIn.note_played(0)
	super()


func _render_time() -> float:
	return NetworkManager.get_estimated_server_time() - NetworkManager.INTERP_DELAY


func _stand_in(seq: int) -> ProjectileStandIn:
	var shooter := _wizard()
	shooter.shot_seq = seq
	return _keep(ProjectileStandIn.spawn(MISSILE, {"position": FROM, "direction": DIR}, shooter)) \
			as ProjectileStandIn


## The server copy as a client builds it, with interp holding its first sample at `first_ms`.
func _copy(seq: int, born_ms: int, first_ms: int) -> Projectile:
	var data := {"position": FROM, "direction": DIR, "born_ms": born_ms, "shot_seq": seq,
		"owner_peer_id": NetworkManager.multiplayer.get_unique_id()}
	var copy: Projectile = load(MISSILE).new()
	copy.setup(data, false)
	var bridge := NetInterpBridge.new()
	bridge.name = "NetInterp"
	bridge.first_ms = first_ms
	bridge.net_stamp = first_ms + 1000
	copy.add_child(bridge)
	_root().add_child(copy)
	return _keep(copy) as Projectile


func test_hidden_until_render_time_reaches_the_spawn() -> void:
	var stand_in := _stand_in(101)
	stand_in._born = _render_time() + 1.0
	stand_in._process(0.0)
	assert_eq(stand_in._visual, null, "the copy would not be drawn yet either")


func test_flies_the_line_on_the_render_timeline() -> void:
	var stand_in := _stand_in(102)
	stand_in._born = _render_time() - 0.1
	stand_in._process(0.0)
	assert_ne(stand_in._visual, null)
	assert_vec3_almost_eq(stand_in._visual.global_position, FROM + DIR * MagicMissile.MISSILE_SPEED * 0.1,
		0.5, "a tenth of a second of flight past the spawn")


## The create lands late, after render time has passed the spawn: the stand-in keeps drawing the
## copy's own line until interp's first sample is due, then the copy takes over where it is.
func test_late_create_hands_over_once_interp_has_it() -> void:
	var stand_in := _stand_in(103)
	var now_ms := int(_render_time() * 1000.0)
	var copy := _copy(103, now_ms - 150, now_ms + 1000)
	await _physics_frame()
	assert_false(copy.visible, "hidden while its interp has nothing for render time")
	stand_in._process(0.0)
	assert_ne(stand_in._visual, null, "the stand-in draws the stretch interp can't")
	assert_almost_eq(stand_in._born, (now_ms - 150) / 1000.0, 0.001, "on the copy's spawn time")
	assert_vec3_almost_eq(stand_in._visual.global_position,
		FROM + DIR * MagicMissile.MISSILE_SPEED * (_render_time() - stand_in._born), 0.5, "on the copy's line")
	assert_eq(ProjectileStandIn._lags.size(), 1, "the copy's spawn time teaches the next shot's")

	copy.get_node("NetInterp").first_ms = now_ms - 150
	var trail: TrailFader = stand_in._visual._trail
	stand_in._process(0.0)
	assert_true(copy.visible, "interp can draw it now")
	assert_eq(copy._trail, trail, "the copy carries on the stand-in's trail")
	await _physics_frame()
	assert_false(is_instance_valid(stand_in), "the stand-in is done")


func test_copy_gone_ends_the_stand_in() -> void:
	var stand_in := _stand_in(104)
	var now_ms := int(_render_time() * 1000.0)
	var copy := _copy(104, now_ms, now_ms + 1000)
	await _physics_frame()
	copy.queue_free()
	await _physics_frame()
	assert_false(is_instance_valid(stand_in), "a copy that hit something takes its stand-in with it")


func test_gives_up_without_a_copy() -> void:
	var stand_in := _stand_in(105)
	stand_in._born = _render_time() - NetworkManager.net_ping_avg_ms / 1000.0 - ProjectileStandIn.GIVE_UP_AFTER - 0.05
	stand_in._process(0.0)
	await _physics_frame()
	assert_false(is_instance_valid(stand_in), "a refused shot's stand-in doesn't fly on")


func test_other_shots_are_not_claimed() -> void:
	var stand_in := _stand_in(106)
	var now_ms := int(_render_time() * 1000.0)
	var copy := _copy(999, now_ms, now_ms)
	assert_true(copy.visible, "a copy no stand-in waits for is drawn as usual")
	assert_eq(stand_in._copy, null)


## The usual case: the create beats render time to the spawn, so nothing is ever drawn in its place.
func test_early_create_hands_over_undrawn() -> void:
	var stand_in := _stand_in(107)
	var now_ms := int(_render_time() * 1000.0)
	stand_in._born = now_ms / 1000.0 + 1.0
	var copy := _copy(107, now_ms + 1000, now_ms + 1000)
	await _physics_frame()
	var trail: TrailFader = copy._trail
	copy.get_node("NetInterp").first_ms = now_ms - 1
	stand_in._process(0.0)
	assert_eq(stand_in._visual, null, "never drawn")
	assert_true(copy.visible)
	assert_eq(copy._trail, trail, "the copy keeps its own trail")


## A shot whose command the server hasn't played yet may be a lost command on its way again, so
## the stand-in waits rather than draw a missile that doesn't exist.
func test_unplayed_shot_is_not_drawn() -> void:
	var stand_in := _stand_in(108)
	stand_in._born = _render_time() - 0.1
	ProjectileStandIn.note_played(107)
	stand_in._process(0.0)
	assert_eq(stand_in._visual, null)
	ProjectileStandIn.note_played(108)
	stand_in._process(0.0)
	assert_ne(stand_in._visual, null, "drawn once the server has played it")


## A guess that ran ahead of the copy's real spawn is pulled back and hidden, not left in the air.
func test_early_guess_hides_once_paired() -> void:
	var stand_in := _stand_in(109)
	stand_in._born = _render_time() - 0.1
	stand_in._process(0.0)
	var now_ms := int(_render_time() * 1000.0)
	_copy(109, now_ms + 500, now_ms + 500)
	stand_in._process(0.0)
	assert_false(stand_in._visual.visible, "render time hasn't reached the real spawn")


## A stalled downlink brings neither the create nor word of the command, and the stretch it hides
## is the one the stand-in is for.
func test_drawn_through_a_silent_server() -> void:
	var stand_in := _stand_in(110)
	stand_in._born = _render_time() - 0.1
	ProjectileStandIn.note_played(109)
	ProjectileStandIn._played_ms -= int(NetworkManager.INTERP_DELAY * 1000.0) + 50
	stand_in._process(0.0)
	assert_ne(stand_in._visual, null)


## A stalled create can land holding only its spawn sample, long behind render time: interp would
## draw the copy back at the hand, so the stand-in keeps the line until a later sample arrives.
func test_no_hand_over_to_a_copy_behind_render_time() -> void:
	var stand_in := _stand_in(111)
	var now_ms := int(_render_time() * 1000.0)
	var copy := _copy(111, now_ms - 200, now_ms - 200)
	copy.get_node("NetInterp").net_stamp = now_ms - 200
	stand_in._process(0.0)
	assert_false(copy.visible, "its interp has nothing at render time yet")
	copy.get_node("NetInterp").net_stamp = now_ms + 100
	stand_in._process(0.0)
	assert_true(copy.visible)
