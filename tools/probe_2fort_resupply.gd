extends Node
## Converts ww_2fort from the shipped .bsp and reports every resupply trigger's wait key.
## Run as a SCENE (not -s) so the autoloads MapConverter leans on are registered:
##   Godot --headless --path . tools/probe_2fort_resupply.tscn

func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var mc := MapConverter.new()
	if not mc.convert("ww_2fort"):
		print("CONVERT FAILED")
		get_tree().quit(1)
		return
	var map := (load("user://resources/maps/ww_2fort.scn") as PackedScene).instantiate()
	add_child(map)
	var seen := 0
	for n in map.find_children("*", "", true, false):
		var e: Dictionary = n.get_meta("entity", {}) if n.has_meta("entity") else {}
		if String(e.get("classname", "")) != "trigger_multiple":
			continue
		var tgt := String(e.get("target", ""))
		if not tgt.contains("resupply"):
			continue
		seen += 1
		print("%-18s wait=%-6s team_no=%s" % [tgt, e.get("wait", "-"), e.get("team_no", "-")])
	print("resupply triggers: %d (expected 12)" % seen)
	get_tree().quit(0 if seen == 12 else 1)
