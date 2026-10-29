extends "res://src/tests/test_base.gd"
## The shipped MDLs must say where a head is, because nothing downstream guesses any more.
##
## GoldSrc reports a hit box's `group` as TraceResult.iHitgroup, and Combat.apply_hitscan_damage
## keys HEADSHOT_MULT off it. The models used to ship every box at group 0 and goldsrc-godot's MDL
## loader covered for them by searching the bone name for "head" -- game policy inside a shared
## importer, baking a guess into every derived .scn. tools/tag_mdl_head_hitboxes.py put the group
## in the files instead; this is what stops that silently coming undone.
##
## A head box reverting to group 0 removes headshots from that model with no other symptom: no
## error, no missing resource, just a multiplier that stops applying. Re-extracting models from
## ww1.3.0.exe would do it. So would a maintainer replacing one file. Hence a test on the bytes
## rather than on behaviour -- the two existing hitbox tests cover the behaviour, but only for
## synthetic Area3Ds they build themselves, so neither would notice.
##
## Fix a failure with: tools/tag_mdl_head_hitboxes.py --apply

## studiohdr_t: numhitboxes/hitboxindex sit after the bone and bone-controller counts.
const HDR_HITBOX_COUNT_OFF := 156
const HDR_BONE_COUNT_OFF := 140
const BONE_SIZE := 112
const HITBOX_SIZE := 32

## Every model whose head the game can shoot. Named rather than discovered: a model dropping off
## this list by being renamed or deleted is itself worth a failure.
const BODIES: Array[String] = [
	"res://models/player/archmage.mdl",
	"res://models/player/bear.mdl",
	"res://models/player/death.mdl",
	"res://models/player/earth.mdl",
	"res://models/player/fire.mdl",
	"res://models/player/ice.mdl",
	"res://models/player/life.mdl",
	"res://models/player/lightning.mdl",
	"res://models/player/nature.mdl",
	"res://models/player/wind.mdl",
	"res://models/dragon.mdl",
	"res://models/npc/goblin.mdl",
	"res://models/npc/wyvern.mdl",
	"res://models/combo/spiritwiz.mdl",
	"res://models/combo/wombat.mdl",
	"res://models/combo/giantplant.mdl",
]


## (bone_name, group) per hit box, straight out of the file.
func _hitboxes(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var d := f.get_buffer(f.get_length())
	f.close()
	if d.size() < 200 or d.decode_u32(0) != 0x54534449:  # "IDST"
		return []

	var num_bones := d.decode_s32(HDR_BONE_COUNT_OFF)
	var bone_index := d.decode_s32(HDR_BONE_COUNT_OFF + 4)
	var num_hitboxes := d.decode_s32(HDR_HITBOX_COUNT_OFF)
	var hitbox_index := d.decode_s32(HDR_HITBOX_COUNT_OFF + 4)

	var names: Array[String] = []
	for i in num_bones:
		var o := bone_index + i * BONE_SIZE
		var raw := d.slice(o, o + 32)
		var z := raw.find(0)
		names.append(raw.slice(0, z if z >= 0 else 32).get_string_from_ascii())

	var out: Array = []
	for i in num_hitboxes:
		var o := hitbox_index + i * HITBOX_SIZE
		var bone := d.decode_s32(o)
		out.append([names[bone] if bone >= 0 and bone < num_bones else "?", d.decode_s32(o + 4)])
	return out


func test_head_hitboxes_carry_hitgroup_head() -> void:
	for path in BODIES:
		assert_true(FileAccess.file_exists(path), "%s is shipped" % path)
		var hbs := _hitboxes(path)
		assert_gt(hbs.size(), 0, "%s parses as an MDL with hit boxes" % path)

		var heads := 0
		for hb in hbs:
			if "head" in String(hb[0]).to_lower():
				heads += 1
				assert_eq(hb[1], GameConsts.HITBOX_GROUP_HEAD,
					"%s: bone '%s' is a head box and must be tagged HITGROUP_HEAD" % [path, hb[0]])
		assert_gt(heads, 0, "%s has a head bone with a hit box on it" % path)


## The converse: nothing else may claim group 1, or it silently takes double damage. models/seals/
## shipped ten boxes on a bone called "root" at group 1 -- an authoring default, not an intent --
## which is part of why they were deleted.
func test_no_non_head_box_claims_hitgroup_head() -> void:
	for path in BODIES:
		for hb in _hitboxes(path):
			if hb[1] == GameConsts.HITBOX_GROUP_HEAD:
				assert_true("head" in String(hb[0]).to_lower(),
					"%s: bone '%s' claims HITGROUP_HEAD but is not a head" % [path, hb[0]])
