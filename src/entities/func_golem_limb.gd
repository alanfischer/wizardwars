class_name FuncGolemLimb
extends EntityBase
# func_golem_leftleg, rightleg, leftarm, rightarm — golem limb pieces.
# Managed by func_golem_body. Each limb is a brush entity that moves with the body.

var _limb_type := ""  # "leftleg", "rightleg", "leftarm", "rightarm"


func _ready() -> void:
	super()
	var classname: String = ent.get("classname", "")
	if "leftleg" in classname:
		_limb_type = "leftleg"
	elif "rightleg" in classname:
		_limb_type = "rightleg"
	elif "leftarm" in classname:
		_limb_type = "leftarm"
	elif "rightarm" in classname:
		_limb_type = "rightarm"

	# Registered as a mover so the golem_interp=off path (per-limb interp) works. In the
	# default golem_interp=on mode the body suppresses this limb's stream and drives it
	# locally instead (see FuncGolemBody._apply_interp_mode / _client_animate).
	_register_for_sync()


## Called by func_golem_body to identify this limb.
func _get_golem_type() -> String:
	return _limb_type


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	pass  # Limbs are controlled by the body, not triggers
