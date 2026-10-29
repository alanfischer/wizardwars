extends "res://src/tests/test_base.gd"
## A base's team door must let the right things through, and a siege changes what those are.
##
## `team_no` says whose base an entity guards, and the original answers it in one place for a
## door, a button and a trigger alike: CBaseToggle::UTIL_IsMasterTriggered, whose team line is
## the bare `pev->team != pActivator->pev->team`. An alliance never opens anything there — the
## original reads g_iTeamAllies for friendly fire and nothing else. So `==` is the rule here too,
## and the one body that gets past it is ours: a monster the map never contemplated, marked
## META_IGNORES_TEAM_DOORS. It is on MONSTER_TEAM, which no map keys a door to, so the mark is
## the bypass rather than any team or alliance of its own.
##
## Found by play, not by this suite: a wave walked to the first team door on the map and stopped
## there, because every siege monster is on GameConsts.Team.GREEN and sits on MASK_ENTITY — so no
## door could see it, and no door would have opened if it had. And ww_hunt, which allies the
## Hunted with his bodyguards, had every bodyguard who crossed a location volume announcing "The
## Hunted is in the Inn!" to the rest of them, because the alliance was answering the team key.
##
## COVERAGE, measured by reverting each piece: dropping the mark fails a_monster_is_not_kept_out
## and a_monster_works_a_door_trigger; restoring MASK_PLAYER on the volumes fails
## the_touch_volume_watches_monsters and a_monster_works_a_door_trigger; letting an alliance
## answer a team key fails an_ally_is_kept_out and an_ally_does_not_fire_a_trigger.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const TriggerMultipleScript = preload("res://src/entities/trigger_multiple.gd")


class CountingTarget extends Node:
	var fires := 0

	func trigger(_activator: Node, _type) -> void:
		fires += 1


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()
	GoalSystem.team_allies = [0, 0, 0, 0]


## An alliance, as ww_hunt and ww_volcano declare one and as a siege sets one up between the
## defending wizards. It answers friend or foe, and no team key anywhere.
func _ally_red_and_blue() -> void:
	GoalSystem.team_allies[GameConsts.Team.RED - 1] = 1 << (GameConsts.Team.BLUE - 1)


## A blue-only door. Untyped: an AnimatableBody3D only becomes a door once the script is on it.
func _door(keys := {}):
	var body = AnimatableBody3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 2, 2)
	var col := CollisionShape3D.new()
	col.shape = box
	body.add_child(col)
	var e := {"classname": "func_door", "angles": "0 0 0", "speed": "500", "team_no": "1"}
	e.merge(keys, true)
	body.set_meta("entity", e)
	body.set_script(FuncDoor)
	_root().add_child(body)
	_spawned.append(body)
	return body


## Something with a team standing at the door. _check_team reads `team` and the meta and nothing
## else, so a two-line script is the whole player this test needs.
func _actor(team: int, monster := false) -> Node3D:
	var script := GDScript.new()
	script.source_code = "extends Node3D\nvar team := 0\n"
	script.reload()
	var n := Node3D.new()
	n.set_script(script)
	n.team = team
	if monster:
		n.set_meta(GameConsts.META_IGNORES_TEAM_DOORS, true)
	_root().add_child(n)
	_spawned.append(n)
	return n


# --- the gate -------------------------------------------------------------

func test_the_owning_team_passes() -> void:
	assert_true(_door()._check_team(_actor(GameConsts.Team.BLUE)), "blue's own door opens for blue")


func test_the_other_team_is_kept_out() -> void:
	assert_false(_door()._check_team(_actor(GameConsts.Team.RED)), "that is what the key is for")


func test_a_monster_is_not_kept_out() -> void:
	assert_true(_door()._check_team(_actor(SiegeSystem.MONSTER_TEAM, true)),
		"a siege monster is on no playing team — without the mark every base door is a wall")


func test_an_unmarked_monster_is_still_kept_out() -> void:
	assert_false(_door()._check_team(_actor(SiegeSystem.MONSTER_TEAM)),
		"the bypass is the mark, not the team — a player's own summon obeys the map's keys")


func test_an_ally_is_kept_out() -> void:
	_ally_red_and_blue()
	assert_false(_door()._check_team(_actor(GameConsts.Team.RED)),
		"an alliance is friendly fire and the ID line; it is not a key to the base")


func test_an_ungated_door_opens_for_anything() -> void:
	var d = _door({"team_no": "0"})
	assert_true(d._check_team(_actor(GameConsts.Team.RED)), "no key, no gate")
	assert_true(d._check_team(null), "a trigger chain with no activator still works it")


# --- being seen in the first place ----------------------------------------

func test_the_touch_volume_watches_monsters() -> void:
	var d = _door()
	await _tick(2)
	var area: Area3D = d.get_node_or_null("TouchArea")
	assert_true(area != null, "a door with no targetname opens on touch")
	if area == null:
		return
	assert_true((area.collision_mask & GameConsts.MASK_ENTITY) != 0,
		"a door a monster cannot knock on is a wall, whatever the team gate says")
	assert_true((area.collision_mask & GameConsts.MASK_PLAYER) != 0, "and still players")


