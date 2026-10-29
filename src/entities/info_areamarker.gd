class_name InfoAreaMarker
extends EntityBase
# info_areamarker — named area marker used by TFC goal system.

const GROUP := &"area_markers"

var area_team: int = 0


func _ready() -> void:
	super()
	area_team = parse_int(ent, "team_no", 0)
	add_to_group(GROUP)


## Team chat names the marker nearest the sender, as the original's Host_Say did. "" when the map
## has none.
static func nearest_name(tree: SceneTree, pos: Vector3) -> String:
	var best: InfoAreaMarker = null
	for m: InfoAreaMarker in tree.get_nodes_in_group(GROUP):
		if best == null or pos.distance_squared_to(m.global_position) < pos.distance_squared_to(best.global_position):
			best = m
	return best.ent.get("netname", "") if best else ""
