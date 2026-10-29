class_name InfoTFGoal
extends TFGoalBase
# info_tfgoal / i_t_g — TFC info goal entity.
# Ported from tf_info_goal.cpp (TFInfoGoal).
# Can be a brush volume (invisible trigger) or a point entity with mdl (visible, touchable).

var _inactivate_time: float = 0.0
var _area: Area3D
## CTFCGoal::PlaceGoal only sets a touch on a goal with a model (brush or mdl). ww_2fort's
## "your grail has returned" goals have neither: they fire from the flag's return, and are
## not meant to be walked into.
var _touchable := true


func _ready() -> void:
	super()
	_register_for_sync()
	_parse_tf_properties(get_meta("entity", {}))

	var has_brush := is_brush_entity()

	if has_brush:
		# Brush entity: hide meshes and use Volume Area3D for player detection
		_area = GoldSrcEntity.use_volume_as_trigger(self, GameConsts.MASK_PLAYER)
	else:
		# Point entity: load mdl model and create touch area from model bbox
		var mdl_path: String = ent.get("mdl", "")
		_touchable = not mdl_path.is_empty()
		if not mdl_path.is_empty():
			var model := AssetLoader.load_model(mdl_path)
			if model:
				add_child(model)
			else:
				push_warning("info_tfgoal %d: failed to load %s" % [goal_no, mdl_path])

		_area = Area3D.new()
		_area.name = "GoalArea"
		_area.collision_layer = 0
		_area.collision_mask = GameConsts.MASK_PLAYER
		_area.monitoring = true
		_area.monitorable = false
		var sphere := SphereShape3D.new()
		sphere.radius = 1.0  # ~40 GoldSrc units
		var col := CollisionShape3D.new()
		col.shape = sphere
		_area.add_child(col)
		add_child(_area)

	_area.body_entered.connect(_on_body_entered)

	# Apply initial state — match C++ EF_NODRAW behavior
	if goal_state == GoalState.REMOVED:
		_area.set_deferred("monitoring", false)
		set_entity_visible(false)

	Log.info("%d: group=%d team=%d g_a=%d g_e=%d state=%d brush=%s" % [
		goal_no, group_no, req_team, goal_activation, goal_effects, goal_state, has_brush], "tfgoal")


func _physics_process(_delta: float) -> void:
	var time := Time.get_ticks_msec() / 1000.0

	# Pending activation (delay_time)
	if _activate_pending_time != 0.0 and time >= _activate_pending_time:
		_activate_pending_time = 0.0
		_arm_inactivate_timer()
		if not is_instance_valid(_activator):
			_activator = null
		process_goals(_activator)
		_area.set_deferred("monitoring", false)

	# Inactivation timer. Only an ACTIVE goal resets: a goal whose own ops removed it (a flag
	# pickup that removes its own group) must stay REMOVED until something restores it, or this
	# hands it straight back — a stand with no flag model that still gives you the flag.
	if _inactivate_time != 0.0 and time >= _inactivate_time:
		_inactivate_time = 0.0
		if goal_state == GoalState.ACTIVE:
			goal_inactivate(null)


func _on_body_entered(body: Node3D) -> void:
	Log.info("%d: body_entered: %s" % [goal_no, body.name], "tfgoal")
	if not body is CharacterBody3D:
		return
	if body.get("is_dead"):
		return
	# Client: host is authoritative for goal interactions
	if _is_network_client():
		return
	if goal_state != GoalState.INACTIVE:
		Log.info("%d: blocked: state=%d (not inactive)" % [goal_no, goal_state], "tfgoal")
		return
	# Info goals require GA_PLAYER_TOUCH flag
	if not (goal_activation & GA_PLAYER_TOUCH) or not _touchable:
		Log.info("%d: blocked: g_a=%d (no PLAYER_TOUCH)" % [goal_no, goal_activation], "tfgoal")
		return
	# Deferred: goal_activate mutates the scene (state, entities), which mid body_entered
	# callback re-enters the physics server and corrupts it (Linux segfault under load) —
	# same reason item_tfgoal defers its grab.
	call_deferred("goal_activate", body)


# --- State transitions ---

func goal_activate(player: Node) -> void:
	if not _try_activate(player):
		return

	if delay_time != 0.0:
		_activate_pending_time = Time.get_ticks_msec() / 1000.0 + delay_time
	else:
		_arm_inactivate_timer()
		process_goals(_activator)
		set_entity_visible(false)  # C++: EF_NODRAW after activation
		_area.set_deferred("monitoring", false)

	_sync_notify()
	Log.debug("%d: activated by %s" % [goal_no, str(player.name) if player else "null"], "tfgoal")


## Arm the reset timer for this activation. GoldSrc reads a negative `wait` as "never
## reactivates", so leave it unarmed — ww_december's flag pickups are wait -1 and rely on
## their group restore, not a timer, to come back.
func _arm_inactivate_timer() -> void:
	_inactivate_time = 0.0 if stay_active < 0.0 else Time.get_ticks_msec() / 1000.0 + stay_active


func goal_inactivate(_player: Node) -> void:
	goal_state = GoalState.INACTIVE
	_inactivate_time = 0.0
	set_entity_visible(true)
	_area.set_deferred("monitoring", true)
	_sync_notify()


func goal_remove(_player: Node) -> void:
	goal_state = GoalState.REMOVED
	_activate_pending_time = 0.0
	_inactivate_time = 0.0
	set_entity_visible(false)
	_area.set_deferred("monitoring", false)
	_sync_notify()


func goal_restore(_player: Node) -> void:
	goal_state = GoalState.INACTIVE
	_inactivate_time = 0.0
	set_entity_visible(true)
	_area.set_deferred("monitoring", true)
	_sync_notify()


# --- TriggerSystem interface ---

func trigger(activator_node: Node, _type: TriggerSystem.Type) -> void:
	# External triggers can activate goals in any state (including REMOVED).
	# Only player-touch activation (body_entered) respects goal_state.
	goal_activate(activator_node)
