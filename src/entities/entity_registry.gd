## Which script answers for a map entity classname, and what that means for a freshly loaded map.
##
## A .bsp arrives as generic nodes carrying an "entity" meta dictionary. Everything that turns those
## into gameplay is here: the classname table, binding scripts onto the nodes (apply_scripts), and
## clearing away the classnames nothing implements (strip_unscripted). spawn() is the same table
## reached from the other direction — /spawn and any runtime placement — so a hand-spawned entity is
## the same object the map would have produced.
##
## Static by design: the table is data, and the three passes over a map root keep no state. Nothing
## here knows about main.gd beyond being handed a map root.

## classname -> GDScript. Brush entities (model "*N") get set_script() on the existing BSP node;
## point entities get a new Node3D created with the script.
##
## Built once, on first use. weapon_*/ammo_* — the deathmatch arsenal our converted DM maps still
## place — are folded in from ItemDmPickup.CLASSNAMES so that list lives with the script that
## answers for it rather than being restated here.
static var _scripts: Dictionary = _build_table()


static func _build_table() -> Dictionary:
	var t := {
		# Brush entities
		"func_door": FuncDoor,
		"func_door_rotating": FuncDoorRotating,
		"func_wall": FuncWall,
		"func_wall_toggle": FuncWallToggle,
		"func_illusionary": FuncIllusionary,
		"func_ladder": FuncLadder,
		"func_water": FuncWater,
		"func_breakable": FuncBreakable,
		"func_rotating": FuncRotating,
		"func_button": FuncButton,
		"func_rot_button": FuncRotButton,
		"func_conveyor": FuncConveyor,
		"func_pendulum": FuncPendulum,
		"func_plat": FuncPlat,
		"func_platrot": FuncPlatRot,
		"func_train": FuncTrain,
		"func_tracktrain": FuncTrackTrain,
		"trigger_multiple": TriggerMultiple,
		"trigger_once": TriggerMultiple,
		"trigger_hurt": TriggerHurt,
		"trigger_push": TriggerPush,
		"trigger_teleport": TriggerTeleport,
		"trigger_gravity": TriggerGravity,
		"i_t_g": InfoTFGoal,
		"info_tfgoal": InfoTFGoal,
		# Wizard Wars' renamed forks of the TFC goal entities (same keys — the mod
		# only changed the classnames): info_wwgoal/i_w_g drive ww_leyline's node
		# control mode, item_wwgoal is ww_volcano's Archmage token.
		"i_w_g": InfoTFGoal,
		"info_wwgoal": InfoTFGoal,
		# Point entities (also brush: potatoc)
		"potatoc": PotatoCEntity,
		"light": LightEntity,
		"light_spot": LightEntity,
		"trigger_relay": TriggerRelay,
		"trigger_auto": TriggerRelay,
		"multi_manager": MultiManager,
		"multisource": TriggerRelay,
		"ambient_generic": AmbientGeneric,
		"game_text": GameText,
		"info_tfdetect": InfoTFDetect,
		"info_wwdetect": InfoTFDetect,
		"item_healthkit": ItemHealthkit,
		"item_tfgoal": ItemTFGoal,
		"item_wwgoal": ItemTFGoal,
		"info_tfgoal_timer": InfoTFGoalTimer,
		"i_t_t": InfoTFGoalTimer,
		"env_fade": EnvFade,
		"env_model": EnvModel,
		"env_render": EnvRender,
		"env_sprite": EnvSprite,
		"env_glow": EnvGlow,
		"env_shooter": EnvShooter,
		"env_bubbles": EnvBubbles,
		"env_shake": EnvShake,
		"env_sound": EnvSound,
		# cycler is a plain scenery model that plays its idle sequence — env_model's job.
		"cycler": EnvModel,
		"ww_emitter": WWEmitter,
		"env_beam": EnvBeam,
		"env_lightning": EnvBeam,
		"env_laser": EnvLaser,
		"info_target": NamedMarker,
		"info_intermission": NamedMarker,
		"path_corner": NamedMarker,
		"path_track": NamedMarker,
		"info_teleport_destination": NamedMarker,
		"info_player_start": InfoPlayerSpawn,
		"info_player_spawn": InfoPlayerSpawn,
		"info_player_teamspawn": InfoPlayerSpawn,
		"i_p_t": InfoPlayerSpawn,
		"info_player_deathmatch": InfoPlayerSpawn,
		"info_dragonrider_spawn": InfoDragonriderSpawn,
		"infodecal": InfoDecal,
		"info_areamarker": InfoAreaMarker,
		# Clip volume re-created from CLIP brushes lost during import (clip hulls
		# aren't built). Injected into ww_golem.bsp by tools/ww_clipbrush.py.
		"info_clipbrush": InfoClipBrush,
		"trigger_comet": TriggerComet,
		"monster_miniturret": TriggerComet,
		"monster_turret": TriggerComet,
		"ww_sentrycrystal": TriggerComet,
		"monster_dragon": Dragon,
		"dragon": Dragon,
		"monstermaker": MonsterMaker,
		"ww_monstermaker": MonsterMaker,
		"light_environment": LightEnvironment,
		# Golem entities
		"func_golem_body": FuncGolemBody,
		"func_golem_leftleg": FuncGolemLimb,
		"func_golem_rightleg": FuncGolemLimb,
		"func_golem_leftarm": FuncGolemLimb,
		"func_golem_rightarm": FuncGolemLimb,
		"func_golem_controls_forward": FuncGolemControls,
		"func_golem_controls_left": FuncGolemControls,
		"func_golem_controls_right": FuncGolemControls,
		"func_golem_controls_attack": FuncGolemControls,
		"trigger_golem": TriggerGolem,
		# Not a WW entity: the pickup /spawn drops for a weapon. Listed here so a map can place
		# one too, and so it resolves by classname like everything else. "combo_weapon" is the same
		# book left undecided — it picks one of the combo spells when it spawns.
		"item_weapon": ItemWeapon,
		"combo_weapon": ItemWeapon,
	}
	for cn in ItemDmPickup.CLASSNAMES:
		t[cn] = ItemDmPickup
	return t


