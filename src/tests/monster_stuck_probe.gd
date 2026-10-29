extends Node
## Where does a siege wave get stuck? Runs a siege, watches every monster, and reports each one
## that stops moving for good — with what the physics world says about the spot it stopped in.
##
##   godot --headless --path . res://src/tests/monster_stuck_probe.tscn -- --server --map ww_2fort
##
## Written for the report that skeletons jam in ww_2fort's base entryway "floating up a foot or so
## and somewhat on the wall". A monster leaning on a wall is ordinary and MonsterNav peels it off;
## one that is OFF THE FLOOR and inside solid is a different failure, and only the hull can say
## which of the two a given stall is.

const SECONDS := 90.0
const SAMPLE := 0.25
const STUCK_WINDOW := 4.0        # moved less than STUCK_DIST over this long
const STUCK_DIST := 0.4
const LIVE_TARGET := 8           # keep this many walking

var _stuck_reports := 0
var _dossier_done := false
var _track := {}                 # instance id -> {node, hist: Array[Vector3], reported: bool}


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var tree := get_tree()
	var main: Node = load("res://src/main.tscn").instantiate()
	tree.root.add_child(main)
	tree.current_scene = main
	var waited := 0.0
	while waited < 240.0 and not bool(main.get("_game_active")):
		await tree.create_timer(1.0).timeout
		waited += 1.0
	var map_name := str(main.get("_current_map_name"))
	if not bool(main.get("_game_active")):
		print("STUCK %-16s FAIL  map never loaded" % map_name)
		tree.quit(1)
		return
	var err := SiegeSystem.begin()
	if not err.is_empty():
		print("STUCK %-16s FAIL  %s" % [map_name, err])
		tree.quit(1)
		return
	var spot := SiegeSystem.objective_position()
	print("STUCK %-16s altar walk-to %6.1f,%6.1f,%6.1f  entries %d" % [
			map_name, spot.x, spot.y, spot.z, SiegeSystem.entries.size()])

	var kind := OS.get_environment("SIEGE_MONSTER") if OS.has_environment("SIEGE_MONSTER") \
			else SiegeSystem.SKELETON
	var t := 0.0
	var next_census := 10.0
	var window := int(STUCK_WINDOW / SAMPLE)
	while t < SECONDS:
		await tree.create_timer(SAMPLE).timeout
		t += SAMPLE
		var live := 0
		for n in SiegeSystem._live:
			if is_instance_valid(n) and not bool(n.get("is_dead")):
				live += 1
		for _i in maxi(0, LIVE_TARGET - live):
			SiegeSystem.spawn_wave(1, kind)
		for n in SiegeSystem._live:
			if not is_instance_valid(n) or bool(n.get("is_dead")):
				continue
			var id: int = n.get_instance_id()
			var rec: Dictionary = _track.get(id, {})
			if rec.is_empty():
				rec = {"hist": [], "reported": false, "t0": t}
				_track[id] = rec
			var hist: Array = rec["hist"]
			hist.append(n.global_position)
			if hist.size() > window:
				hist.pop_front()
			if rec["reported"] or hist.size() < window:
				continue
			if hist[0].distance_to(hist[-1]) > STUCK_DIST:
				continue
			if n.global_position.distance_to(spot) < 6.0:
				continue                      # arrived; standing at the altar is not stuck
			rec["reported"] = true
			_stuck_reports += 1
			_report(n, t, spot)
			if not _dossier_done:
				_dossier_done = true
				await _dossier(n)
		if t >= next_census:
			next_census = t + 10.0
			_census(t)
	# The number this probe exists for: monsters that ended the run frozen off the floor.
	# Counted at the end rather than summed over reports, because a monster frozen at t=30
	# and still frozen at t=90 is one loss, not two.
	var frozen := 0
	var floating := 0
	for n in SiegeSystem._live:
		if not is_instance_valid(n) or bool(n.get("is_dead")):
			continue
		var walk = n.get("_walk")
		var still: bool = n.velocity.length() < 0.1
		var off_floor: bool = _drop(n) > 0.3 and not (walk and walk.in_water)
		if off_floor:
			floating += 1
			if still:
				frozen += 1
	print("STUCK %-16s done  tracked %d  live %d  FROZEN-FLOATERS %d  (off-floor %d)  reports %d"
			% [map_name, _track.size(), SiegeSystem._live.size(), frozen, floating,
			_stuck_reports])
	tree.quit(0)


