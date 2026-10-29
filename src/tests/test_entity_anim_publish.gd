extends "res://src/tests/test_base.gd"
## A dynamic entity's animation reaches clients only through EntityBehavior writing the name onto
## its NetInterp:net_anim slot. Two Godot quirks made that silently no-op: play() emits
## current_animation_changed, not animation_changed; and on the first play() that signal arrives
## before current_animation is assigned, so a read-back publish sent "".

## The behavior bound by the most recent _make_entity() — the swap test drives it directly.
var _behavior: EntityBehavior


## A host entity wired the way the dynamic-entity spawner wires one: NetInterp bridge
## child, an AnimationPlayer, and an EntityBehavior bound to both (two-step, as every
## production caller does it — the model only exists by _ready).
func _make_entity() -> Node3D:
	var host := Node3D.new()
	var bridge := NetInterpBridge.new()
	bridge.name = "NetInterp"
	host.add_child(bridge)
	host.add_child(_make_anim_player())
	_root().add_child(host)
	_behavior = EntityBehavior.new()
	_behavior.initialize(host, true)
	_behavior.set_anim_player(host.get_node("AnimationPlayer"))
	return host


func _make_anim_player() -> AnimationPlayer:
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	var lib := AnimationLibrary.new()
	for anim_name in ["flying_cycler", "idle_1"]:
		var a := Animation.new()
		a.length = 1.0
		lib.add_animation(anim_name, a)
	ap.add_animation_library("", lib)
	return ap


func test_first_play_publishes_its_name() -> void:
	var host := _make_entity()
	var ap: AnimationPlayer = host.get_node("AnimationPlayer")

	assert_eq(host.get_node("NetInterp").net_anim, "", "nothing published before the first play")
	ap.play("flying_cycler")
	assert_eq(host.get_node("NetInterp").net_anim, "flying_cycler",
		"the very first play() must reach the slot — a dragon plays no second clip")
	host.queue_free()


func test_switching_animation_republishes() -> void:
	var host := _make_entity()
	var ap: AnimationPlayer = host.get_node("AnimationPlayer")

	ap.play("flying_cycler")
	ap.play("idle_1")
	assert_eq(host.get_node("NetInterp").net_anim, "idle_1", "a later clip supersedes")
	host.queue_free()


func test_publish_survives_late_anim_player() -> void:
	# Models load in _ready, so set_anim_player is called after the bridge exists;
	# swapping players must move the hook rather than leave the old one publishing.
	var host := _make_entity()
	var replacement := _make_anim_player()
	replacement.name = "AnimationPlayer2"
	host.add_child(replacement)
	_behavior.set_anim_player(replacement)

	host.get_node("AnimationPlayer").play("idle_1")
	assert_eq(host.get_node("NetInterp").net_anim, "", "the detached player no longer publishes")
	replacement.play("flying_cycler")
	assert_eq(host.get_node("NetInterp").net_anim, "flying_cycler", "the current player does")
	host.queue_free()
