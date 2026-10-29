class_name ItemWeapon
extends EntityBase
## item_weapon — a weapon lying on the ground as a spellbook. Walk over it and the spell
## joins your loadout for the rest of the life.
##
## Not a Wizard Wars entity: WW shipped models/w_spellbook.mdl but never a pickup that used
## it. This is what /spawn <weapon> drops, and it works from a .bsp too.
##
## Keys: weapon (registry key, e.g. "comet_weapon"), model (override world model).
##
## Classname "combo_weapon" — or a "weapon" key of "combo" — is a book that hasn't decided yet:
## it becomes one of the combo spells at random. Each peer rolls its own, which costs nothing:
## the replicas are spinning scenery and only the host's roll is ever granted.
##
## HOST-AUTHORITATIVE: only the host polls for touches and grants; the pickup frees itself
## on grant and the dynamic-entity spawner despawns the replicas.

const DEFAULT_MODEL := "models/w_spellbook.mdl"
const COMBO_KEY := "combo"  # a "weapon" value asking for any combo spell rather than a named one
const PICKUP_SOUND := "items/gunpickup2.wav"
const SPIN_RATE := 1.2   # rad/s; visual only, so each peer spins its own copy

var _weapon_key := ""
var _model: Node3D
var _touch := TouchBehavior.new()


func _ready() -> void:
	super()
	_weapon_key = ent.get("weapon", "")
	if _weapon_key.is_empty() or _weapon_key == COMBO_KEY:
		_weapon_key = SpawnRegistry.random_combo_weapon()
	if not SpawnRegistry.has_weapon(_weapon_key):
		push_warning("item_weapon: unknown weapon '%s'" % _weapon_key)
		queue_free()
		return
	SoundSystem.precache(PICKUP_SOUND)
	_touch.initialize(self, _try_give)

	_model = AssetLoader.load_model(ent.get("model", DEFAULT_MODEL))
	if _model:
		add_child(_model)
		add_child(BlobShadow.new(0.3))
	rotation = parse_angles(ent)
	_touch.add_box()
	_seed_game_visible()


func _physics_process(delta: float) -> void:
	if _model:
		_model.rotate_y(SPIN_RATE * delta)
	_touch.tick(delta)


func _try_give(body: Node3D) -> bool:
	if not body.has_method("grant_weapon") or body.get("is_dead"):
		return false
	if not body.grant_weapon(_weapon_key):
		return false  # already carries it — leave the book for someone who doesn't
	SoundSystem.play_3d(PICKUP_SOUND, global_position)
	CommandSystem.notify_peer(node_peer_id(body), "Picked up %s." % _display_name())
	_entity.destroy()
	return true


func _display_name() -> String:
	var w := SpawnRegistry.build_weapon(_weapon_key)
	return w.get_display_name() if w else _weapon_key
