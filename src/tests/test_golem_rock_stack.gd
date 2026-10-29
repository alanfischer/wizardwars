extends "res://src/tests/test_base.gd"
## ww_golem's stacked-rock mechanic, using the REAL entity scripts. Rocks break in dependency
## pairs: a base breaks unconditionally and sets a global flag, the rock on top only breaks
## `if(base==1)`. trigger_golem must re-fire on every clap, or a one-shot trigger lets the top
## rock's guard evaluate before the base broke and it never re-fires. The test reproduces the
## ordering by clapping the top trigger first, modeling the map's 0.1s base-delay relay.

const PotatoCScript = preload("res://src/entities/potatoc_entity.gd")
const TriggerGolemScript = preload("res://src/entities/trigger_golem.gd")


## Minimal func_breakable stand-in: records whether it was turned OFF.
class FakeBreakable:
	extends Node3D
	var broken := false
	func trigger(_activator: Node, type: int) -> void:
		if type == TriggerSystem.Type.OFF:
			broken = true


func _add(node: Node, entity: Dictionary) -> Node:
	node.set_meta("entity", entity)
	_root().add_child(node)
	return node


func _make_breakable(tname: String) -> FakeBreakable:
	var b := FakeBreakable.new()
	_root().add_child(b)
	TriggerSystem.register(tname, b)
	return b


## One dependency pair wired like the map (base potatoc fires directly — the
## real map's 0.1s relay only affects ordering, which the test controls).
## Returns [base_breakable, top_breakable, base_golem_trig, top_golem_trig].
func _build_pair(base: String, top: String) -> Array:
	var base_bk := _make_breakable(base)
	var top_bk := _make_breakable(top)
	_add(PotatoCScript.new(), {
		"classname": "potatoc", "targetname": base + "off",
		"globals": base + ";", "code": "[TurnOff('%s');%s=1;]" % [base, base]})
	_add(PotatoCScript.new(), {
		"classname": "potatoc", "targetname": top + "off",
		"code": "[if(%s==1)[TurnOff('%s');]]" % [base, top]})
	var base_trig := _add(TriggerGolemScript.new(), {
		"classname": "trigger_golem", "target": base + "off"})
	var top_trig := _add(TriggerGolemScript.new(), {
		"classname": "trigger_golem", "target": top + "off"})
	return [base_bk, top_bk, base_trig, top_trig]


func test_base_rock_breaks() -> void:
	PotatoC.global_vars.clear()
	var pair := _build_pair("srock1", "srock2")
	var base_bk: FakeBreakable = pair[0]
	pair[2].golem_activate(null)  # clap the base trigger
	assert_true(base_bk.broken, "base rock breaks unconditionally on a clap")
	for n in pair: n.queue_free()


func test_stacked_rock_breaks_on_later_clap() -> void:
	PotatoC.global_vars.clear()
	var pair := _build_pair("srock3", "srock4")
	var top_bk: FakeBreakable = pair[1]
	var base_trig: Node = pair[2]
	var top_trig: Node = pair[3]

	# One clap fires both triggers. The relay delays the base, so the top
	# evaluates first (base still standing) — model that by clapping top first.
	top_trig.golem_activate(null)
	base_trig.golem_activate(null)
	assert_false(top_bk.broken, "stacked rock stays up on the clap that breaks its base")
	assert_eq(PotatoC.global_vars.get("srock3"), 1, "base broke and set its global flag")

	# Second clap: the trigger is no longer one-shot, so the stacked rock
	# re-evaluates its guard (base==1 now) and breaks.
	top_trig.golem_activate(null)
	assert_true(top_bk.broken, "stacked rock breaks on the next clap once its base is gone")

	for n in pair: n.queue_free()
