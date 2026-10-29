extends "res://src/tests/test_base.gd"
## What happens to a projectile or a summon when the wizard who cast it leaves — a disconnect, a
## round reset, /killbots. The reference it holds goes dangling, and GDScript refuses a freed
## object at a typed `attacker: Node3D` parameter: not a warning, a refusal that drops the whole
## damage call, so the hit deals NOTHING. Every holder has to drop a freed caster before it can
## reach damage credit.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const MagicMissileScript = preload("res://src/projectiles/magic_missile.gd")

const ARENA := Vector3(-240.0, 90.0, 0.0)  # clear of map geometry, and of the other suites'

## The typed `attacker` is the point: an untyped one would take the freed reference and hide this.
class DummyTarget extends Node3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var damage_taken := 0.0
	var credited: Array = []

	func take_damage(amount: float, _type: int, attacker: Node3D = null) -> void:
		damage_taken += amount
		credited.append(attacker)


func _missile_at(pos: Vector3) -> MagicMissile:
	var m: MagicMissile = MagicMissileScript.new()
	m.setup({"position": pos, "direction": Vector3.FORWARD}, true)
	_root().add_child(m)
	_keep(m)
	return m


func test_a_missile_outliving_its_caster_still_deals_its_damage() -> void:
	var target := DummyTarget.new()
	_root().add_child(target)
	_keep(target)
	var caster := Node3D.new()      # not _keep()'d: this test frees it on purpose
	_root().add_child(caster)

	var m := _missile_at(ARENA)
	m.owner_node = caster
	caster.free()                   # the wizard leaves while the missile is in the air
	await _tick(2)                  # physics_frame resumes BEFORE _physics_process, so two

	# typeof, not `== null`: a freed object compares equal to null and is falsy, so either of
	# those reads as "dropped" on the dangling reference this test is about.
	assert_eq(typeof(m.owner_node), TYPE_NIL, "the freed caster is dropped, not just dangling")

	m._hit_target(target)
	assert_eq(target.damage_taken, MagicMissile.MISSILE_DAMAGE, "the hit still lands")
	assert_eq(target.credited, [null], "credited to nobody, rather than refused outright")


## The drop hangs off the host tick, so a subclass that replaces _physics_process instead of
## _host_physics has to call it itself (Bird), and a class that is not a Projectile at all
## (RollingStone, Satchel, every summon) needs its own. One that forgets loses every hit made
## after its caster left — silently, since the error names only the damage helper. Checked
## against the source because there is no runtime seam that would catch a missing call.
func test_every_owner_holder_drops_a_freed_caster() -> void:
	for dir in ["res://src/projectiles", "res://src/monsters", "res://src/weapons"]:
		for file in DirAccess.get_files_at(dir):
			if not file.ends_with(".gd"):
				continue
			var src := FileAccess.get_file_as_string("%s/%s" % [dir, file])
			if not "var owner_node" in src:
				continue  # inherits Projectile's, which is dropped in its host tick
			assert_true("_forget_freed_owner" in src or "is_instance_valid(owner_node)" in src,
				"%s holds an owner_node of its own but never drops a freed one" % file)