## Every live monster's height above the floor under it. A float that only happens where they
## jam is a map spot; one they all carry is the kernel.
func _census(t: float) -> void:
	var out := PackedStringArray()
	for n in SiegeSystem._live:
		if not is_instance_valid(n) or bool(n.get("is_dead")):
			continue
		var walk = n.get("_walk")
		out.append("%.2f%s%s" % [_drop(n), "f" if walk and walk.state.on_floor else "-",
				"w" if walk and walk.in_water else ""])
	print("  CENSUS t=%4.0fs  feet-above-floor: %s" % [t, " ".join(out)])


## Metres from the monster's feet down to the first world/clip surface under them.
func _drop(n: Node3D) -> float:
	var pos := n.global_position
	var ray := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.05,
			pos + Vector3.DOWN * 4.0, GameConsts.MASK_WORLD | GameConsts.MASK_CLIP)
	var hit := n.get_world_3d().direct_space_state.intersect_ray(ray)
	return (pos.y + 0.05 - float(hit.position.y)) if not hit.is_empty() else INF


func _report(n: Node3D, t: float, spot: Vector3) -> void:
	var pos := n.global_position
	var space := n.get_world_3d().direct_space_state
	var walk = n.get("_walk")
	var nav = n.get("_nav")
	var in_water := bool(walk.in_water) if walk else false
	var on_floor := bool(walk.state.on_floor) if walk else false
	var vel: Vector3 = n.velocity

	# How far its feet are off whatever is under them.
	var ray := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.05,
			pos + Vector3.DOWN * 4.0, GameConsts.MASK_WORLD | GameConsts.MASK_CLIP)
	var hit := space.intersect_ray(ray)
	var drop := (pos.y + 0.05 - float(hit.position.y)) if not hit.is_empty() else INF

	# What its own hull overlaps right now, and how deep. recovery_as_collision reports the
	# penetration Godot would push out of, which is the thing that says "inside solid".
	var mp := PhysicsTestMotionParameters3D.new()
	mp.from = n.global_transform
	mp.motion = Vector3.ZERO
	mp.margin = n.safe_margin
	mp.recovery_as_collision = true
	mp.max_collisions = 6
	var mr := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(n.get_rid(), mp, mr)
	var depths := PackedStringArray()
	for i in mr.get_collision_count():
		depths.append("%.3f@%s %s" % [mr.get_collision_depth(i),
				_norm_str(mr.get_collision_normal(i)), _who(mr.get_collider(i))])

	# Can it move at all? Sweep its own hull a step in each compass direction and down.
	var free := PackedStringArray()
	for probe in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT,
			Vector3.DOWN, Vector3.UP]:
		mp.motion = probe * 0.5
		mp.recovery_as_collision = false
		PhysicsServer3D.body_test_motion(n.get_rid(), mp, mr)
		var got := mr.get_travel().length()
		var who := _who(mr.get_collider(0)) if mr.get_collision_count() > 0 else "-"
		free.append("%s:%.2f/%s" % [_dir_name(probe), got, who])

	# Where the PHYSICS SERVER thinks it is, against where the node says it is. A kinematic
	# body whose two transforms disagree is blocked by geometry nobody can see at the node's
	# position, which is exactly what a stuck monster looks like from the outside.
	var srv: Transform3D = PhysicsServer3D.body_get_state(n.get_rid(),
			PhysicsServer3D.BODY_STATE_TRANSFORM)
	var skew := srv.origin - pos
	var wp = nav.waypoint() if nav else Vector3.INF
	print("  STUCK-AT %9.4f,%9.4f,%9.4f  t=%4.0fs  %s  floor=%s  drop=%s  vel=%.2f  to-altar %.0fm  wp %s"
			% [pos.x, pos.y, pos.z, t, "water" if in_water else "dry ",
			"yes" if on_floor else "NO ",
			("%.2fm" % drop) if drop < INF else "none",
			vel.length(), pos.distance_to(spot),
			("%.1f,%.1f,%.1f" % [wp.x, wp.y, wp.z]) if wp != Vector3.INF else "-"])
	print("           overlap [%s]  room [%s]" % [", ".join(depths), " ".join(free)])
	print("           server-origin %6.2f,%6.2f,%6.2f  skew %.3f,%.3f,%.3f  test_move(down .6)=%s" % [
			srv.origin.x, srv.origin.y, srv.origin.z, skew.x, skew.y, skew.z,
			n.test_move(n.global_transform, Vector3.DOWN * 0.6)])


static func _norm_str(v: Vector3) -> String:
	return "%+.1f,%+.1f,%+.1f" % [v.x, v.y, v.z]


