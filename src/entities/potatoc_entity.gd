class_name PotatoCEntity
extends EntityBase
# PotatoC scripting entity — brush or point entity that runs PotatoC code on trigger.

var _interpreter: PotatoC
var _user: Node  # activator that triggered us


func _ready() -> void:
	super()

	# Parse globals — adds to static PotatoC.global_vars
	var globals: String = ent.get("globals", "")
	if not globals.is_empty():
		PotatoC.parse_globals(globals)

	# Collect all code keys: "code", "code1", "code2", ... "codeN"
	var code_keys: Array[String] = []
	for key in ent.keys():
		if key == "code" or (key.begins_with("code") and key.substr(4).is_valid_int()):
			code_keys.append(key)

	# Sort: "code" first, then "code1", "code2", ... numerically
	code_keys.sort_custom(func(a: String, b: String) -> bool:
		var a_num := -1 if a == "code" else int(a.substr(4))
		var b_num := -1 if b == "code" else int(b.substr(4))
		return a_num < b_num
	)

	var full_code := ""
	for key in code_keys:
		full_code += ent[key]

	_init_dispatch()
	_interpreter = PotatoC.new()
	_interpreter.function_handler = _on_function
	if not full_code.is_empty():
		_interpreter.parse_code(full_code)

	var classname: String = ent.get("classname", "")
	Log.debug("potatoc '%s' (%s): %d code keys, globals='%s'" % [
		ent.get("targetname", ""), classname, code_keys.size(), globals])


func trigger(activator: Node, _type: TriggerSystem.Type) -> void:
	# Host-only: interpreter code modifies authoritative state (goals, scores,
	# spawn groups) and fires triggers. Side effects propagate to clients via
	# their respective sync mechanisms (TriggerSystem, score sync, weather sync).
	if _is_network_client():
		return
	Log.debug("potatoc '%s' triggered (type=%s)" % [name, _type])
	_user = activator
	_interpreter.execute()


# --- Built-in function dispatch ---

var _dispatch: Dictionary  # func_name -> Callable(arg1: String, arg2: String) -> int

# Debounce: multiple RespawnPlayer calls in the same frame → single respawn
var _respawn_pending := false


func _init_dispatch() -> void:
	_dispatch = {
		# Trigger functions
		"Trigger": _fn_trigger, "TurnOn": _fn_turn_on, "TurnOff": _fn_turn_off,
		"Say": _fn_say, "SetLightStyle": _fn_set_light_style, "APTeam": _fn_ap_team,
		# Goal functions
		"Activate": _fn_activate, "Remove": _fn_remove, "Restore": _fn_restore,
		"IsActive": _fn_is_active, "IsInactive": _fn_is_inactive, "IsRemoved": _fn_is_removed,
		# Scoring
		"GiveTeamPoints": _fn_give_team_points, "GivePoints": _fn_give_points,
		"GivePlayerPoints": _fn_give_player_points,
		# Spawn groups
		"RemSG": _fn_rem_sg, "ResSG": _fn_res_sg,
		# Weather
		"SetWeather": _fn_set_weather,
		# Utility / queries
		"Random": _fn_random, "MaxPlayers": _fn_max_players, "APClass": _fn_ap_class,
		"GetAPID": _fn_get_apid, "GetEntityIndex": _fn_get_entity_index,
		"GetX": _fn_get_x, "GetY": _fn_get_y, "GetZ": _fn_get_z,
		"GetEntityX": _fn_get_entity_x, "GetEntityY": _fn_get_entity_y,
		"GetEntityZ": _fn_get_entity_z,
		"TriggerFromPlayer": _fn_trigger_from_player,
		"SetRenderAmount": _fn_set_render_amount_fn,
		"IsPlayerInWater": _fn_is_player_in_water,
		"PlaySound": _fn_play_sound_fn,
		"RespawnPlayer": _fn_respawn_player,
		"RemovePlants": _fn_remove_plants,
	}


func _on_function(app: PotatoC.App, local_vars: Dictionary) -> int:
	var func_name: String = app.str_val
	var arg1_str := _interpreter.get_string_arg(app.app1, local_vars)
	var arg2_str := _interpreter.get_string_arg(app.app2, local_vars)

	if _dispatch.has(func_name):
		return _dispatch[func_name].call(arg1_str, arg2_str)

	push_warning("PotatoC: unknown function '%s'" % func_name)
	return 0


# --- Handler methods ---

