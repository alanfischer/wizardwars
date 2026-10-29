extends Node
## Records where everyone was during a match, so it can be replayed from above.
##
## Started by /record and stopped by /stoprecord (or when the map changes). Writes a CSV to
## user://replays/<map>-<stamp>.csv, which tools/match_gif.py turns into a video over the
## backdrop from tools/map_top.gd.
##
## Host-side: it walks the player registry, so it captures connected humans and bots alike, which is
## the point — a replay of a match you played is only useful if you are in it.
##
## Deliberately more than positions. What makes a replay diagnostic rather than decorative is
## seeing WHY a bot did something, so each row carries the bot's current route target and what
## its brain was doing; a dot that circles is then obviously a dot whose target keeps flipping.

const HZ := 10.0                  # samples a second; 10 is smooth enough to read at playback

var _f: FileAccess = null
var _t := 0.0
var _elapsed := 0.0
var _limit := 0.0
var path := ""
# Both fixed for the map's lifetime, so they are resolved once rather than rebuilt 10x a second:
# the carriable flags, and each row's comma-stripped name (id -> name).
var _flags: Array = []
var _names := {}


func start(map_name: String, seconds: float) -> String:
	stop()
	DirAccess.make_dir_recursive_absolute("user://replays")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	path = "user://replays/%s-%s.csv" % [map_name, stamp]
	_f = FileAccess.open(path, FileAccess.WRITE)
	if _f == null:
		path = ""
		return ""
	_f.store_line("# map=%s hz=%.1f" % [map_name, HZ])
	_f.store_line("t,id,name,team,x,y,z,yaw,alive,carrying,state,tx,tz,element")
	_t = 0.0
	_elapsed = 0.0
	_limit = seconds
	_flags = GoalSystem.get_carriable_flags()
	_names.clear()
	set_physics_process(true)
	return path


func stop() -> void:
	set_physics_process(false)
	if _f != null:
		_f.close()
		_f = null


func is_recording() -> bool:
	return _f != null


func _physics_process(delta: float) -> void:
	if _f == null:
		return
	_elapsed += delta
	if _limit > 0.0 and _elapsed >= _limit:
		stop()
		return
	_t += delta
	if _t < 1.0 / HZ:
		return
	_t = 0.0
	if not Game.game_active:
		return
	# The grail matters more than any individual bot — a replay where you cannot see the
	# objective move cannot answer "did anyone nearly score". Carried ones are drawn at the
	# carrier's feet by the game already, so their logged position follows the carrier for free.
	for g in _flags:
		if not is_instance_valid(g):
			continue
		var gp: Vector3 = g.global_position
		var held: int = int(g.get("_carrier_peer_id"))
		_f.store_line("%.2f,%d,%s,%d,%.2f,%.2f,%.2f,0,1,%d,grail,0,0,-1" % [
			_elapsed, 9000 + g.get_instance_id() % 900, _name_of(g),
			int(g.get("owned_by")) if g.get("owned_by") != null else 0,
			gp.x, gp.y, gp.z, 1 if held != 0 else 0])
	var players := NetworkManager.player_roster()
	for id in players:
		var p = players[id]
		if not (p is Node3D):
			continue
		var pos: Vector3 = p.global_position
		var brain = p.get_node_or_null("BotBrain")
		var state := "player"
		var tx := 0.0
		var tz := 0.0
		if brain != null:
			state = _brain_state(brain)
			var tgt := _brain_target(brain)
			tx = tgt.x
			tz = tgt.z
		_f.store_line("%.2f,%d,%s,%d,%.2f,%.2f,%.2f,%.3f,%d,%d,%s,%.2f,%.2f,%d" % [
			_elapsed, int(id), _name_of(p), int(p.get("team")),
			pos.x, pos.y, pos.z, p.rotation.y,
			0 if p.get("is_dead") else 1,
			0 if p.get("carried_items") == null or (p.get("carried_items") as Array).is_empty() else 1,
			state, tx, tz, int(p.get("element")) if p.get("element") != null else -1])


## Row-safe name, cached: the CSV is comma-separated and a name never changes mid-match.
func _name_of(n: Node) -> String:
	var k := n.get_instance_id()
	if not _names.has(k):
		_names[k] = String(n.name).replace(",", " ")
	return _names[k]


## One word for what the brain is doing, chosen most-specific first — this is what gets coloured
## in the replay, so the useful answer is the unusual state rather than the common one.
func _brain_state(b) -> String:
	if b.get("_riding"):
		return "lift"
	if b.get("_free_t") != null and float(b.get("_free_t")) > 0.0:
		return "unstick"
	if b.get("_rescue_id") != null and int(b.get("_rescue_id")) >= 0:
		return "rescue"
	if b.get("_local_nav"):
		return "local"
	if b.get("_known") != null:
		return "fighting"
	if b.get("_roaming"):
		return "roam"
	return "route"


## Where the bot is heading right now: its current route node, else the objective it committed to.
func _brain_target(b) -> Vector3:
	var g = b.get("_graph")
	var route = b.get("_route")
	var i: int = int(b.get("_route_i"))
	if g != null and route != null and i >= 0 and i < (route as Array).size():
		return g.position_of(route[i])
	var held = b.get("_obj_held")
	return held if held != null and held != Vector3.INF else Vector3.ZERO
