extends "res://src/tests/test_base.gd"
## Where the siege altar's crystal ends up once it is placed. The model's origin is neither its
## feet nor its middle — the mesh starts 0.4 m up and reaches 3.1 m — so an altar dropped at a
## spot and left alone stands above that spot rather than on it, and in a low room it comes out
## through the ceiling. ww_ravine's grail room is three metres floor to ceiling and did exactly
## that.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const SiegeAltarScript = preload("res://src/entities/siege_altar.gd")

const ARENA := Vector3(-260.0, 90.0, 0.0)  # clear of map geometry, and of the other suites'


## Mirrors main._spawn_dyn_entity: setup() first, add_child() after.
func _altar(headroom: float) -> SiegeAltar:
	var altar: SiegeAltar = SiegeAltarScript.new()
	altar.setup({"position": ARENA, "headroom": headroom, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(altar)
	_keep(altar)
	return altar


## The drawn crystal in world space. The altar's own light is a VisualInstance3D too, and its
## range dwarfs the model — ask only the meshes.
func _drawn(altar: Node3D) -> AABB:
	var out := AABB()
	for n in altar.find_children("*", "MeshInstance3D", true, false):
		var mesh := n as MeshInstance3D
		var box: AABB = mesh.global_transform * mesh.get_aabb()
		out = box if out.size == Vector3.ZERO else out.merge(box)
	return out


func test_the_crystal_stands_on_the_spot_not_above_it() -> void:
	var altar := _altar(INF)
	var drawn := _drawn(altar)
	assert_gt(drawn.size.y, 0.0, "the altar should have drawn something to measure")
	assert_almost_eq(drawn.position.y, ARENA.y, 0.02,
		"the crystal's foot belongs at the spot the altar was placed on")
	assert_almost_eq(float(altar.get("_scale")), 1.0, 0.001,
		"nothing overhead means nothing to shrink for")


func test_a_low_ceiling_shrinks_the_crystal_to_fit() -> void:
	var altar := _altar(2.0)
	var drawn := _drawn(altar)
	assert_lt(drawn.end.y, ARENA.y + 2.0,
		"the crystal must stay under the ceiling the host measured")
	assert_almost_eq(drawn.position.y, ARENA.y, 0.02,
		"shrinking must not lift the crystal off the floor")


func test_a_crawlspace_does_not_shrink_it_to_nothing() -> void:
	var altar := _altar(0.3)
	var drawn := _drawn(altar)
	assert_gt(drawn.size.y, 1.0,
		"an altar too small to see is worse than one whose tip shows through a ceiling")
	assert_almost_eq(float(altar.get("_scale")), SiegeAltar.MIN_SCALE, 0.001,
		"the shrink is clamped, not unbounded")
