extends "res://src/tests/test_base.gd"
## Tests for StatusLogic. Each test gets a fresh instance — no reset(), no global state.

const Movement = preload("res://addons/pmove/movement.gd")

var _logic: StatusLogic


class FakeTarget:
	extends Node3D
	var health: float = 100.0
	var is_dead: bool = false
	var peer_id: int = 0
	var team: int = 0
	var damage_taken: float = 0.0
	var shown_statuses: Array = []
	var hidden_statuses: Array = []

	func take_damage(amount: float, _type: int, _attacker) -> void:
		health = maxf(health - amount, 0.0)
		damage_taken += amount

	func show_status(type: int) -> void:
		shown_statuses.append(type)

	func hide_status(type: int) -> void:
		hidden_statuses.append(type)


func _setup_test(_test_name: String) -> void:
	_logic = StatusLogic.new()


func _make_target(hp: float = 100.0) -> FakeTarget:
	var t := FakeTarget.new()
	t.health = hp
	return t


func test_apply_poison_marks_poisoned() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	assert_true(_logic.has_status(t, GameConsts.StatusType.POISON), "should be poisoned")


func test_apply_burn_marks_burning() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.BURNING)
	assert_true(_logic.has_status(t, GameConsts.StatusType.BURNING), "should be burning")


func test_apply_status_idempotent_show() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	assert_eq(t.shown_statuses.count(GameConsts.StatusType.POISON), 1,
		"show_status must only fire once for duplicate apply")


func test_has_status_fresh_target_returns_false() -> void:
	var t := _make_target()
	assert_false(_logic.has_status(t, GameConsts.StatusType.POISON), "fresh: no poison")
	assert_false(_logic.has_status(t, GameConsts.StatusType.BURNING), "fresh: no burn")
	assert_false(_logic.has_status(t, GameConsts.StatusType.FROSTED), "fresh: no frost")


func test_apply_frost_marks_frosted() -> void:
	var t := _make_target()
	_logic.apply_frost(t, 1.0)
	assert_true(_logic.has_status(t, GameConsts.StatusType.FROSTED), "should be frosted")


func test_apply_frost_stacks_duration() -> void:
	var t := _make_target()
	_logic.apply_frost(t, 1.0)
	_logic.apply_frost(t, 1.0)
	_logic.tick(1.5, true)
	assert_true(_logic.has_status(t, GameConsts.StatusType.FROSTED),
		"stacked 2s frost should survive 1.5s tick")


func test_apply_frost_caps_at_max() -> void:
	var t := _make_target()
	for _i in range(10):
		_logic.apply_frost(t, StatusLogic.FROST_DURATION)
	_logic.tick(StatusLogic.MAX_FROST_DURATION + 0.1, true)
	assert_false(_logic.has_status(t, GameConsts.StatusType.FROSTED),
		"frost must cap at MAX_FROST_DURATION")


func test_friction_mult_when_frosted() -> void:
	var t := _make_target()
	_logic.apply_frost(t, 2.0)
	assert_almost_eq(_logic.get_friction_multiplier(t), StatusLogic.FROST_FRICTION_MULT,
		0.001, "frosted → FROST_FRICTION_MULT")


func test_friction_mult_when_not_frosted() -> void:
	var t := _make_target()
	assert_almost_eq(_logic.get_friction_multiplier(t), 1.0, 0.001, "no frost → 1.0")


func test_clear_poison() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	_logic.clear_status(t, GameConsts.StatusType.POISON)
	assert_false(_logic.has_status(t, GameConsts.StatusType.POISON), "poison cleared")


func test_clear_burn() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.BURNING)
	_logic.clear_status(t, GameConsts.StatusType.BURNING)
	assert_false(_logic.has_status(t, GameConsts.StatusType.BURNING), "burn cleared")


func test_clear_frost() -> void:
	var t := _make_target()
	_logic.apply_frost(t, 2.0)
	_logic.clear_status(t, GameConsts.StatusType.FROSTED)
	assert_false(_logic.has_status(t, GameConsts.StatusType.FROSTED), "frost cleared")
	assert_almost_eq(_logic.get_friction_multiplier(t), 1.0, 0.001,
		"friction back to 1.0 after frost cleared")