func _fn_trigger(arg1: String, _arg2: String) -> int:
	TriggerSystem.fire(arg1, self, TriggerSystem.Type.TOGGLE)
	return 0

func _fn_turn_on(arg1: String, _arg2: String) -> int:
	TriggerSystem.fire(arg1, self, TriggerSystem.Type.ON)
	return 0

func _fn_turn_off(arg1: String, _arg2: String) -> int:
	TriggerSystem.fire(arg1, self, TriggerSystem.Type.OFF)
	return 0

func _fn_say(arg1: String, _arg2: String) -> int:
	var text := GoalMessages.translate(arg1)
	if not _is_network_client():
		NetworkManager.sync_hud_text.rpc(text, NetworkManager.HUD_CENTER, 1.0, 1.0, 1.0, 3.0)
	return 0

func _fn_set_light_style(arg1: String, arg2: String) -> int:
	_set_light_style(arg1, arg2)
	return 0

func _fn_ap_team(_arg1: String, _arg2: String) -> int:
	if is_instance_valid(_user) and "team" in _user:
		return _user.team
	return 0

func _fn_activate(arg1: String, _arg2: String) -> int:
	var g := GoalSystem.get_goal(int(arg1))
	if g:
		g.goal_activate(_user)
	else:
		push_warning("PotatoC Activate: goal %s not found" % arg1)
	return 0

func _fn_remove(arg1: String, _arg2: String) -> int:
	var g := GoalSystem.get_goal(int(arg1))
	if g:
		g.goal_remove(_user)
	else:
		push_warning("PotatoC Remove: goal %s not found" % arg1)
	return 0

func _fn_restore(arg1: String, _arg2: String) -> int:
	var g := GoalSystem.get_goal(int(arg1))
	if g:
		g.goal_restore(_user)
	else:
		push_warning("PotatoC Restore: goal %s not found" % arg1)
	return 0

func _fn_is_active(arg1: String, _arg2: String) -> int:
	var g := GoalSystem.get_goal(int(arg1))
	return 1 if g and g.goal_state == TFGoalBase.GoalState.ACTIVE else 0

func _fn_is_inactive(arg1: String, _arg2: String) -> int:
	var g := GoalSystem.get_goal(int(arg1))
	return 1 if g and g.goal_state == TFGoalBase.GoalState.INACTIVE else 0

func _fn_is_removed(arg1: String, _arg2: String) -> int:
	var g := GoalSystem.get_goal(int(arg1))
	return 1 if g and g.goal_state == TFGoalBase.GoalState.REMOVED else 0

func _fn_give_team_points(arg1: String, arg2: String) -> int:
	GoalSystem.add_score(int(arg1), int(arg2))
	return 0

func _fn_give_points(arg1: String, _arg2: String) -> int:
	# GivePoints(amount) — award objective points to the activating player,
	# folded into their frag count (maps call it single-arg, e.g. GivePoints(2)).
	GoalSystem.add_player_points(node_peer_id(_user), int(arg1))
	return 0

func _fn_give_player_points(arg1: String, arg2: String) -> int:
	# GivePlayerPoints(playerHandle, amount) — award to a specific player.
	var node := _find_by_handle(int(arg1))
	GoalSystem.add_player_points(node_peer_id(node), int(arg2))
	return 0

func _fn_rem_sg(arg1: String, _arg2: String) -> int:
	_set_spawn_group_active(int(arg1), false)
	return 0

func _fn_res_sg(arg1: String, _arg2: String) -> int:
	_set_spawn_group_active(int(arg1), true)
	return 0

func _fn_set_weather(arg1: String, arg2: String) -> int:
	if Game.weather_system:
		Game.weather_system.set_weather(int(arg1), int(arg2))
	return 0

func _fn_random(arg1: String, arg2: String) -> int:
	return randi_range(int(arg1), int(arg2))

func _fn_max_players(_arg1: String, _arg2: String) -> int:
	# Real server cap (the value create_server uses), not a guessed constant.
	return NetworkManager.MAX_CLIENTS

func _fn_ap_class(_arg1: String, _arg2: String) -> int:
	# Activating player's class — WizardWars maps class onto element (see APTeam).
	if is_instance_valid(_user) and "element" in _user:
		return _user.element
	return 0

func _fn_remove_plants(_arg1: String, _arg2: String) -> int:
	PlantBehavior.remove_all_everywhere()
	return 0

func _fn_get_apid(_arg1: String, _arg2: String) -> int:
	return _user.get_instance_id() if is_instance_valid(_user) else 0