## Does the table bind this classname?
static func has(classname: String) -> bool:
	return _scripts.has(classname)


## The script bound to a classname, or null.
static func script_for(classname: String) -> GDScript:
	return _scripts.get(classname)


## Sorted classnames the table binds — everything /spawn will answer to by classname.
static func classnames() -> Array:
	var out: Array = _scripts.keys()
	out.sort()
	return out

## Runtime spawn of a map entity by classname, with the keyvalues a .bsp would have carried.
## A brush entity gets its geometry from a "size" key (GoldSrc units); one that needs a brush and
## wasn't given a size falls back to a default box (GoldSrcEntity.build_brush_stand_in).
## Server-side: the dynamic-entity spawner rebuilds it on every client.
static func spawn(classname: String, keys: Dictionary, pos: Vector3, yaw: float) -> Node:
	var script: GDScript = _scripts.get(classname)
	if script == null:
		return null
	var ent := keys.duplicate()
	ent["classname"] = classname
	var data := {
		"script_path": script.resource_path,
		"ent": ent,
		"position": pos,
		"yaw": yaw,
		# The id has to come from the host: an entity that registers its own would draw it from a
		# per-peer counter, and a client the spawn was PVS-deferred for never advances that counter.
		"sync_state": true,
	}
	# Entities with a setup() of their own (Dragon) read keyvalues off the top level, not the
	# meta dictionary. merge() without overwrite so a stray key can't clobber the spawn fields.
	data.merge(ent, false)
	return NetworkManager.spawn_dynamic_entity(data)


## Bind a script to every entity node in a freshly loaded map that the table answers for, and log
## what the map contained. A node whose type does not match what its script expects is replaced by
## one that does before the script goes on.
static func apply_scripts(map_root: Node3D) -> void:
	var class_counts: Dictionary = {}
	var entity_count := 0

	for child in map_root.get_children():
		if not child.has_meta("entity"):
			continue
		var ent: Dictionary = child.get_meta("entity")
		var classname: String = ent.get("classname", "")
		class_counts[classname] = class_counts.get(classname, 0) + 1

		if classname == "worldspawn":
			continue

		if _scripts.has(classname):
			var script: GDScript = _scripts[classname]
			var script_base = script.get_instance_base_type()
			if not child.is_class(script_base) and script_base != &"Node":
				# Type mismatch (e.g. script wants CharacterBody3D but node is Node3D): replace the
				# generic node with the correct subtype before set_script.
				var new_node: Node3D = ClassDB.instantiate(script_base)
				new_node.name = child.name
				for key in child.get_meta_list():
					new_node.set_meta(key, child.get_meta(key))
				new_node.transform = child.transform
				child.replace_by(new_node)
				child.queue_free()
				child = new_node
			child.set_script(script)
			entity_count += 1

	Log.info("Entity summary (%d spawned):" % entity_count)
	var sorted_names := class_counts.keys()
	sorted_names.sort()
	for cn in sorted_names:
		Log.info("  %s: %d" % [cn, class_counts[cn]])



## Clear away the entity classnames nothing implements: brush ones are hidden and made
## non-colliding (their geometry is still part of the BSP), point ones are freed outright.
static func strip_unscripted(map_root: Node3D) -> void:
	var removed := 0
	var kept := 0
	for child in map_root.get_children():
		if not child.has_meta("entity"):
			continue
		var meta: Dictionary = child.get_meta("entity")
		var classname: String = meta.get("classname", "")
		if classname == "worldspawn":
			continue
		if _scripts.has(classname):
			kept += 1
		else:
			var model_key: String = meta.get("model", "")  # brush entities hidden, point entities freed
			if model_key.begins_with("*"):
				_hide_brush_node(child)
			else:
				child.queue_free()
			removed += 1
	Log.info("Entities: kept %d, removed %d unrecognized" % [kept, removed])


static func _hide_brush_node(node: Node3D) -> void:
	node.visible = false
	if node is StaticBody3D or node is AnimatableBody3D:
		var body := node as CollisionObject3D
		body.collision_layer = 0
		body.collision_mask = 0
	for child in node.get_children():
		if child is StaticBody3D or child is AnimatableBody3D:
			child.queue_free()
