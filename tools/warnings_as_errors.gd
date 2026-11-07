extends SceneTree
## Prints an override.cfg that raises every GDScript warning left at Warn to Error, for
## run_tests.sh. Godot prints no warnings in a headless run; as errors they fail the load.


func _init() -> void:
	print("[debug]")
	for p in ProjectSettings.get_property_list():
		var name: String = p.name
		if name.begins_with("debug/gdscript/warnings/") and typeof(ProjectSettings.get_setting(name)) == TYPE_INT \
				and ProjectSettings.get_setting(name) == 1:
			print("%s=2" % name.trim_prefix("debug/"))
	quit()