func _fn_get_entity_index(arg1: String, _arg2: String) -> int:
	if not arg1.is_empty() and TriggerSystem.has(arg1):
		var nodes := TriggerSystem.get_nodes(arg1)
		if not nodes.is_empty():
			return nodes[0].get_instance_id()
	return 0

func _fn_get_x(_arg1: String, _arg2: String) -> int:
	return _to_gs_x(global_position)

func _fn_get_y(_arg1: String, _arg2: String) -> int:
	return _to_gs_y(global_position)

func _fn_get_z(_arg1: String, _arg2: String) -> int:
	return _to_gs_z(global_position)

func _fn_get_entity_x(arg1: String, _arg2: String) -> int:
	var node := _find_by_handle(int(arg1))
	return _to_gs_x(node.global_position) if node else 0

func _fn_get_entity_y(arg1: String, _arg2: String) -> int:
	var node := _find_by_handle(int(arg1))
	return _to_gs_y(node.global_position) if node else 0

func _fn_get_entity_z(arg1: String, _arg2: String) -> int:
	var node := _find_by_handle(int(arg1))
	return _to_gs_z(node.global_position) if node else 0

func _fn_trigger_from_player(arg1: String, arg2: String) -> int:
	var player := _find_by_handle(int(arg1))
	if player and not arg2.is_empty():
		TriggerSystem.fire(arg2, player, TriggerSystem.Type.TOGGLE)
	return 0

func _fn_set_render_amount_fn(arg1: String, arg2: String) -> int:
	_set_render_amount(arg1, int(arg2))
	return 0

func _fn_is_player_in_water(arg1: String, _arg2: String) -> int:
	var player := _find_by_handle(int(arg1))
	if player and player.has_method("is_in_water"):
		return 1 if player.is_in_water() else 0
	return 0

func _fn_play_sound_fn(arg1: String, _arg2: String) -> int:
	_play_sound(arg1)
	return 0

func _fn_respawn_player(_arg1: String, _arg2: String) -> int:
	if _respawn_pending:
		return 0
	_respawn_pending = true
	_do_respawn_all.call_deferred()
	return 0

func _do_respawn_all() -> void:
	_respawn_pending = false
	var main_scene = get_tree().current_scene
	if main_scene and main_scene.has_method("respawn_all_players"):
		main_scene.respawn_all_players()


# --- Coordinate conversion: Godot → GoldSrc ---
# Godot = (-gs_x * S, gs_z * S, gs_y * S), so invert:

func _to_gs_x(pos: Vector3) -> int:
	return int(-pos.x / GameConsts.SCALE_FACTOR)

func _to_gs_y(pos: Vector3) -> int:
	return int(pos.z / GameConsts.SCALE_FACTOR)

func _to_gs_z(pos: Vector3) -> int:
	return int(pos.y / GameConsts.SCALE_FACTOR)


func _find_by_handle(handle: int) -> Node:
	if handle == 0:
		return null
	return instance_from_id(handle) as Node


func _set_render_amount(targetname: String, amount: int) -> void:
	if targetname.is_empty():
		return
	if not TriggerSystem.has(targetname):
		return
	var alpha := amount / 255.0
	for node in TriggerSystem.get_nodes(targetname):
		if not node is Node3D:
			continue
		for child in node.get_children():
			if not child is MeshInstance3D:
				continue
			var mesh_inst: MeshInstance3D = child
			for surf_idx in mesh_inst.mesh.get_surface_count():
				var mat = mesh_inst.get_active_material(surf_idx)
				if mat is StandardMaterial3D:
					mat = mat.duplicate()
					mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					mat.albedo_color.a = alpha
					mesh_inst.set_surface_override_material(surf_idx, mat)


func _set_spawn_group_active(group: int, active: bool) -> void:
	if active:
		SpawnSystem.restore_group(group)
	else:
		SpawnSystem.remove_group(group)


func _play_sound(sound_path: String) -> void:
	if sound_path.is_empty():
		return
	SoundSystem.play_global(sound_path)


func _set_light_style(targetname: String, style_char: String) -> void:
	if targetname.is_empty() or style_char.is_empty():
		return
	if not TriggerSystem.has(targetname):
		push_warning("PotatoC SetLightStyle: no entity '%s'" % targetname)
		return
	for node in TriggerSystem.get_nodes(targetname):
		if node.has_method("set_light_style"):
			node.set_light_style(style_char)
