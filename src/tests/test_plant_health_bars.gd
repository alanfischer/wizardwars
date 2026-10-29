extends "res://src/tests/test_base.gd"
## The persistent-plant HUD entries are health bars, not on/off labels: the owner
## needs to see a thornplant being chewed before it dies. A beanstalk reports its
## WEAKEST segment, because any segment dying takes the whole chain down.

const BeanstalkScript = preload("res://src/monsters/beanstalk.gd")


func _bar(hud: HUD, kind: String) -> HUD.BarWidget:
	return hud._plant_bars[kind]


func test_bars_hidden_until_planted() -> void:
	var hud := _make_hud()
	for kind in ["beanstalk", "thornplant"]:
		var bar := _bar(hud, kind)
		assert_false(bar.root.visible, "%s bar starts hidden" % kind)
	hud.queue_free()


func test_bar_fills_to_health_ratio() -> void:
	var hud := _make_hud()
	hud.set_plant_indicator("thornplant", true, 75.0, 300.0)
	var bar := _bar(hud, "thornplant")
	assert_true(bar.root.visible, "planted thornplant shows its bar")
	assert_almost_eq(bar.fill.anchor_right, 0.25, 0.001, "quarter health, quarter bar")
	assert_eq(bar.label.text, "Thornplant 75", "label carries the current HP")
	hud.queue_free()


func test_bar_hides_when_plant_dies() -> void:
	var hud := _make_hud()
	hud.set_plant_indicator("beanstalk", true, 80.0, 80.0)
	hud.set_plant_indicator("beanstalk", false)
	assert_false(_bar(hud, "beanstalk").root.visible, "destroyed beanstalk clears its bar")
	hud.queue_free()


func test_missing_max_health_fills_bar() -> void:
	var hud := _make_hud()
	hud.set_plant_indicator("beanstalk", true, 40.0, 0.0)
	assert_almost_eq(_bar(hud, "beanstalk").fill.anchor_right, 1.0, 0.001,
		"a zero max can't divide the bar to NaN")
	hud.queue_free()


func test_unknown_kind_is_inert() -> void:
	var hud := _make_hud()
	hud.set_plant_indicator("cockleburr", true, 10.0, 10.0)
	hud.queue_free()


func test_chain_reports_weakest_segment() -> void:
	var root: Beanstalk = BeanstalkScript.new()
	var top: Beanstalk = BeanstalkScript.new()
	for seg in [root, top]:
		seg.setup({}, true)
	root.next_segment = top
	top.prev_segment = root

	assert_eq(root.chain_health(), Vector2(Beanstalk.HEALTH, Beanstalk.HEALTH),
		"a fresh chain is at full health")
	top.take_damage(30.0)
	assert_eq(root.chain_health(), Vector2(Beanstalk.HEALTH - 30.0, Beanstalk.HEALTH),
		"damage anywhere in the chain is what the owner sees")
	# Asked from the damaged segment, the walk still starts at the root.
	assert_eq(top.chain_health(), root.chain_health(), "same answer from either end")

	root.free()
	top.free()