## Everything about one stuck monster, taking the time to do it properly: what shapes it has,
## what a settled twin of it says about the spot, and whether a nudge frees it.
func _dossier(n: CharacterBody3D) -> void:
	var kids := PackedStringArray()
	for c in n.get_children():
		kids.append("%s<%s>" % [c.name, c.get_class()])
	var src: CollisionShape3D = n.get_node_or_null("CollisionShape3D")
	print("  DOSSIER children: %s" % " ".join(kids))
	print("           node 'CollisionShape3D' -> %s  shape=%s" % [
			"found" if src else "MISSING",
			str(src.shape) if src else "-"])

	# A twin with a hull built from scratch, given a physics frame to enter the world before
	# it is asked anything — a body added this frame has not reached the simulator yet and
	# reads free in every direction, which is an answer about nothing.
	var twin := CharacterBody3D.new()
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.4
	cyl.height = 1.8
	col.shape = cyl
	col.position.y = 0.9
	twin.add_child(col)
	twin.collision_layer = 0
	twin.collision_mask = n.collision_mask
	get_tree().current_scene.add_child(twin)
	twin.global_transform = n.global_transform
	await get_tree().physics_frame
	print("           settled twin room [%s]" % _room(twin, n.global_transform))
	twin.queue_free()

	# Where, around here, could this hull stand at all? One row per height, one column per
	# lateral offset: the shape of the pocket it is in.
	print("           escape map (rows dy, cols dx/dz; . = free to fall, X = cannot move)")
	for dy in [0.0, -0.1, -0.2, -0.3, -0.45, -0.5]:
		var row := PackedStringArray()
		for off in [Vector3.ZERO, Vector3(0.05, 0, 0), Vector3(-0.05, 0, 0),
				Vector3(0, 0, 0.05), Vector3(0, 0, -0.05), Vector3(0.2, 0, 0),
				Vector3(-0.2, 0, 0), Vector3(0, 0, 0.2), Vector3(0, 0, -0.2)]:
			var t := n.global_transform
			t.origin += off + Vector3(0.0, dy, 0.0)
			var mp2 := PhysicsTestMotionParameters3D.new()
			mp2.from = t
			mp2.margin = n.safe_margin
			var mr2 := PhysicsTestMotionResult3D.new()
			mp2.motion = Vector3.DOWN * 0.3
			PhysicsServer3D.body_test_motion(n.get_rid(), mp2, mr2)
			row.append("%.2f" % mr2.get_travel().length())
		print("             dy%+.2f  %s" % [dy, " ".join(row)])

	# Does a hair of a nudge free the monster itself? A body that is merely sitting exactly on
	# a plane comes loose; one in a real pocket does not.
	var before := n.global_transform
	for nudge in [Vector3(0.0, 0.02, 0.0), Vector3(0.05, 0.0, 0.0), Vector3(0.0, 0.2, 0.0)]:
		var t := before
		t.origin += nudge
		print("           nudge %+.2f,%+.2f,%+.2f room [%s]" % [nudge.x, nudge.y, nudge.z,
				_room(n, t)])


## Six 0.5 m sweeps from `from`, as travel distances.
func _room(body: CharacterBody3D, from: Transform3D) -> String:
	var mp := PhysicsTestMotionParameters3D.new()
	mp.from = from
	mp.margin = body.safe_margin
	mp.max_collisions = 4
	var mr := PhysicsTestMotionResult3D.new()
	var out := PackedStringArray()
	for probe in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT,
			Vector3.DOWN, Vector3.UP]:
		mp.motion = probe * 0.5
		PhysicsServer3D.body_test_motion(body.get_rid(), mp, mr)
		out.append("%s:%.2f" % [_dir_name(probe), mr.get_travel().length()])
	return " ".join(out)


## Who is that? Name, class and layers — "the BSP" and "a func_wall" are different answers.
static func _who(obj: Object) -> String:
	if obj == null:
		return "null"
	var n := obj as Node
	if n == null:
		return obj.get_class()
	var layer := int(n.get("collision_layer")) if "collision_layer" in n else -1
	var tags := PackedStringArray()
	for meta in n.get_meta_list():
		tags.append(str(meta))
	return "%s<%s>L%d%s" % [n.name, n.get_class(), layer,
			("{" + ",".join(tags) + "}") if tags.size() > 0 else ""]


static func _dir_name(v: Vector3) -> String:
	if v.y > 0.5: return "up"
	if v.y < -0.5: return "down"
	if v.z < -0.5: return "fwd"
	if v.z > 0.5: return "back"
	if v.x < -0.5: return "left"
	return "right"
