class_name HolidayGroup
extends Node3D
## One group of holiday props against a wall: a dynamic entity HolidayDecor spawns on the server.
## Every peer builds the props from the spawn data. Any blow pops one in a burst of confetti and it
## comes back a little later; which are popped, and when that last changed, ride the snapshot.

const _SHADER := preload("res://shaders/holiday_decor.gdshader")
const _SHADOW_SHADER := preload("res://shaders/holiday_shadow.gdshader")
## A prop's blob shadow: an ellipse this much wider than what it built, this far off the floor.
const SHADOW_SPREAD := 1.2
const SHADOW_LIFT := 0.015
const POP_SOUND := "misc/confetti_pop.wav"
const CONFETTI := {
	"thanksgiving": [Color(0.95, 0.5, 0.1), Color(0.85, 0.2, 0.1), Color(0.95, 0.78, 0.2),
		Color(0.55, 0.32, 0.12), Color(0.5, 0.6, 0.15)],
	"christmas": [Color(0.85, 0.1, 0.1), Color(0.1, 0.6, 0.2), Color(0.98, 0.82, 0.3),
		Color(0.95, 0.95, 0.95), Color(0.75, 0.8, 0.9)],
}
## Seconds a popped prop stays gone, at random between the two.
static var respawn_after := Vector2(20.0, 35.0)
## Whether groups build their mesh. A dedicated server draws nothing and stands a box of the props'
## bounds in for it, which is all PVS needs. Tests turn it on to look at the geometry.
static var meshes := DisplayServer.get_name() != "headless"
static var _material: ShaderMaterial
static var _shadow_material: ShaderMaterial
static var _bound_to: LightGrid

## The props, as HolidayDecor placed them: [{kind, size, seed, r, h, at, yaw}] in this node's frame.
var props: Array = []
var holiday := ""
## x: one bit per prop, set while it is popped; y: the server's clock (ms) when x last changed.
## One property so the two can't arrive apart. Set on the server, followed on the clients.
var state := Vector2i.ZERO:
	set(value):
		if value == state:
			return
		var was := state.x
		state = value
		_show(was)
var popped: int:
	get: return state.x
var _mesh: MeshInstance3D
var _hits: Array[HolidayProp] = []


func setup(data: Dictionary, is_host: bool) -> void:
	position = data.get("position", Vector3.ZERO)
	rotation.y = data.get("yaw", 0.0)
	props = data.get("props", [])
	holiday = data.get("holiday", "")
	if meshes:
		var geo := HolidayProps.Geo.new()
		var shadows := HolidayProps.Geo.new()
		for k in props.size():
			var p: Dictionary = props[k]
			geo.prop = k
			var xf := Transform3D(Basis(Vector3.UP, p["yaw"]), p["at"])
			var first := geo.verts.size()
			HolidayProps.build(geo, xf, p["kind"], p["size"], p["seed"])
			shadows.prop = k
			_shadow(shadows, xf, geo.verts.slice(first))
		_mesh = MeshInstance3D.new()
		_mesh.mesh = geo.to_mesh()
		shadows.add_to(_mesh.mesh)
		_mesh.mesh.surface_set_material(0, material())
		_mesh.mesh.surface_set_material(1, shadow_material())
		_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh)
	else:
		add_child(_bounds())
	if is_host:
		for k in props.size():
			var hit := HolidayProp.make(self, k, props[k]["at"], props[k]["r"], props[k]["h"])
			add_child(hit)
			_hits.append(hit)


static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = _SHADER
		_material.set_shader_parameter("linear_output", EntityRender.renderer_is_linear())
		_material.set_shader_parameter("detail", HolidayProps.detail_texture())
	# Rebound for each map's grid: clearing a map drops the grid's hold on every material it lit.
	if AssetLoader.light_grid and AssetLoader.light_grid != _bound_to:
		AssetLoader.light_grid.bind(_material)
		_bound_to = AssetLoader.light_grid
	return _material


## The prop's shadow, fitted to what it built: its outline seen from above, in its own frame.
static func _shadow(shadows: HolidayProps.Geo, xf: Transform3D, verts: PackedVector3Array) -> void:
	var inv := xf.affine_inverse()
	var lo := Vector2(INF, INF)
	var hi := -lo
	for v in verts:
		var l := inv * v
		lo = Vector2(minf(lo.x, l.x), minf(lo.y, l.z))
		hi = Vector2(maxf(hi.x, l.x), maxf(hi.y, l.z))
	var mid := (lo + hi) * 0.5
	var half := (hi - lo) * 0.5 * SHADOW_SPREAD
	var y := 0.01 + SHADOW_LIFT  # `at` stands 1 cm into the floor
	shadows.quad(xf, Vector3(mid.x - half.x, y, mid.y - half.y), Vector3(mid.x + half.x, y, mid.y - half.y),
		Vector3(mid.x - half.x, y, mid.y + half.y), Vector3(mid.x + half.x, y, mid.y + half.y), Color.BLACK)


static func shadow_material() -> ShaderMaterial:
	if _shadow_material == null:
		_shadow_material = ShaderMaterial.new()
		_shadow_material.shader = _SHADOW_SHADER
	return _shadow_material


## What PVS sizes the entity by where nothing draws it: a box round every prop's footprint.
func _bounds() -> MeshInstance3D:
	var box := AABB()
	for k in props.size():
		var p: Dictionary = props[k]
		var r: float = p["r"]
		var prop := AABB(p["at"] - Vector3(r, 0, r), Vector3(r * 2.0, p["h"], r * 2.0))
		box = prop if k == 0 else box.merge(prop)
	var mesh := BoxMesh.new()
	mesh.size = box.size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = box.get_center()
	return mi


func net_sync_properties() -> PackedStringArray:
	return PackedStringArray([":state"])


## Server: prop `k` was hit.
func pop(k: int) -> void:
	if k < 0 or k >= props.size() or is_popped(k):
		return
	state = Vector2i(popped | (1 << k), Time.get_ticks_msec())
	get_tree().create_timer(randf_range(respawn_after.x, respawn_after.y)).timeout.connect(_unpop.bind(k))


func _unpop(k: int) -> void:
	state = Vector2i(popped & ~(1 << k), Time.get_ticks_msec())


func is_popped(k: int) -> bool:
	return (popped >> k) & 1 != 0


func _show(was: int) -> void:
	for k in _hits.size():
		_hits[k].set_gone(is_popped(k))
	if _mesh:
		_mesh.set_instance_shader_parameter(&"popped", popped)
	if DisplayServer.get_name() == "headless" or not _fresh():
		return
	var colors: Array[Color] = []
	colors.assign(CONFETTI[holiday])
	for k in props.size():
		var bit := 1 << k
		if (popped & bit) == (was & bit):
			continue
		var p: Dictionary = props[k]
		var r: float = p["r"]
		var at: Vector3 = to_global(p["at"]) + Vector3(0, minf(float(p["h"]) * 0.5, 0.6), 0)
		if popped & bit:
			ConfettiEffect.spawn(get_parent(), at, colors, r, clampi(int(60.0 + r * 120.0), 60, 160))
			SoundSystem.play_3d_local(POP_SOUND, at, randf_range(0.9, 1.15))
		else:
			ConfettiEffect.spawn(get_parent(), at, colors, r * 0.4, 18)


## Whether the last change is news: a joiner's first snapshot, or one coming back into view, says
## what is popped, not that it just popped.
func _fresh() -> bool:
	if NetworkManager.is_authority() or not NetworkManager.is_clock_synced():
		return true
	return NetworkManager.get_estimated_server_time() - state.y / 1000.0 < 1.0
