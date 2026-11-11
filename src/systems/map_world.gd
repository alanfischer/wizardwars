extends Node
## The loaded map: its scene off disk, its entities scripted and in the tree, PVS, the per-map
## systems every peer needs at the same path (decals, weather), the map's lighting, and the
## per-map resets on the way out.
##
## Parented to main.gd as "MapWorld". The map and its systems go under the injected parent, not
## here: entities, decals and weather are reached by path between peers, and that path is Main's.

const EntityRegistry = preload("res://src/entities/entity_registry.gd")

## Everything is .scn: Blender .glb is pre-converted on the host, so the runtime loader only
## ever deals with one format.
const _MAP_SEARCH_PATHS := [
	MapConverter.CACHE_DIR + "/%s.scn",  # converted on this peer OR downloaded from another
	"exported/%s.scn",               # legacy exported scene
]

var _parent: Node
var _skybox: Skybox
var _rendered := false  # this process draws its maps: lighting, sky, water depth, PVS render groups


## `rendered` is false on a dedicated server and the offline bake.
func bind(parent: Node, skybox: Skybox, rendered: bool) -> void:
	_parent = parent
	_skybox = skybox
	_rendered = rendered


func _ready() -> void:
	ServerVars.value_changed.connect(_on_server_var_changed)


## False when there is no usable .scn.
func load_map(map_name: String) -> bool:
	var map_root := _load_root(map_name)
	if map_root == null:
		return false
	if _rendered:
		_begin_lighting(map_root)
	VisibilitySystem.setup(map_root)
	_add_map(map_root)
	if _rendered:
		_register_worldspawn_pvs_groups(map_root)

	# On the server too: place_rpc and set_weather are @rpcs, so the nodes must exist at a matching
	# path on every peer. Headless, DecalSystem draws nothing (its textures fail to load).
	var decals := DecalSystem.new()
	decals.name = "DecalSystem"
	decals.setup()
	_parent.add_child(decals)
	Game.decal_system = decals
	# The follow target is attached once a local player exists (never, on a dedicated server).
	var weather := WeatherSystem.new()
	weather.name = "WeatherSystem"
	weather.map_root = map_root
	_parent.add_child(weather)
	Game.weather_system = weather

	if _rendered:
		var watered := WaterSurfaces.apply(map_root, RenderQuality.water_depth_enabled())
		if watered > 0:
			Log.info("Water depth effects %s on %d liquid surfaces" % [
					"on" if RenderQuality.water_depth_enabled() else "off", watered])
		_skybox.build(map_root)
		NightMode.apply(map_root)  # after WaterSurfaces, so it collects the liquids as drawn

	AssetLoader.precache_resources(_parent)  # so the first shot has no hitch
	return true


## After main has freed the map's nodes.
func clear() -> void:
	_skybox.clear()
	AssetLoader.light_grid = null
	LightGrid._all_acube_materials.clear()
	NetworkManager.reset_entities()
	VisibilitySystem.teardown()
	GoalSystem.reset()
	SpawnSystem.reset()
	TriggerSystem.reset()
	StatusSystem.reset()
	BotSystem.reset()
	SiegeSystem.reset()
	MonsterNav.reset()
	MatchSystem.reset()
	PotatoC.global_vars.clear()


## Before the entities spawn: they light themselves off the grid as they enter, and a
## light_environment hands NightMode its lightstyle from _ready.
func _begin_lighting(map_root: Node3D) -> void:
	NightMode.reset()
	var grid := LightGrid.from_meta(map_root)
	if grid.is_valid():
		Log.info("Light grid loaded from map metadata")
		AssetLoader.light_grid = grid


func _on_server_var_changed(key: String, _value: Variant) -> void:
	if key == "time" and _rendered and Game.map_root:
		NightMode.apply(Game.map_root)


