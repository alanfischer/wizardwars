extends "res://src/tests/test_base.gd"
## The crosshair ID line — who you are looking at, and how much of them there is left.
##
## Composed on the server (RemotePlayer.tick_target_id traces, Teams.target_id_line words it)
## because health is server-side state: a client only ever knows its own. These cover the wording
## and the rules about who may read what; the trace itself needs a live map.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const PlayerScript = preload("res://src/player.gd")
const ThornplantScript = preload("res://src/monsters/thornplant.gd")


func _make_player(pid: int, team: int, elem := GameConsts.Element.FIRE, player_name := "") -> Node:
	var p: CharacterBody3D = PlayerScript.new()
	p.peer_id = pid
	p.team = team
	p.element = elem
	p.health = 75.0
	p.max_health = 100.0
	if not player_name.is_empty():
		NetworkManager.set_player_name(pid, player_name)
	_keep(p)
	return p


func _teardown_test() -> void:
	NetworkManager.swap_peer_table()
	await super()


func test_an_ally_is_named_with_their_health() -> void:
	var viewer := _make_player(1, GameConsts.Team.BLUE)
	var ally := _make_player(2, GameConsts.Team.BLUE, GameConsts.Element.ICE, "Merlin")
	assert_eq(Teams.target_id_line(viewer, ally), ["Merlin", 1, 75],
		"an ally should read as a friend, with health")


func test_an_enemy_is_named_without_their_health() -> void:
	var viewer := _make_player(1, GameConsts.Team.BLUE)
	var foe := _make_player(2, GameConsts.Team.RED, GameConsts.Element.ICE, "Morgana")
	assert_eq(Teams.target_id_line(viewer, foe), ["Morgana", -1, -1],
		"an enemy's health is not the enemy's to give away")


func test_the_life_wizard_reads_health_off_anyone() -> void:
	var viewer := _make_player(1, GameConsts.Team.BLUE, GameConsts.Element.LIFE)
	var foe := _make_player(2, GameConsts.Team.RED, GameConsts.Element.ICE, "Morgana")
	assert_eq(Teams.target_id_line(viewer, foe), ["Morgana", -1, 75],
		"the life wizard's status bar read health off everything in the original")


func test_deathmatch_says_neither_friend_nor_foe() -> void:
	var viewer := _make_player(1, GameConsts.Team.NONE)
	var other := _make_player(2, GameConsts.Team.NONE, GameConsts.Element.ICE, "Rincewind")
	assert_eq(Teams.target_id_line(viewer, other), ["Rincewind", 0, -1],
		"with no teams everyone is a foe, so the word says nothing worth the space")


func test_an_invisible_wizard_is_not_given_away() -> void:
	var viewer := _make_player(1, GameConsts.Team.BLUE)
	var foe := _make_player(2, GameConsts.Team.RED, GameConsts.Element.ICE, "Morgana")
	foe.is_invisible = true
	assert_eq(Teams.target_id_line(viewer, foe), ["", 0, -1],
		"the ID line would undo the ice wizard's whole spell")


func test_a_dead_body_is_not_named() -> void:
	var viewer := _make_player(1, GameConsts.Team.BLUE)
	var foe := _make_player(2, GameConsts.Team.RED, GameConsts.Element.ICE, "Morgana")
	foe.is_dead = true
	assert_eq(Teams.target_id_line(viewer, foe), ["", 0, -1], "a corpse has no name over it")


func test_your_own_body_is_not_named() -> void:
	# On a listen server one player owns two nodes (the view and its puppet) sharing a peer id;
	# looking down must not identify yourself through the second one.
	var viewer := _make_player(1, GameConsts.Team.BLUE, GameConsts.Element.FIRE, "Alan")
	var own_puppet := _make_player(1, GameConsts.Team.BLUE, GameConsts.Element.FIRE)
	assert_eq(Teams.target_id_line(viewer, own_puppet), ["", 0, -1],
		"your own puppet is you, not a target")


func test_a_summon_is_named_after_its_caster() -> void:
	var viewer := _make_player(1, GameConsts.Team.RED)
	var caster := _make_player(2, GameConsts.Team.BLUE, GameConsts.Element.NATURE, "Merlin")
	var plant: Node3D = ThornplantScript.new()
	plant.team = GameConsts.Team.BLUE
	plant.owner_node = caster
	_keep(plant)
	var line := Teams.target_id_line(viewer, plant)
	assert_eq(line[0], "Merlin's Thornplant", "a plant is known by who planted it")
	assert_eq(line[1], -1, "and it belongs to their side, not yours")


