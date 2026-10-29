class_name WizardClone
extends Node3D

## Visual illusion clone spawned by the aeromancer's Clone spell.
## Drifts in its assigned direction, fades out, then disappears.

const LIFETIME := 3.0
const FADE_START := 1.5   # seconds at full opacity before fading begins
const INITIAL_ALPHA := 0.85

var _entity := EntityBehavior.new()
var _model: Node3D
var _anim_player: AnimationPlayer = null
var _staff_model: Node3D
var _bone_merge: BoneMerge
var _direction := Vector3.FORWARD
var _speed := 0.0
var _model_path := ""
var _staff_path := ""
var _team := 0


func setup(data: Dictionary, is_host := true) -> void:
	position = data.get("position", Vector3.ZERO)
	_direction = (data.get("direction", Vector3.FORWARD) as Vector3).normalized()
	_speed = data.get("speed", 0.0)
	_model_path = data.get("model_path", "models/player/wind.mdl")
	_staff_path = data.get("staff_path", "")
	_team = data.get("team", 0)
	_entity.initialize(self, is_host)


func _ready() -> void:
	_model = AssetLoader.load_model(_model_path)
	if _model:
		_model.position.y = 0.9
		_strip_collision(_model)
		add_child(_model)
		add_child(BlobShadow.new())
		AssetLoader.set_model_alpha(_model, INITIAL_ALPHA)
		AssetLoader.set_model_skin(_model, _team)

		_anim_player = _model.find_child("AnimationPlayer")
		_entity.set_anim_player(_anim_player)
		if _anim_player and _anim_player.has_animation("run2"):
			var anim := _anim_player.get_animation("run2")
			anim.loop_mode = Animation.LOOP_LINEAR
			_anim_player.play("run2")

	_load_staff()

	if _direction.length_squared() > 0.001:
		look_at(global_position + _direction, GeomUtil.safe_up(_direction))

	# Creation + replication handled by the dynamic-entity MultiplayerSpawner (spawn_dynamic_entity).

	var tween := create_tween()
	tween.tween_interval(FADE_START)
	tween.tween_method(_set_alpha, INITIAL_ALPHA, 0.0, LIFETIME - FADE_START)
	tween.tween_callback(_die)


## On the physics tick, not _process: this is the authoritative position NetInterpBridge
## publishes (it samples on the tick), and moving it off-tick fights physics interpolation.
func _physics_process(delta: float) -> void:
	if _entity.is_host:
		position += _direction * _speed * delta


func _load_staff() -> void:
	if not _model or _staff_path.is_empty():
		return
	var staff_model := AssetLoader.load_model(_staff_path)
	if not staff_model:
		return
	staff_model.position.y = 0.9
	add_child(staff_model)
	_staff_model = staff_model
	AssetLoader.set_model_alpha(_staff_model, INITIAL_ALPHA)

	var player_skel: Skeleton3D = _model.find_child("Skeleton3D")
	var staff_skel: Skeleton3D = staff_model.find_child("Skeleton3D")
	if player_skel and staff_skel:
		_bone_merge = BoneMerge.attach(staff_skel, player_skel)


func _set_alpha(alpha: float) -> void:
	if _model:
		AssetLoader.set_model_alpha(_model, alpha)
	if _staff_model:
		AssetLoader.set_model_alpha(_staff_model, alpha)


func _die() -> void:
	_entity.destroy()


static func _strip_collision(node: Node) -> void:
	for child in node.get_children():
		if child is StaticBody3D:
			child.queue_free()
		else:
			_strip_collision(child)


## Animation rides the shared NetInterp slot (see EntityBehavior.set_anim_player).
func net_sync_properties() -> PackedStringArray:
	return PackedStringArray(["NetInterp:net_anim"])
