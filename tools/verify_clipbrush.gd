extends SceneTree
## Fast check: the engine's own GoldSrcBSP parser reads the injected
## info_clipbrush entities from the edited ww_golem.bsp (no mesh build).


func _initialize() -> void:
	if not ClassDB.class_exists(&"GoldSrcBSP"):
		printerr("GoldSrcBSP plugin not available")
		quit(1)
		return
	var bsp = ClassDB.instantiate(&"GoldSrcBSP")
	bsp.set_scale_factor(GameConsts.SCALE_FACTOR)
	var path := "res://maps/ww_golem.bsp"
	if bsp.has_method("load_bsp"):
		bsp.load_bsp(path)

	var clips: Array = []
	for e in bsp.get_entities():
		if e.get("classname", "") == "info_clipbrush":
			clips.append(e)
	print("engine parsed info_clipbrush entities: %d" % clips.size())
	if clips.is_empty():
		printerr("FAIL: parser saw no clipbrush entities (injection unreadable?)")
		quit(1)
		return
	var rotated := 0
	for e in clips:
		if e.has("angles"):
			rotated += 1
	var sample: Dictionary = clips[0]
	print("  sample: origin='%s' size='%s' angles='%s'" % [
		sample.get("origin", ""), sample.get("size", ""), sample.get("angles", "(none)")])
	print("  rotated boxes: %d / %d" % [rotated, clips.size()])
	print("OK: engine reads injected clip entities")
	quit(0)