func test_clear_status_noop_on_missing_target() -> void:
	var t := _make_target()
	_logic.clear_status(t, GameConsts.StatusType.POISON)
	assert_true(true, "clear on untracked target must not crash")


func test_clear_all_removes_all_statuses() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	_logic.apply_status(t, GameConsts.StatusType.BURNING)
	_logic.apply_frost(t, 2.0)
	_logic.clear_all(t)
	assert_false(_logic.has_status(t, GameConsts.StatusType.POISON), "poison cleared")
	assert_false(_logic.has_status(t, GameConsts.StatusType.BURNING), "burn cleared")
	assert_false(_logic.has_status(t, GameConsts.StatusType.FROSTED), "frost cleared")


func test_clear_all_no_status_no_crash() -> void:
	var t := _make_target()
	_logic.clear_all(t)
	assert_true(true, "clear_all on clean target must not crash")


func test_tick_decays_burn_timer() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.BURNING)
	_logic.tick(1.0, true)
	assert_true(_logic.has_status(t, GameConsts.StatusType.BURNING),
		"burn still active after 1s of 5s duration")


func test_tick_burn_expired_clears_status() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.BURNING)
	_logic.tick(StatusLogic.BURN_DURATION + 0.1, true)
	assert_false(_logic.has_status(t, GameConsts.StatusType.BURNING),
		"burn should expire after full duration")


func test_tick_burn_dot_fires_at_interval() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.BURNING)
	_logic.tick(StatusLogic.DOT_INTERVAL + 0.01, true)
	assert_gt(t.damage_taken, 0.0, "burn DoT should have fired once")


func test_tick_burn_dot_damage_amount() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.BURNING)
	_logic.tick(StatusLogic.DOT_INTERVAL + 0.01, true)
	var expected := StatusLogic.BURN_DPS * StatusLogic.DOT_INTERVAL
	assert_almost_eq(t.damage_taken, expected, 0.001, "burn DoT = BURN_DPS * DOT_INTERVAL")


func test_tick_burn_accumulates_partial_intervals() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.BURNING)
	_logic.tick(StatusLogic.DOT_INTERVAL * 0.4, true)
	_logic.tick(StatusLogic.DOT_INTERVAL * 0.4, true)
	assert_almost_eq(t.damage_taken, 0.0, 0.001,
		"two partial ticks below interval must not fire DoT yet")
	_logic.tick(StatusLogic.DOT_INTERVAL * 0.4, true)
	assert_gt(t.damage_taken, 0.0, "third partial tick crosses interval — DoT fires")


func test_tick_poison_applies_dot() -> void:
	var t := _make_target(100.0)
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	_logic.tick(StatusLogic.DOT_INTERVAL + 0.01, true)
	assert_gt(t.damage_taken, 0.0, "poison DoT should have fired")


func test_tick_poison_stops_at_1hp() -> void:
	var t := _make_target(1.0 + StatusLogic.POISON_DPS * StatusLogic.DOT_INTERVAL)
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	_logic.tick(StatusLogic.DOT_INTERVAL + 0.01, true)
	assert_almost_eq(t.health, 1.0, 0.001, "poison should stop at 1 HP")
	assert_false(_logic.has_status(t, GameConsts.StatusType.POISON),
		"poison should self-clear after hitting 1 HP floor")


func test_tick_poison_clears_when_already_at_1hp() -> void:
	var t := _make_target(1.0)
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	_logic.tick(StatusLogic.DOT_INTERVAL + 0.01, true)
	assert_almost_eq(t.health, 1.0, 0.001, "health unchanged at 1 HP")
	assert_false(_logic.has_status(t, GameConsts.StatusType.POISON),
		"poison clears when target is already at 1 HP")


func test_tick_poison_never_kills() -> void:
	var t := _make_target(2.0)
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	for _i in range(20):
		_logic.tick(StatusLogic.DOT_INTERVAL + 0.01, true)
	assert_gt(t.health, 0.0, "poison must never kill")


