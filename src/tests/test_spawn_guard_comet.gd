extends "res://src/tests/test_base.gd"
## Spawn guard (trigger_comet / ww_sentrycrystal / monster_turret / monster_miniturret).
##
## Two contracts:
##   - mode comes from the PRESENCE of team_no, so team_no "0" scans for team 0 rather
##     than silently falling through to passive, and a volume-driven guard never starts
##     hunting on its own (ww_pushed ships two trigger_comets with no team_no).
##   - the per-target cooldown table is keyed by instance id and pruned, so it does not
##     accumulate an entry for every intruder the guard ever shot at.

const TriggerCometScript = preload("res://src/entities/trigger_comet.gd")


func _make(keys: Dictionary) -> Node:
	var g := TriggerCometScript.new()
	g.set_meta("entity", keys)
	_root().add_child(g)
	return g


# --- mode selection ---

func test_team_no_selects_scanning_mode() -> void:
	var g := _make({"classname": "ww_sentrycrystal", "team_no": "2"})
	assert_true(g._scanning, "a guard given team_no hunts for itself")
	assert_eq(g._team, 2, "team_no is the team it attacks")
	assert_true(g.is_physics_processing(), "scanning guards tick")
	g.queue_free()


func test_absent_team_no_stays_passive() -> void:
	var g := _make({"classname": "trigger_comet"})
	assert_false(g._scanning, "no team_no means the volume decides, not the guard")
	assert_false(g.is_physics_processing(), "passive guards do not tick at all")
	g.queue_free()


func test_team_no_zero_is_presence_not_truthiness() -> void:
	var g := _make({"classname": "ww_sentrycrystal", "team_no": "0"})
	assert_true(g._scanning, "team_no '0' is still a team_no — presence picks the mode")
	g.queue_free()


# --- cooldown table hygiene ---

func test_freed_target_is_dropped() -> void:
	var g := _make({"classname": "trigger_comet"})
	var target := Node3D.new()
	g._last_fire_time[target.get_instance_id()] = 0.0
	assert_eq(g._last_fire_time.size(), 1, "cooldown recorded for the target")
	target.free()
	g._forget_freed_targets()
	assert_eq(g._last_fire_time.size(), 0, "freed target's cooldown is dropped")
	g.queue_free()


func test_live_target_is_kept() -> void:
	var g := _make({"classname": "trigger_comet"})
	var target := Node3D.new()
	g._last_fire_time[target.get_instance_id()] = 12.5
	g._forget_freed_targets()
	assert_eq(g._last_fire_time.size(), 1, "a target still alive keeps its cooldown")
	target.free()
	g.queue_free()


func test_prune_leaves_cooldown_value_intact() -> void:
	var g := _make({"classname": "trigger_comet"})
	var live := Node3D.new()
	var gone := Node3D.new()
	g._last_fire_time[live.get_instance_id()] = 7.0
	g._last_fire_time[gone.get_instance_id()] = 3.0
	gone.free()
	g._forget_freed_targets()
	assert_eq(g._last_fire_time.get(live.get_instance_id()), 7.0,
		"pruning does not disturb the surviving target's last-fire time")
	live.free()
	g.queue_free()
