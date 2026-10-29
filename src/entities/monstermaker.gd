class_name MonsterMaker
extends EntityBase
## monstermaker — runtime monster spawner (GoldSrc/WizardWars).
##
## WW's `ww_monstermaker` fork only renamed the classname, so both read the same
## keys and run through here.
##
## Maintains a live population of `monstertype` monsters at its origin, respawning
## `delay` seconds after a child dies. This is how many maps place their dragon(s)
## — e.g. ww_skytower's tower-top dragon ("if the dragon dies, a new one respawns")
## and ww_varrock/ww_countryside/ww_feudal — rather than placing a monster_dragon
## directly.
##
## Server-authoritative: spawns ride NetworkManager.spawn_dynamic_entity (the same
## path a map-placed dragon re-creates itself through), so every client receives the
## replica with a synchronizer + PVS + state-sync id. Only monster types we actually
## implement spawn; the two monster_zombie makers stay inert until there is a zombie.
##
## A maker with a targetname waits to be fired. SF_CYCLIC drops one monster per firing
## (ww_matrox's skeleton waves, where a trigger_multiple on each approach feeds three
## makers); without it the firing toggles the free-running clock on and off.

# GoldSrc monstertype -> entity script. Extend as monster types are implemented.
const MONSTER_SCRIPTS := {
	"monster_dragon": "res://src/monsters/dragon.gd",
	"dragon": "res://src/monsters/dragon.gd",
	"monster_skeleton": "res://src/monsters/skeleton.gd",
	"monster_sheep": "res://src/monsters/sheep.gd",
}
const INITIAL_DELAY := 0.5  # first monster lands almost immediately, not after `delay`
## Radius of the "is anyone standing on my spawn point" probe — a monster hull's own width.
const SPAWN_CLEARANCE := 16.0 * GameConsts.SCALE_FACTOR
const SF_START_ON := 1
const SF_CYCLIC := 4

var _script_path := ""
var _max_live := 1        # target live children (WW dragons are one per spawn point)
var _delay := 5.0         # seconds to wait after a death before respawning
var _remaining := -1      # total left to spawn (-1 = infinite)
var _team_no := 0
var _children: Array[Node] = []
var _cooldown := INITIAL_DELAY
var _cyclic := false
var _active := false


func _ready() -> void:
	super()
	# Point entity — no mesh/collision. Spawner logic runs only on the authority;
	# clients get the monsters as replicated dynamic entities, so they do nothing.
	if not NetworkManager.is_authority():
		set_process(false)
		return
	_script_path = MONSTER_SCRIPTS.get(ent.get("monstertype", ""), "")
	if _script_path.is_empty():  # zombie — not implemented
		set_process(false)
		return
	_team_no = parse_int(ent, "team_no", 0)
	_delay = maxf(0.1, float(ent.get("delay", 5)))
	# m_imaxlivechildren <= 0 means "no cap" in GoldSrc, but a WW dragon spawn is a
	# single mountable dragon that respawns on death — treat it as one to avoid
	# spawning an unbounded dragon swarm every `delay` seconds.
	var maxlive := parse_int(ent, "m_imaxlivechildren", 1)
	_max_live = maxlive if maxlive > 0 else 1
	_remaining = parse_int(ent, "monstercount", -1)
	var spawnflags := parse_int(ent, "spawnflags", 0)
	_cyclic = (spawnflags & SF_CYCLIC) != 0
	var named: bool = not ent.get("targetname", "").is_empty()
	# A cyclic maker spawns only when fired, so its clock never runs — the original sets
	# the think function for START_ON but never gives it a nextthink.
	_active = not named or (not _cyclic and (spawnflags & SF_START_ON) != 0)
	set_process(_active)


## Fired by name: one monster for a cyclic maker, on/off for any other.
func trigger(_activator: Node, type: TriggerSystem.Type) -> void:
	if _script_path.is_empty() or _is_network_client():
		return
	if _cyclic:
		_spawn_one()
		return
	_active = type == TriggerSystem.Type.ON or (type == TriggerSystem.Type.TOGGLE and not _active)
	set_process(_active)
	_cooldown = 0.0  # an activated maker drops its first monster at once, as GoldSrc does


func _process(delta: float) -> void:
	if not _active:
		return
	# At target population the cooldown stays primed so a death starts a fresh delay.
	if _live_children() >= _max_live:
		_cooldown = _delay
		return
	if _remaining == 0:
		return
	_cooldown -= delta
	if _cooldown <= 0.0:
		_spawn_one()
		_cooldown = _delay


func _live_children() -> int:
	_children = _children.filter(func(c): return is_instance_valid(c) and not c.is_queued_for_deletion())
	return _children.size()


func _spawn_one() -> void:
	if _remaining == 0 or _live_children() >= _max_live:
		return
	if not _spawn_point_clear():
		return  # occupied; the clock is reset either way, so it tries again next delay
	var child := _spawn_child()
	if child == null:
		return  # spawner not ready yet; retry next cooldown
	_children.append(child)
	if _remaining > 0:
		_remaining -= 1


## "don't build a stack of monsters!" — the original checks its spawn point for players and
## monsters before making anything, and skips the turn if one is standing there. ww_feudal asks
## one maker for a flock of ten, so without this they come out inside each other.
func _spawn_point_clear() -> bool:
	if not is_inside_tree():
		return true
	var space := get_world_3d().direct_space_state
	if space == null:
		return true
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = SPAWN_CLEARANCE
	query.shape = sphere
	query.transform = Transform3D(Basis(), global_position + Vector3.UP * SPAWN_CLEARANCE)
	query.collision_mask = GameConsts.MASK_ENTITY | GameConsts.MASK_PLAYER
	return space.intersect_shape(query, 1).is_empty()


## The network half on its own, so a test can stand in for it and still drive the real bookkeeping.
func _spawn_child() -> Node:
	var xform := global_transform
	var yaw := xform.basis.get_euler().y
	return NetworkManager.spawn_dynamic_entity({
		"script_path": _script_path,
		# Both spellings of the team: a dragon reads its spawn as the map entity it also is
		# (team_no), a skeleton as the summon it also is (team).
		"team_no": _team_no,
		"team": _team_no,
		"position": xform.origin,
		"yaw": yaw,
		"sync_state": true,
	})
