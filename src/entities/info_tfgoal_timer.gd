class_name InfoTFGoalTimer
extends TFGoalBase
# info_tfgoal_timer — TFC timer goal entity.
#
# In TFC, INACTIVE is the "ticking" state: the timer fires process_goals every
# search_time seconds and stays INACTIVE (recurring). REMOVED disables it.
# ACTIVE is a one-shot countdown (typically a recapture cooldown) that drops
# back to INACTIVE on expiry.
#
# Lifecycle:
#   spawn (state=INACTIVE) → start ticking
#   goal_restore()  → INACTIVE + start ticking
#   goal_activate() → ACTIVE  + one-shot search_time countdown
#   timer expires   → INACTIVE + process_goals + rearm if still INACTIVE
#                     (process_goals may cascade to goal_remove / GR_REMOVE_IMMEDIATELY,
#                      in which case state ends up REMOVED and we don't rearm)
#   goal_remove()   → REMOVED + cancel timer

var search_time: float = 0.0
var _timer: SceneTreeTimer = null
var _timer_gen: int = 0  # incremented on each cancel/start; stale callbacks ignore themselves
var _timer_activator: Node = null
var _model: Node3D


func _ready() -> void:
	super()
	_register_for_sync()
	_parse_tf_properties(get_meta("entity", {}))
	search_time = parse_float(ent, "search_time", 0.0)

	# Load optional MDL model (e.g. flag marker on cz2 command points)
	var mdl_path: String = ent.get("mdl", "")
	if not mdl_path.is_empty():
		_model = AssetLoader.load_model(mdl_path)
		if _model:
			add_child(_model)
			if _entity.entity_id >= 0:
				VisibilitySystem.untrack_node(_entity.entity_id)
				VisibilitySystem.track_node(_entity.entity_id, self)
			var skin: int = parse_int(ent, "skin", 0)
			if skin > 0:
				AssetLoader.set_model_skin(_model, skin)

	# Visibility based on initial state
	set_entity_visible(goal_state != GoalState.REMOVED)

	Log.info("timer %d: group=%d team=%d state=%d search_time=%.1f" % [
		goal_no, group_no, req_team, goal_state, search_time], "tfgoal")

	# INACTIVE timers tick on a recurring schedule from spawn (TFC behavior).
	# Host-only — clients receive cascaded effects via RPC.
	if goal_state == GoalState.INACTIVE and not _is_network_client():
		_start_timer()


func goal_activate(player: Node) -> void:
	goal_state = GoalState.ACTIVE
	set_entity_visible(true)
	_sync_notify()
	_timer_activator = player
	_start_timer()
	Log.info("timer %d: activated -> ACTIVE, timer %.1fs" % [goal_no, search_time], "tfgoal")


func goal_inactivate(_player: Node) -> void:
	goal_state = GoalState.INACTIVE
	set_entity_visible(true)
	_sync_notify()
	_cancel_timer()
	Log.info("timer %d: inactivated -> INACTIVE" % goal_no, "tfgoal")


func goal_remove(_player: Node) -> void:
	goal_state = GoalState.REMOVED
	set_entity_visible(false)
	_sync_notify()
	_cancel_timer()
	Log.info("timer %d: removed -> REMOVED" % goal_no, "tfgoal")


func goal_restore(_player: Node) -> void:
	goal_state = GoalState.INACTIVE
	set_entity_visible(true)
	_sync_notify()
	_start_timer()  # restored timers begin ticking again
	Log.info("timer %d: restored -> INACTIVE, ticking %.1fs" % [goal_no, search_time], "tfgoal")


func trigger(activator: Node, _type: TriggerSystem.Type) -> void:
	goal_activate(activator)


func _start_timer() -> void:
	_cancel_timer()
	if search_time <= 0.0:
		return
	_timer = get_tree().create_timer(search_time)
	# Bind generation so a cancelled-but-still-pending SceneTreeTimer doesn't
	# resurrect us when it eventually fires.
	var gen := _timer_gen
	_timer.timeout.connect(_on_timer_expired.bind(gen), CONNECT_ONE_SHOT)


func _cancel_timer() -> void:
	# Bumping generation invalidates any in-flight SceneTreeTimer callback.
	_timer_gen += 1
	_timer = null


func _on_timer_expired(gen: int) -> void:
	if gen != _timer_gen:
		return  # cancelled or superseded
	_timer = null
	goal_state = GoalState.INACTIVE
	var activator = _timer_activator if is_instance_valid(_timer_activator) else null
	if check_activation(activator):
		Log.info("timer %d: expired -> INACTIVE, processing goals" % goal_no, "tfgoal")
		process_goals(activator)
	else:
		Log.info("timer %d: expired -> INACTIVE, criteria failed (skipping)" % goal_no, "tfgoal")
	# Recurring tick: process_goals may have cascaded to goal_remove (e.g. via
	# GR_REMOVE_IMMEDIATELY or rv_g=self). If still INACTIVE, rearm.
	if goal_state == GoalState.INACTIVE:
		_start_timer()
	else:
		_timer_activator = null
