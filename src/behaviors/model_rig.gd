class_name ModelRig
extends RefCounted

## A creature's MDL rig: which clip it is showing, when that clip comes round, and whether
## anything is looking at it.
##
## A behavior rather than a base class, for the same reason as [EntityBehavior] — the things that
## carry one extend three different engine types. It sits *beside* the entity behavior and never
## wraps it: main.gd wires a dynamic entity's network id by finding an `_entity` or `_summon`
## member by name, so a composite that swallowed one would silently lose state sync.
##
## Two jobs, and the first is what makes the second possible:
##
## - **The clip clock.** `play()` and `clip_over()` answer off the rig's own `age`, never off the
##   AnimationPlayer. A sleeping AnimationPlayer reports its clip as playing forever and never
##   fires `animation_finished`, so an AI that asks the mixer what it is doing can never be let
##   to sleep. The clock is the prerequisite, not a detail of it.
## - **Sleeping.** Animating a rig is most of what a crowd of MDL creatures costs — ~0.2ms per
##   skinned surface per frame under gl_compatibility — and it is pure presentation, so
##   `sleep_offscreen()` animates only where someone can see it, and never on a dedicated server.
##   That is only legal once nothing gameplay-facing hangs off a bone: `add_hitbox()` is the
##   static replacement for the per-bone volumes an MDL ships with, which AssetLoader.strip_hitboxes
##   takes off. A creature still shot through bone-attached hitboxes has to stay awake.
##
## `clip` is the authority's answer, and only the authority's: a client's rig is driven by the
## synced clip name landing on the AnimationPlayer, so it never calls play() and leaves this
## empty. Anything a client has to reason about — "is the attack clip on screen right now?" —
## belongs to `anim_player`, which is what that peer is actually showing.

## Where a clip's loop_mode comes from.
enum Loop {
	## The MDL's own STUDIO_LOOPING flag, as the importer read it.
	MODEL,
	## Only `looping_clips` loop and everything else is a one-shot — what an AI that waits for
	## clips to end needs, since a looping idle would strand it in that idle forever.
	LISTED,
}

var anim_player: AnimationPlayer
## The clip the AI last asked for (authority only — see the note above).
var clip := ""
## The `age` the current clip comes round at.
var clip_ends := 0.0
var age := 0.0
var loop_policy := Loop.MODEL
var looping_clips := PackedStringArray()

var _host: Node3D
var _loops := false


func initialize(host: Node3D, player: AnimationPlayer, policy := Loop.MODEL,
		looping := PackedStringArray()) -> void:
	_host = host
	anim_player = player
	loop_policy = policy
	looping_clips = looping


func tick(delta: float) -> void:
	age += delta


## Make `clip_name` the clip that is playing. One already running is left alone until it has come
## round, so a one-shot is never cut short and a loop is never restarted for nothing — but the
## clock is re-stamped either way, which is how a caller learns when the next cycle lands.
func play(clip_name: String, restart := false) -> void:
	if anim_player == null or not anim_player.has_animation(clip_name):
		return
	var same := clip_name == clip
	if same and not restart and not clip_cycled():
		return
	var anim := anim_player.get_animation(clip_name)
	if loop_policy == Loop.LISTED:
		anim.loop_mode = Animation.LOOP_LINEAR if clip_name in looping_clips else Animation.LOOP_NONE
	_loops = anim.loop_mode != Animation.LOOP_NONE
	clip = clip_name
	clip_ends = age + anim.length
	if same and not restart and _loops:
		return  # going round again: re-timed, but not worth a restart or a re-publish
	if same:
		# Restarted in place rather than through stop(): an AnimationPlayer emits
		# current_animation_changed only when the *name* changes, so stop() here would publish
		# "" and the play() after it would publish nothing at all. A client already on this clip
		# loses nothing by that, but one arriving afterwards is handed an empty clip name and
		# stands in its rest pose until the creature next picks a different clip.
		anim_player.play(clip_name)
		anim_player.seek(0.0, true)
		return
	anim_player.stop()  # clears current_animation, so the new name is published to clients
	anim_player.play(clip_name)


## Has the current clip run its length? True once per cycle for a loop, and true from then on
## for a one-shot.
func clip_cycled() -> bool:
	return not clip.is_empty() and age >= clip_ends


## ...and it was a one-shot, so it is finished rather than going round again.
func clip_over() -> bool:
	return not _loops and clip_cycled()


## Animate only where someone can see it. `aabb` is the creature's extent in host-local space —
## the box the notifier measures against the screen. The connections below are safe to hand a
## RefCounted's methods to — a Callable holds no reference to its object — because the host node holds
## this rig, and the notifier is the host's own child.
func sleep_offscreen(aabb: AABB) -> void:
	sleep()
	if DisplayServer.get_name() == "headless":
		return  # a dedicated server draws nobody, so nothing ever wakes it
	var notifier := VisibleOnScreenNotifier3D.new()
	notifier.aabb = aabb
	notifier.screen_entered.connect(wake)
	notifier.screen_exited.connect(sleep)
	_host.add_child(notifier)


func wake() -> void:
	if anim_player:
		anim_player.active = true


func sleep() -> void:
	if anim_player:
		anim_player.active = false


## A static hit volume on the host body, standing in for the per-bone ones the MDL ships with.
## A box on a body that already has a hull costs nothing to animate, and having one is what lets
## the rig sleep at all.
func add_hitbox(size: Vector3, center: Vector3, group := 0) -> Area3D:
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	var area := Area3D.new()
	area.collision_layer = GameConsts.MASK_HITBOX
	area.collision_mask = 0
	area.monitoring = false   # queryable only, the way the MDL builds its own
	area.monitorable = true
	area.set_meta("hitbox_group", group)
	area.position = center
	area.add_child(shape)
	_host.add_child(area)
	return area
