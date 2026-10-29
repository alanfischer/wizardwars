extends SceneTree
## ww_2fort: did the four injected ammo backpacks survive the BSP conversion, and did they
## land where they were asked for? Dumps each pack's entity keys and its world position.
##
## Reads the converted map out of the runtime cache, so run the game (or ./run.sh) once
## after re-running ww_2fort_ammo.py, or the cache still holds the old map.
##
## Run: Godot --headless -s tools/probe_2fort_ammo.gd

func _initialize() -> void:
	var cached := "user://resources/maps/ww_2fort.scn"
	if not FileAccess.file_exists(cached):
		print("no converted map at %s -- run the game or ./run.sh once first" % cached)
		quit(1)
		return
	var map := (load(cached) as PackedScene).instantiate()
	get_root().add_child(map)

	var found := 0
	for n in map.find_children("*", "", true, false):
		var e: Dictionary = n.get_meta("entity", {}) if n.has_meta("entity") else {}
		if String(e.get("targetname", "")) != "ww_ammo_pack":
			continue
		found += 1
		print("pack %d  origin=%-18s pos=%-28s mana=%d+%d+%d+%d grenades=%d+%d g_a=%s g_e=%s state=%s wait=%s team=%s mdl=%s" % [
			found, e.get("origin", "?"), str(n.position),
			int(e.get("ammo_shells", 0)), int(e.get("ammo_nails", 0)),
			int(e.get("ammo_cells", 0)), int(e.get("ammo_rockets", 0)),
			int(e.get("no_grenades_1", 0)), int(e.get("no_grenades_2", 0)),
			e.get("goal_activation", "-"), e.get("goal_effects", "-"),
			e.get("goal_state", "-"), e.get("wait", "-"),
			e.get("team_no", "any"), e.get("mdl", "-")])
	print("packs found: %d (expected 4)" % found)
	quit(0 if found == 4 else 1)
