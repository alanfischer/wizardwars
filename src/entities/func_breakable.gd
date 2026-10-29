class_name FuncBreakable
extends FuncWallToggle
# func_breakable — breakable wall (houses, walls destroyed by golem, etc.)
# GoldSrc func_breakable spawnflag 1 = "trigger only" (NOT "start off"), so
# _ready overrides the parent's SF_START_OFF interpretation.
#
# A breakable sprays a debris burst matching its GoldSrc "material" key when
# destroyed. A missing key is matGlass (0), same as CBreakable's zero-init — not
# "no material", so ww_december's and ww_library's windows still shatter.
#
# A brush may also name its own "gibmodel", which wins over the material: ww_feudal has one
# that showers flying skulls rather than the wood its material asks for.

const SF_TRIGGER_ONLY := 1  # "Only Trigger": can't be shot apart, only a trigger destroys it

var _material := GibEffect.MAT_GLASS  # GoldSrc Materials value; absent key = glass
var _gibmodel := ""                   # brush's own "gibmodel", if it named one
var _health := HealthBehavior.new()
var _damageable := false
# team=NONE keeps bot target-selection (which skips team==NONE) from fixating on
# the wall, while splash/direct damage (which don't skip NONE) still land.
var team: int = GameConsts.Team.NONE


func _ready() -> void:
	super()
	set_entity_visible(true)
	_record_initial_visible()
	EntityRender.apply_render_properties(self, ent)
	if ent.has("material"):
		_material = int(ent["material"])
	_gibmodel = str(ent.get("gibmodel", ""))
	AssetLoader.precache_model(GibEffect.model_for_break(_material, _gibmodel))
	var hp := float(ent.get("health", 0))
	if hp > 0.0 and _is_breakable() and not (parse_spawnflags(ent) & SF_TRIGGER_ONLY):
		_arm_damage(hp)


## A brush that can be shot apart. "unhunted" is why ww_library's wall of windows doesn't pull
## a missile off the wizard standing behind it — see Combat.find_homing_target.
func _arm_damage(hp: float) -> void:
	_damageable = true
	_health.initialize(self, hp, NetworkManager.is_authority(), _break)
	add_to_group("unhunted")


## CBreakable::IsBreakable — matUnbreakableGlass alone shrugs off both damage and Use.
func _is_breakable() -> bool:
	return _material != GibEffect.MAT_UNBREAKABLE_GLASS


func take_damage(amount: float, type: int = GameConsts.DamageType.PHYSICAL, attacker: Node3D = null) -> void:
	if not _damageable:
		return
	_health.take_damage(amount, type, attacker)


func trigger(activator: Node, type: TriggerSystem.Type) -> void:
	# CBreakable::Use ignores the use type and always Dies; only ON (round reset
	# restoring the geometry) goes through the normal visibility path.
	if type != TriggerSystem.Type.ON:
		if not _is_breakable():
			return  # matUnbreakableGlass ignores the Use outright
		if _game_visible:
			_break()
			return
	super(activator, type)


func _break() -> void:
	var aabb := _brush_world_aabb()
	GibEffect.burst(aabb.get_center(), _material, aabb.size, 0, "", get_tree().current_scene, _gibmodel)
	set_entity_visible(false)
	_sync_notify()


func _brush_world_aabb() -> AABB:
	var result := AABB()
	var seeded := false
	var stack: Array = [self]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and n.mesh:
			var mi := n as MeshInstance3D
			var world: AABB = mi.global_transform * mi.get_aabb()
			result = world if not seeded else result.merge(world)
			seeded = true
		for c in n.get_children():
			stack.append(c)
	if not seeded:
		return AABB(global_position, Vector3.ZERO)
	return result
