class_name VRLobbyPanel
extends VRPanel3D
# Opaque 3D panel hosting 2D lobby UIs; auto-hides when no contained UI is visible.

var _trigger_was_pressed := false
var _ui_nodes: Array[Node] = []


func _populate_viewport(vp: SubViewport) -> void:
	# Solid background behind the UI; visible only when the panel itself is.
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.1, 0.15)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	vp.add_child(bg)


func _on_panel_ready() -> void:
	visible = false
	Log.info("VRLobbyPanel ready — mesh at local %s, parent: %s" % [
		mesh.position, str(get_parent().name) if get_parent() else "none"])


func add_ui(node: Node) -> void:
	viewport.add_child(node)
	_ui_nodes.append(node)
	node.visibility_changed.connect(_refresh_visibility)
	node.tree_exited.connect(_ui_nodes.erase.bind(node))
	# Deferred so the child's _ready runs first; otherwise the panel briefly flashes visible before _ready hides it.
	_refresh_visibility.call_deferred()


func _refresh_visibility() -> void:
	for n in _ui_nodes:
		if n.visible:
			visible = true
			return
	visible = false


## Forwards hover/trigger from the pointing controller to the SubViewport as mouse events.
func update_pointer(controller: XRController3D) -> void:
	var ray_origin := controller.global_position
	var ray_dir := -controller.global_transform.basis.z

	var mesh_normal := mesh.global_transform.basis.z
	var plane := Plane(mesh_normal, mesh.global_position)
	var hit: Variant = plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return

	var local_hit := mesh.global_transform.affine_inverse() * (hit as Vector3)
	if abs(local_hit.x) > PANEL_SIZE.x * 0.5 or abs(local_hit.y) > PANEL_SIZE.y * 0.5:
		return

	var pixel := Vector2(
		(local_hit.x / PANEL_SIZE.x + 0.5) * VIEWPORT_SIZE.x,
		(0.5 - local_hit.y / PANEL_SIZE.y) * VIEWPORT_SIZE.y
	)

	var motion := InputEventMouseMotion.new()
	motion.position = pixel
	motion.global_position = pixel
	viewport.push_input(motion)

	var trigger_pressed := controller.is_button_pressed("trigger_click")
	if trigger_pressed != _trigger_was_pressed:
		_trigger_was_pressed = trigger_pressed
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = trigger_pressed
		click.position = pixel
		click.global_position = pixel
		viewport.push_input(click)
