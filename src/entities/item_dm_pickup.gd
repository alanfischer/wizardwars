class_name ItemDmPickup
extends EntityBase
## weapon_* / ammo_* — the GoldSrc deathmatch arsenal, which a wizard has no use for.
##
## Five of our maps were deathmatch maps first and still place Half-Life's guns and ammo boxes
## (ww_varrock alone has 84). Rather than drop them, each becomes whichever pickup the game
## style calls for:
##
##   combo chaos on    a spellbook holding one of the combo spells, rolled fresh on every respawn
##   combo chaos off   mana — a full pour from a gun, a sip from an ammo box
##
## The style is the map's to declare (info_wwdetect "combo_chaos") and the server's to override
## (/combo_chaos auto|on|off); see GoalSystem.is_combo_chaos. Changing it re-dresses the
## pickups already lying on the ground rather than waiting for them to be taken.
##
## HOST-AUTHORITATIVE: only the host polls for touches and grants; clients follow synced
## game-visibility, and their own roll of the spell is never used.

## Every weapon_/ammo_ classname Half-Life and TFC place, kept here rather than in Main's entity
## table because this is the script that answers for them. Stock HL spells several of these two
## ways (weapon_glock and weapon_9mmhandgun are the same gun), so both spellings are listed and a
## drop-in .bsp works either way.
const CLASSNAMES := [
	"weapon_crowbar", "weapon_9mmhandgun", "weapon_glock", "weapon_357", "weapon_python",
	"weapon_9mmAR", "weapon_mp5", "weapon_shotgun", "weapon_crossbow", "weapon_rpg",
	"weapon_gauss", "weapon_egon", "weapon_hornetgun", "weapon_handgrenade", "weapon_satchel",
	"weapon_tripmine", "weapon_snark",
	"ammo_9mmclip", "ammo_glockclip", "ammo_mp5clip", "ammo_9mmbox", "ammo_9mmAR",
	"ammo_ARgrenades", "ammo_mp5grenades", "ammo_buckshot", "ammo_357", "ammo_crossbow",
	"ammo_rpgclip", "ammo_gaussclip", "ammo_egonclip",
]

const BOOK_MODEL := "models/w_spellbook.mdl"
const MANA_MODEL := "models/backpack.mdl"
const BOOK_SOUND := "items/gunpickup2.wav"
const MANA_SOUND := "items/ammopickup1.wav"
const WEAPON_MANA := 50.0  # a gun was the big prize on the map, so it pours
const AMMO_MANA := 20.0
const RESPAWN_TIME := 30.0
const SF_NORESPAWN := 1 << 30
const SPIN_RATE := 1.2  # rad/s; visual only, so each peer spins its own copy

var _model: Node3D
var _model_path := ""
var _chaos := false
var _weapon_key := ""
var _mana := WEAPON_MANA
## _dress on respawn: a fresh roll of the spell, and the style may have changed while it was gone.
var _touch := TouchBehavior.new()


func _ready() -> void:
	super()
	_register_for_sync()
	_touch.initialize(self, _try_give, _dress)
	if not (parse_spawnflags(ent) & SF_NORESPAWN):
		_touch.respawn_time = RESPAWN_TIME
	if str(ent.get("classname", "")).begins_with("ammo_"):
		_mana = AMMO_MANA
	SoundSystem.precache(BOOK_SOUND)
	SoundSystem.precache(MANA_SOUND)
	rotation = parse_angles(ent)
	_touch.add_box()

	add_child(BlobShadow.new(0.3))
	# Deferred: the style is declared by info_wwdetect, which is a node in the same map like any
	# other and readies whenever its turn comes — in ww_varrock, after every pickup on the map.
	# Waiting a frame means dressing against the style the map actually asked for.
	_dress.call_deferred()
	ServerVars.value_changed.connect(_on_server_var_changed)
	_seed_game_visible()


## Become the pickup the current style calls for: on spawn, on respawn (which is where the spell
## is rolled again) and when the style changes under a live map.
func _dress() -> void:
	_chaos = GoalSystem.is_combo_chaos()
	_weapon_key = SpawnRegistry.random_combo_weapon() if _chaos else ""
	var wanted := BOOK_MODEL if _chaos else MANA_MODEL
	if _model_path == wanted:
		return
	_model_path = wanted
	if _model:
		_model.queue_free()
	_model = AssetLoader.load_model(wanted)
	if _model == null:
		push_warning("item_dm_pickup: failed to load %s" % wanted)
		return
	add_child(_model)
	# Re-track so _compute_local_aabb sees the real mesh AABB — otherwise PVS uses the origin
	# point alone and the pickup vanishes when that point clips into a solid leaf.
	if _entity.entity_id >= 0:
		VisibilitySystem.untrack_node(_entity.entity_id)
		VisibilitySystem.track_node(_entity.entity_id, self)


func _on_server_var_changed(key: String, _value: Variant) -> void:
	if key == "combo_chaos" and _touch.available:
		_dress()


func _physics_process(delta: float) -> void:
	if _model:
		_model.rotate_y(SPIN_RATE * delta)
	_touch.tick(delta)


func _try_give(body: Node3D) -> bool:
	if body.get("is_dead"):
		return false
	if _chaos:
		if not body.has_method("grant_weapon") or not body.grant_weapon(_weapon_key):
			return false  # already carries that spell — leave the book for someone who doesn't
		CommandSystem.notify_peer(node_peer_id(body), "Picked up %s." % _display_name())
	else:
		if not body.has_method("add_mana"):
			return false
		# CBaseEntity::TakeHealth's rule, applied to mana: no room means it isn't consumed.
		if float(body.get("mana")) >= float(body.get("max_mana")):
			return false
		body.add_mana(_mana)

	SoundSystem.play_3d(BOOK_SOUND if _chaos else MANA_SOUND, global_position)
	_touch.take()
	return true


func _display_name() -> String:
	var w := SpawnRegistry.build_weapon(_weapon_key)
	return w.get_display_name() if w else _weapon_key