func test_an_ownerless_summon_keeps_its_own_name() -> void:
	var viewer := _make_player(1, GameConsts.Team.RED)
	var plant: Node3D = ThornplantScript.new()
	plant.team = GameConsts.Team.BLUE
	_keep(plant)
	assert_eq(Teams.target_id_line(viewer, plant)[0], "Thornplant",
		"a plant whose caster is gone is still a plant")


func test_map_props_stay_silent() -> void:
	# func_breakable and the buttons take damage like anything else, and naming them off their
	# script would put "Func Breakable" over every crate on the map.
	var viewer := _make_player(1, GameConsts.Team.BLUE)
	var crate: Node3D = load("res://src/entities/func_breakable.gd").new()
	assert_eq(Teams.target_id_line(viewer, crate), ["", 0, -1],
		"a crate is not somebody")
	crate.free()


func test_nothing_under_the_crosshair_says_nothing() -> void:
	var viewer := _make_player(1, GameConsts.Team.BLUE)
	assert_eq(Teams.target_id_line(viewer, null), ["", 0, -1], "a miss clears the line")


# --- The trace itself ---
#
# The server's half: a puppet reconstructs its owner's aim from synced yaw/pitch, traces
# MAX_ID_RANGE, and reads the line off whatever the ray landed on. Real puppets, because the
# ray deliberately misses player capsules and lands on the per-bone hitbox areas an .mdl
# carries (Combat.collect_hitscan_excludes) — a stand-in body would be hit by a trace the
# live game's trace would pass straight through.

const RemotePlayerScene = preload("res://src/remote_player.tscn")


func _puppet(pid: int, team: int, pos: Vector3, player_name := "") -> RemotePlayer:
	var p: RemotePlayer = RemotePlayerScene.instantiate()
	# Out of the stream: a NetSync with no multiplayer peer has nothing to talk to.
	var net_sync := p.get_node(^"NetSync")
	p.remove_child(net_sync)
	net_sync.free()
	p.peer_id = pid
	p.team = team
	if not player_name.is_empty():
		NetworkManager.set_player_name(pid, player_name)
	_root().add_child(p)
	_spawned.append(p)
	p._load_player_model("fire")
	p.set_damageable(true)
	p.global_position = pos
	return p


func test_the_trace_names_the_wizard_in_front_of_it() -> void:
	var viewer := _puppet(1, GameConsts.Team.BLUE, Vector3.ZERO)
	viewer.rotation.y = 0.0  # looking down -Z
	_puppet(2, GameConsts.Team.RED, Vector3(0.0, 0.0, -5.0), "Morgana")
	await _settle()
	assert_eq(viewer._look_target_line(), ["Morgana", -1, -1],
		"the trace should land on the hitboxes of the wizard five metres ahead")


func test_the_trace_names_nobody_when_it_is_pointed_away() -> void:
	var viewer := _puppet(1, GameConsts.Team.BLUE, Vector3.ZERO)
	viewer.rotation.y = PI  # about-face
	_puppet(2, GameConsts.Team.RED, Vector3(0.0, 0.0, -5.0), "Morgana")
	await _settle()
	assert_eq(viewer._look_target_line(), ["", 0, -1], "nothing under the crosshair, nothing said")


func test_a_puppet_still_loading_the_map_reads_nothing() -> void:
	# main._on_peer_connected parks an unspawned peer's puppet on a spawn point with its
	# collider off and out of the damageable group. It must not be feeding that client names.
	var viewer := _puppet(1, GameConsts.Team.BLUE, Vector3.ZERO)
	viewer.rotation.y = 0.0
	viewer.set_damageable(false)
	_puppet(2, GameConsts.Team.RED, Vector3(0.0, 0.0, -5.0), "Morgana")
	await _settle()
	assert_eq(viewer._look_target_line(), ["", 0, -1], "a body that hasn't spawned sees nothing")


# --- What the player actually reads ---

func test_the_hud_wording() -> void:
	var hud := _make_hud()
	_keep(hud)
	hud.set_target_id("Merlin", 1, 75)
	assert_eq(hud._target_id_label.text, "(Friend) Merlin  75%", "an ally reads as one, with health")
	assert_true(hud._target_id_label.visible, "…and is on screen")

	hud.set_target_id("Morgana", -1, -1)
	assert_eq(hud._target_id_label.text, "(Foe) Morgana", "an enemy's line carries no health")

	hud.set_target_id("Rincewind", 0, -1)
	assert_eq(hud._target_id_label.text, "Rincewind",
		"with no sides in play the line is just the name")

	hud.set_target_id("", 0, -1)
	assert_false(hud._target_id_label.visible, "an empty line leaves the screen")
