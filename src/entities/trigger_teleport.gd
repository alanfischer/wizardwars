class_name TriggerTeleport
extends EntityBase
# trigger_teleport — area that teleports the player to an info_teleport_destination.

var _target_key: String


func _ready() -> void:
	super()
	_target_key = ent.get("target", "")

	var area := GoldSrcEntity.use_volume_as_trigger(self, GameConsts.MASK_PLAYER)
	area.body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if not body is CharacterBody3D:
		return
	if not body.is_alive:
		return
	if _is_network_client():
		return
	if _target_key.is_empty():
		return
	var destinations := TriggerSystem.get_nodes(_target_key)
	if destinations.is_empty():
		push_warning("trigger_teleport: destination '%s' not found" % _target_key)
		return
	var dest: Node3D = destinations[0]
	# Deferred: moving a physics body inside a body_entered callback re-enters the physics
	# server mid-step and corrupts its iteration (Linux segfault under load). Same guard the
	# item_tfgoal grab path uses.
	body.call_deferred("teleport_to", dest.global_position, dest.rotation.y)
