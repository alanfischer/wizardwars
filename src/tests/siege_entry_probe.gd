extends Node
## The entry points a wave is brought in at: is the ground under them where the derivation thinks
## it is? Every monster on ww_2fort was found 9.4 m BELOW its entry within one second of spawning.
##
##   godot --headless --path . res://src/tests/siege_entry_probe.tscn -- --server --map ww_2fort
##
## Companion to siege_arena_probe, which asks whether a map can host a siege at all; this one asks
## whether the entries it derived are ground a monster can be put down on.

func _ready() -> void: _run.call_deferred()

func _run() -> void:
	var tree := get_tree()
	var main: Node = load("res://src/main.tscn").instantiate()
	tree.root.add_child(main)
	tree.current_scene = main
	var waited := 0.0
	while waited < 240.0 and not bool(main.get("_game_active")):
		await tree.create_timer(1.0).timeout
		waited += 1.0
	var err := SiegeSystem.begin()
	if not err.is_empty():
		print("ENTRY no siege: %s" % err); tree.quit(1); return
	var g = MonsterNav.graph(main)
	var goal: Vector3 = SiegeSystem.objective_position()
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state

	print("ENTRY %s  %d entries, goal %.1f,%.1f,%.1f"
			% [str(main.get("_current_map_name")), SiegeSystem.entries.size(), goal.x, goal.y, goal.z])
	for i in SiegeSystem.entries.size():
		var e: Vector3 = SiegeSystem.entries[i]
		# How far is the floor below where a monster is put down?
		var q := PhysicsRayQueryParameters3D.create(e + Vector3.UP * 0.3,
				e + Vector3.DOWN * 40.0, GameConsts.MASK_WORLD_AND_CLIP)
		var hit: Dictionary = space.intersect_ray(q)
		var drop := (e.y + 0.3) - float(hit.position.y) if not hit.is_empty() else INF
		# And is the FLOOR routable, as against the spawn point floating above it?
		var floor_pos: Vector3 = hit.position if not hit.is_empty() else e
		print("  entry %2d  %7.1f,%6.1f,%7.1f  drop %5.1fm  entry->goal %3d hops  floor->goal %3d hops"
				% [i, e.x, e.y, e.z, drop, g.path_ids(e, goal).size(),
				g.path_ids(floor_pos + Vector3.UP * 0.1, goal).size()])
	tree.quit(0)
