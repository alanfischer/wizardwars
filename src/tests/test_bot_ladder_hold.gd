extends "res://src/tests/test_base.gd"
## BotBrain.hold_climb_axis — the rule that keeps a bot climbing when its route has lost the
## ladder. Re-pathing from inside a shaft picks the nearest waypoint to the bot, and halfway up
## ww_ravine's 12m ladder that is the LANDING at the top: the route then never visits the ladder
## node, the bot has no climb to drive, and it leans on the wall two metres under the floor.
## Measured before this rule: jams of 29-53s there every match, and one of 456s.

const BotBrain = preload("res://src/bot/bot_brain.gd")

# The real ww_ravine shaft: rungs on a face at x 4.60 (so the outward normal is -X), the bot
# pressed against it, and the landing it is heading for at y 43.42.
const NORMAL := Vector3(-1.0, 0.0, 0.0)
const LANDING := Vector3(3.59, 43.42, -1.06)


func _run_tests() -> void:
	_current_test = "climbs_while_the_landing_is_above"
	test_climbs_while_the_landing_is_above()
	_current_test = "aims_above_the_landing_and_into_the_rungs"
	test_aims_above_the_landing_and_into_the_rungs()
	_current_test = "keeps_climbing_until_clear_above_the_landing"
	test_keeps_climbing_until_clear_above_the_landing()
	_current_test = "releases_once_clear_above_the_landing"
	test_releases_once_clear_above_the_landing()
	_current_test = "off_a_ladder_it_does_not_apply"
	test_off_a_ladder_it_does_not_apply()
	_current_test = "free_climb_volumes_are_left_alone"
	test_free_climb_volumes_are_left_alone()
	_current_test = "climbs_the_remembered_column"
	test_climbs_the_remembered_column()
	_current_test = "a_distant_axis_is_ignored"
	test_a_distant_axis_is_ignored()


func test_climbs_while_the_landing_is_above() -> void:
	# Where the bots actually hung: 2.1 m under the floor, pressed on the rungs.
	var axis := BotBrain.hold_climb_axis(Vector3(4.24, 41.32, 0.0), LANDING, NORMAL)
	assert_true(axis != Vector3.INF, "mid-shaft with the landing overhead should climb")
	assert_gt(axis.y, 41.32, "the climb target must be above the bot")


func test_aims_above_the_landing_and_into_the_rungs() -> void:
	var bot := Vector3(4.24, 41.32, 0.0)
	var axis := BotBrain.hold_climb_axis(bot, LANDING, NORMAL)
	assert_gt(axis.y, LANDING.y, "must climb clear of the landing, not stop level with it")
	# -X normal means the rungs are at +X: the aim leans that way so the climb keeps contact.
	assert_gt(axis.x, bot.x, "aim should lean into the rungs")
	assert_lt(absf(axis.x - bot.x), 0.75, "but only a nudge — it is a climb, not a walk")
	assert_true(is_equal_approx(axis.z, bot.z), "no sideways drift out of the shaft")


func test_keeps_climbing_until_clear_above_the_landing() -> void:
	# Level with the floor is NOT enough: the hull then meets the slab's vertical face when it
	# steps off. Measured as a 417s hang four centimetres low.
	for y in [43.38, LANDING.y, LANDING.y + 0.1]:
		assert_true(BotBrain.hold_climb_axis(Vector3(4.24, y, 0.0), LANDING, NORMAL) != Vector3.INF,
				"at y %.2f the bot is not yet clear of the floor edge" % y)


func test_releases_once_clear_above_the_landing() -> void:
	# Clear of it, the climb must end, or the bot rides into the ceiling instead of stepping off.
	for y in [LANDING.y + 0.35, 44.2]:
		var axis := BotBrain.hold_climb_axis(Vector3(4.24, y, 0.0), LANDING, NORMAL)
		assert_true(axis == Vector3.INF, "at y %.2f the landing is steppable; stop climbing" % y)


func test_off_a_ladder_it_does_not_apply() -> void:
	# No ladder under the hands: a node overhead is a jump or a ramp, not a climb.
	assert_true(BotBrain.hold_climb_axis(Vector3(4.24, 41.32, 0.0), LANDING, Vector3.ZERO)
			== Vector3.INF, "nothing to climb without a ladder")


func test_free_climb_volumes_are_left_alone() -> void:
	# WW's mappers used func_ladder for whole rock faces; those report a zero normal and are
	# flown, not climbed (see FuncLadder.FREECLIMB_THICKNESS).
	assert_true(BotBrain.hold_climb_axis(Vector3(0.0, 10.0, 0.0), Vector3(2.0, 20.0, 2.0),
			Vector3.ZERO) == Vector3.INF, "free-climb volumes keep their own steering")


## The shaft ww_ravine's ladder rises through is barely wider than the hull: climbing straight up
## from wherever the bot drifted to jams its shoulder under the floor at the top (measured: a 125s
## hang at y 43.31, four centimetres under the landing). Given the ladder's own axis it climbs that
## column instead.
func test_climbs_the_remembered_column() -> void:
	var drifted := Vector3(4.29, 41.0, 0.40)
	var axis := Vector3(4.65, 44.90, 0.0)          # the real FL_LADDER node for this shaft
	var got := BotBrain.hold_climb_axis(drifted, LANDING, NORMAL, axis)
	assert_lt(absf(got.z - axis.z), absf(drifted.z - axis.z),
			"the climb should pull back toward the shaft column, not hold the drift")


## But only when it is the shaft we are actually in — a ladder remembered from elsewhere on the
## map must not drag the climb sideways.
func test_a_distant_axis_is_ignored() -> void:
	var bot := Vector3(4.29, 41.0, 0.40)
	var far_axis := Vector3(40.0, 44.9, 30.0)
	var got := BotBrain.hold_climb_axis(bot, LANDING, NORMAL, far_axis)
	assert_true(is_equal_approx(got.z, bot.z), "a ladder 40m away is not the one under our hands")