func _load_root(map_name: String) -> Node3D:
	for tpl in _MAP_SEARCH_PATHS:
		var path: String = tpl % map_name
		if not FileAccess.file_exists(path):
			continue
		var scene := ResourceLoader.load(path) as PackedScene
		if scene == null:
			push_error("Failed to load scene: %s" % path)
			continue
		var root: Node3D = scene.instantiate()
		_report_map_pipeline(root, path)
		EntityRegistry.strip_unscripted(root)
		return root
	return null


## A GoldSrc-derived scene has to carry the stripped BSP tree, or hop has no clip hull to trace and
## PVS is off — the map plays with render-face collision and nobody is told. A peer that downloaded
## the .scn can't repair it (no .bsp ships to clients), so logging the pipeline version is the best
## we can do. Blender maps have no worldspawn and never had a tree, so they're not this case.
func _report_map_pipeline(root: Node3D, scn_path: String) -> void:
	if root.has_meta("bsp_data") or root.get_node_or_null("worldspawn") == null:
		return
	Log.warn(("%s was built by pipeline v%d (current is v%d) and carries no BSP tree: "
		+ "no clip-hull collision, PVS off. Re-download it from a host on current code.")
		% [scn_path, int(root.get_meta(MapConverter.VERSION_META, 0)), MapConverter.CACHE_VERSION])


func _add_map(map_root: Node3D) -> void:
	# TFC entity keys, so multi_manager doesn't treat them as targets.
	MultiManager.extra_reserved_keys = PackedStringArray([
		"goal_no", "goal_group", "goal_state", "items_allowed",
		"maxammo_shells", "maxammo_nails", "maxammo_rockets", "maxammo_cells",
	])
	EntityRender.apply_color_space(map_root)
	EntityRegistry.apply_scripts(map_root)
	Game.map_root = map_root
	_parent.add_child(map_root)  # entity _ready runs here, info_wwdetect included
	if GoalSystem.is_combo_chaos():
		Log.info("Combo chaos ON: this map's weapon/ammo pickups are combo spellbooks")
	_init_spawn_groups()


func _register_worldspawn_pvs_groups(map_root: Node3D) -> void:
	var ws := map_root.get_node_or_null("worldspawn") as Node3D
	if ws == null:
		return
	var count := 0
	for child in ws.get_children():
		if child is Node3D and child.has_meta("pvs_leaves"):
			VisibilitySystem.track_node_by_leaves(
				child.get_instance_id(), child as Node3D,
				child.get_meta("pvs_leaves") as PackedInt32Array)
			count += 1
	if count > 0:
		Log.info("[Visibility] Tracking %d worldspawn spatial groups for PVS culling" % count)


## TFC's game mode code started only home spawns active; our generic entity spawner has no such
## logic. Heuristic: for each team, the lowest-numbered group is the home group — keep it active
## and disable all others.
func _init_spawn_groups() -> void:
	var team_groups: Dictionary = {}  # team_no -> Dictionary(group_no -> int)
	for spawn in SpawnSystem.get_all_spawns():
		if spawn.team_no == 0 or spawn.group_no == 0:
			continue
		if not team_groups.has(spawn.team_no):
			team_groups[spawn.team_no] = {}
		var groups: Dictionary = team_groups[spawn.team_no]
		groups[spawn.group_no] = groups.get(spawn.group_no, 0) + 1

	var any_multi := false
	for team_no in team_groups:
		if team_groups[team_no].size() > 1:
			any_multi = true
			break
	if not any_multi:
		return

	for team_no in team_groups:
		var groups: Dictionary = team_groups[team_no]
		if groups.size() <= 1:
			continue
		# TFC convention: base spawns use the lowest group_no, forward/captured positions use higher.
		var home_group: int = 0
		var home_count: int = 0
		for group_no in groups:
			if home_group == 0 or group_no < home_group:
				home_group = group_no
				home_count = groups[group_no]
		for group_no in groups:
			if group_no != home_group:
				SpawnSystem.remove_group(group_no)
		Log.info("SpawnGroups: team %d home=group %d (%d spawns), disabled %d forward groups" % [
			team_no, home_group, home_count, groups.size() - 1])
