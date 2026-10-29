class_name SatchelBehavior
extends RefCounted

## A wizard's satchels: the count the HUD draws, and the server-side fuse of a primed-but-
## unthrown one. Held by Player as `satchel_pack`.

var count := 3
var max_count := 3
## Fuse of a primed-but-unthrown satchel. -1.0 = not primed. Only meaningful on the
## server-side puppet, ticked from RemotePlayer._physics_process.
var fuse_remaining := -1.0

var _host: Node3D


func initialize(host: Node3D) -> void:
	_host = host


## The satchel pack of a node that has one, or null — callers reaching a player duck-typed.
static func of(node: Object) -> SatchelBehavior:
	return node.get("satchel_pack") if is_instance_valid(node) else null


## Back to a full pack with nothing primed. Part of the spawn reset.
func refill() -> void:
	count = max_count
	fuse_remaining = -1.0


func add(amount: int) -> void:
	count = mini(count + amount, max_count)


## Server: begin priming a held satchel (start the fuse countdown). Returns true
## if a satchel was consumed and primed, false if it couldn't start (dead, already
## primed, or out of satchels). Caller syncs the new satchel count to the owner.
func prime() -> bool:
	if _host.is_dead:
		return false
	if fuse_remaining >= 0.0:
		return false  # already primed
	if count <= 0:
		return false  # out of satchels
	count -= 1
	fuse_remaining = Satchel.FUSE_TIMES[_host.element]
	return true


## Server: throw the currently-primed satchel, carrying its remaining fuse. No-op
## if nothing is primed.
func throw(aim_dir: Vector3) -> void:
	if fuse_remaining < 0.0:
		return  # not primed
	var fuse := fuse_remaining
	fuse_remaining = -1.0
	spawn(aim_dir.normalized(), fuse)


## Server: advance a primed fuse; if it expires while still in hand, force-spawn
## and immediately detonate. Called each physics tick from the puppet.
func tick_fuse(delta: float) -> void:
	if fuse_remaining < 0.0:
		return
	fuse_remaining -= delta
	if fuse_remaining <= 0.0:
		fuse_remaining = -1.0
		if not _host.is_dead:
			spawn(Vector3.FORWARD, 0.0)


## Server: drop a still-primed satchel where the player fell, so dying doesn't
## silently swallow it. The dropped satchel keeps ticking its own fuse on the
## ground (and can still detonate on whoever killed you).
func drop_on_death() -> void:
	if fuse_remaining < 0.0:
		return
	var fuse := fuse_remaining
	fuse_remaining = -1.0
	# Drop at the body with a small toss so it settles beside the corpse rather
	# than launching like a thrown satchel.
	_spawn_entity(_host.global_position + Vector3(0, 0.5, 0), Vector3(0, 1.0, 0), fuse)


func spawn(aim_dir: Vector3, fuse: float) -> void:
	var spawn_pos := _host.global_position + Vector3(0, 1.6, 0) + aim_dir * 0.1
	var throw_vel := aim_dir * Satchel.THROW_SPEED + Vector3(0, 3.0, 0)
	_spawn_entity(spawn_pos, throw_vel, fuse)


## Server: bin this player's live satchels, plus a primed-but-unthrown one. A thrown
## satchel keeps ticking across a respawn, and the ice satchel teleports its owner on
## detonation — one thrown just before a round reset would yank the player back out of spawn.
func remove_live() -> void:
	fuse_remaining = -1.0
	for node in _host.get_tree().get_nodes_in_group("projectile"):
		if node is Satchel and node.owner_node == _host:
			node.cancel()


func _spawn_entity(spawn_pos: Vector3, throw_velocity: Vector3, fuse: float) -> void:
	NetworkManager.spawn_projectile("res://src/weapons/satchel.gd", {
		"position": spawn_pos,
		"velocity": throw_velocity,
		"element": _host.element,
		"team": _host.team,
		"fuse_remaining": fuse,
	}, _host)