# --- the trigger that fires the door --------------------------------------
#
# Half the maps gate their base doors with a separate team trigger_multiple rather than with the
# door's own touch volume (2fort's resupplies, ww_wolteg's spawn doors), and a door that carries a
# targetname builds no touch volume at all. So the trigger has to answer a monster too — but only
# when what it fires is a door. Letting one trip every trigger in a map would fire capture goals,
# monstermakers and the multi_managers that run a map's round.

func _trigger(keys := {}) -> Node3D:
	var e := {"classname": "trigger_multiple", "target": "spawn_door"}
	e.merge(keys, true)
	var t: Node3D = TriggerMultipleScript.new()
	var area := Area3D.new()
	area.name = "Volume"
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 4)
	col.shape = box
	area.add_child(col)
	t.add_child(area)
	t.set_meta("entity", e)
	_root().add_child(t)
	_spawned.append(t)
	return t


## A monster body, as the siege spawns one: MASK_ENTITY, on the monster team, marked.
func _monster_body() -> CharacterBody3D:
	var script := GDScript.new()
	script.source_code = "extends CharacterBody3D\nvar team := 0\nvar is_dead := false\n"
	script.reload()
	var b := CharacterBody3D.new()
	b.set_script(script)
	b.team = SiegeSystem.MONSTER_TEAM
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	col.shape = sphere
	b.add_child(col)
	b.collision_layer = GameConsts.MASK_ENTITY
	b.set_meta(GameConsts.META_IGNORES_TEAM_DOORS, true)
	_root().add_child(b)
	b.global_position = Vector3.ZERO
	_spawned.append(b)
	return b


## A wizard standing on a trigger: MASK_PLAYER and alive, which is all _touch reads.
func _player_body(team: int) -> CharacterBody3D:
	var script := GDScript.new()
	script.source_code = "extends CharacterBody3D\nvar team := 0\nvar is_alive := true\n"
	script.reload()
	var b := CharacterBody3D.new()
	b.set_script(script)
	b.team = team
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	col.shape = sphere
	b.add_child(col)
	b.collision_layer = GameConsts.MASK_PLAYER
	_root().add_child(b)
	b.global_position = Vector3.ZERO
	_spawned.append(b)
	return b


func _counting_target() -> CountingTarget:
	var target := CountingTarget.new()
	_root().add_child(target)
	_spawned.append(target)
	TriggerSystem.register("spawn_door", target)
	return target


func test_a_monster_works_a_door_trigger() -> void:
	var d = _door({"targetname": "spawn_door"})
	TriggerSystem.register("spawn_door", d)
	var t := _trigger({"team_no": "1"})
	_monster_body()
	await _tick(4)
	assert_true(d.state != FuncDoorBase.State.AT_BOTTOM,
		"a blue spawn door fired by a blue-only trigger still has to open for the attackers")


func test_a_monster_leaves_the_rest_of_the_map_alone() -> void:
	var target := CountingTarget.new()
	_root().add_child(target)
	_spawned.append(target)
	TriggerSystem.register("spawn_door", target)
	var _t := _trigger()
	_monster_body()
	await _tick(8)
	assert_eq(target.fires, 0,
		"a monster standing on a trigger that fires no door must not fire it — capture goals, "
		+ "monstermakers and multi_managers were written for players")


# --- the same rule, reached through a trigger ------------------------------
#
# ww_hunt's fifteen location volumes are team_no 1 (the Hunted) and announce him to the team-2
# bodyguards. The map allies those two teams, so an alliance that answers a team key had every
# bodyguard announcing the Hunted's position — and stamping the trigger's wait doing it, which
# swallowed the announcement he was due. UTIL_IsMasterTriggered runs before both.

func test_an_ally_does_not_fire_a_trigger() -> void:
	_ally_red_and_blue()
	var target := _counting_target()
	var t := _trigger({"team_no": "1"})
	t._wait_time = 0.05
	_player_body(GameConsts.Team.RED)
	await _tick(12)
	assert_eq(target.fires, 0, "a bodyguard is not the Hunted, however friendly they are")


func test_the_keyed_team_fires_its_trigger() -> void:
	_ally_red_and_blue()
	var target := _counting_target()
	var _t := _trigger({"team_no": "1"})
	_player_body(GameConsts.Team.BLUE)
	await _tick(4)
	assert_gt(target.fires, 0, "the Hunted himself announces his own position")


## A door is no exception: the same ally is kept out of the volume that fires one.
func test_an_ally_does_not_fire_a_door_trigger_either() -> void:
	_ally_red_and_blue()
	var d = _door({"targetname": "spawn_door"})
	TriggerSystem.register("spawn_door", d)
	var _t := _trigger({"team_no": "1"})
	_player_body(GameConsts.Team.RED)
	await _tick(8)
	assert_true(d.state == FuncDoorBase.State.AT_BOTTOM,
		"the enemy of a siege is the wave, and it carries the mark — not an allied wizard's team")