func test_tick_frost_decays() -> void:
	var t := _make_target()
	_logic.apply_frost(t, 2.0)
	_logic.tick(1.0, true)
	assert_true(_logic.has_status(t, GameConsts.StatusType.FROSTED),
		"2s frost should survive a 1s tick")


func test_tick_frost_clears_when_expired() -> void:
	var t := _make_target()
	_logic.apply_frost(t, 0.5)
	_logic.tick(0.6, true)
	assert_false(_logic.has_status(t, GameConsts.StatusType.FROSTED),
		"0.5s frost should expire after 0.6s tick")


func test_tick_removes_dead_target() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	t.is_dead = true
	_logic.tick(0.1, true)
	var fresh := _make_target()
	assert_false(_logic.has_status(fresh, GameConsts.StatusType.POISON),
		"dead target state removed on tick")


func test_tick_removes_freed_target() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	t.free()
	_logic.tick(0.1, true)
	assert_true(true, "tick with freed target node must not crash")


func test_modifiers_frosted_reduces_scales() -> void:
	var t := _make_target()
	_logic.apply_frost(t, 2.0)
	var mods := Movement.MovementModifiers.new()
	_logic.contribute_movement_modifiers(t, mods)
	assert_almost_eq(mods.friction_scale, StatusLogic.FROST_FRICTION_MULT, 0.001,
		"frost reduces friction_scale")
	assert_almost_eq(mods.accel_scale, StatusLogic.FROST_FRICTION_MULT, 0.001,
		"frost reduces accel_scale")


func test_modifiers_not_frosted_scales_are_one() -> void:
	var t := _make_target()
	var mods := Movement.MovementModifiers.new()
	_logic.contribute_movement_modifiers(t, mods)
	assert_almost_eq(mods.friction_scale, 1.0, 0.001, "no frost → friction_scale = 1.0")
	assert_almost_eq(mods.accel_scale, 1.0, 0.001, "no frost → accel_scale = 1.0")


func test_apply_calls_show_status() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.BURNING)
	assert_true(t.shown_statuses.has(GameConsts.StatusType.BURNING),
		"apply should call show_status on target")


func test_clear_calls_hide_status() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.BURNING)
	_logic.clear_status(t, GameConsts.StatusType.BURNING)
	assert_true(t.hidden_statuses.has(GameConsts.StatusType.BURNING),
		"clear should call hide_status on target")


func test_apply_frost_calls_show_status_once() -> void:
	var t := _make_target()
	_logic.apply_frost(t, 1.0)
	_logic.apply_frost(t, 1.0)
	assert_eq(t.shown_statuses.count(GameConsts.StatusType.FROSTED), 1,
		"show_status for frost fires only on first application")


func test_tick_burn_expire_returns_sync_event() -> void:
	var t := _make_target()
	_logic.apply_status(t, GameConsts.StatusType.BURNING)
	var events := _logic.tick(StatusLogic.BURN_DURATION + 0.1, true)
	var found := false
	for ev in events:
		if ev.get("status") == GameConsts.StatusType.BURNING and ev.get("active") == false:
			found = true
	assert_true(found, "burn expiry should produce a sync event")


func test_tick_frost_expire_returns_sync_event() -> void:
	var t := _make_target()
	_logic.apply_frost(t, 0.5)
	var events := _logic.tick(0.6, true)
	var found := false
	for ev in events:
		if ev.has("frost_clear"):
			found = true
	assert_true(found, "frost expiry should produce a frost_clear sync event")


func test_tick_poison_clear_returns_sync_event() -> void:
	var t := _make_target(1.0)
	_logic.apply_status(t, GameConsts.StatusType.POISON)
	var events := _logic.tick(StatusLogic.DOT_INTERVAL + 0.01, true)
	var found := false
	for ev in events:
		if ev.get("status") == GameConsts.StatusType.POISON and ev.get("active") == false:
			found = true
	assert_true(found, "poison self-clear should produce a sync event")
