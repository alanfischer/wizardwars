class_name FuncGolemControls
extends EntityBase
# func_golem_controls_forward, _left, _right, _attack — cockpit buttons.
# When a player presses +use on these, they signal the golem body.
# The control type is determined from the classname.

var _control_type := ""  # "forward", "left", "right", "attack"
var _golem_body: Node3D  # resolved reference to func_golem_body


func _ready() -> void:
	super()
	var classname: String = ent.get("classname", "")
	if "forward" in classname:
		_control_type = "forward"
	elif "left" in classname:
		_control_type = "left"
	elif "right" in classname:
		_control_type = "right"
	elif "attack" in classname:
		_control_type = "attack"

	# Registered as a mover (golem_interp=off path). In golem_interp=on the body suppresses
	# this stream and drives the control locally. +use routes by node path regardless.
	_register_for_sync()
	call_deferred("_resolve_body")


func _resolve_body() -> void:
	for node in get_tree().get_nodes_in_group("golem_body"):
		_golem_body = node
		break
	if not _golem_body:
		var nodes := TriggerSystem.get_nodes("golem")  # fallback: targetname "golem"
		if not nodes.is_empty():
			_golem_body = nodes[0]


func is_player_usable() -> bool:
	return true


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	if _is_network_client():
		return
	if not _golem_body:
		Log.info("Golem control '%s': no golem body found!" % _control_type)
		return
	Log.info("Golem control '%s' triggered" % _control_type)
	match _control_type:
		"forward":
			_golem_body.golem_walk()
		"left":
			_golem_body.golem_turn_left()
		"right":
			_golem_body.golem_turn_right()
		"attack":
			_golem_body.golem_attack(_activator)
