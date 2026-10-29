extends Node

enum Type { OFF, ON, TOGGLE }

# targetname -> Array[Node]
var _registry: Dictionary = {}


## Idempotent per (name, node): TF goals register from two call sites, and a duplicate
## listing would double-fire per trigger (double-scores hold timers, burns one-shot activations).
func register(targetname: String, node: Node) -> void:
	if targetname.is_empty():
		return
	if not _registry.has(targetname):
		_registry[targetname] = []
	var nodes: Array = _registry[targetname]
	if not nodes.has(node):
		nodes.append(node)


func unregister(targetname: String, node: Node) -> void:
	if not _registry.has(targetname):
		return
	var arr: Array = _registry[targetname]
	arr.erase(node)
	if arr.is_empty():
		_registry.erase(targetname)


func has(targetname: String) -> bool:
	return _registry.has(targetname)


func get_nodes(targetname: String) -> Array:
	return _registry.get(targetname, [])


func reset() -> void:
	_registry.clear()


## Server-only when online; each entity's trigger() broadcasts its own effects to clients.
func fire(targetname: String, activator: Node = null, type: Type = Type.TOGGLE) -> void:
	if targetname.is_empty():
		return
	if NetworkManager.is_online() and not NetworkManager.is_host():
		return
	if not _registry.has(targetname):
		Log.debug("TriggerSystem: '%s' NOT REGISTERED" % targetname)
		return
	var nodes: Array = _registry[targetname]
	Log.debug("TriggerSystem: fire '%s' -> %d target(s), type=%s" % [targetname, nodes.size(), type])
	var snapshot: Array = nodes.duplicate()
	for node in snapshot:
		if not is_instance_valid(node):
			nodes.erase(node)
			continue
		if node.has_method("trigger"):
			node.trigger(activator, type)
	if nodes.is_empty():
		_registry.erase(targetname)
