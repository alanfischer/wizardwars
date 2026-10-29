class_name GameConsts

const SCALE_FACTOR := 0.025
# GoldSrc maps are bounded to ±4096 units; farther than this is outside the world
# (e.g. satchel-teleported into a gap and falling) and the authority kills the player.
const WORLD_BOUND := 4096.0 * SCALE_FACTOR  # 102.4 m
const PUSH_SPEED_SCALE := 1.0  # global trigger_push speed multiplier — tune to match desired jump pad height
const PLAYER_CENTER := Vector3(0, 0.9, 0)  # half standing hull height — used for AoE/homing target center


# Fastest legitimate mover (golem falling) is 20 m/s; motion above this is a map-reset
# teleport, not travel, and ground-carry/kinematic-velocity-sync consumers must ignore it.
const MOVER_TELEPORT_SPEED := 120.0  # m/s

# Same teleport-vs-motion threshold for a spawned entity's published velocity, lower because
# their repositions are small (e.g. cocklebur snapping to a victim, ~1.5m/tick). Above this
# the client snaps to the new position instead of extrapolating away from it.
const ENTITY_PUBLISH_TELEPORT_SPEED := 60.0  # m/s

# Distance a mover can jump in one tick before ground-carry treats it as a teleport and
# releases the rider. Must equal NetworkManager.ENTITY_TELEPORT_DIST so the carry and the
# client interp buffer agree on teleport-vs-motion for the same synced mover.
const MOVER_TELEPORT_DIST := 12.0

## RAISING is the raise-dead cast taking a live wizard. It carries no status of its own; what
## marks it out is that the raising uses the body up, so the kill leaves no corpse (see
## RemotePlayer._on_died). A bone thrown by the skeleton afterwards is ordinary damage and does
## leave one — as it did in the original, which threw it as DMG_NEVERGIB.
enum DamageType { PHYSICAL = 0, FIRE = 1, ICE = 2, LIGHTNING = 3, DEATH = 4, RAISING = 5 }
enum StatusType { NONE = 0, POISON = 1, BURNING = 2, FROSTED = 3 }

const OVERHEAL_FACTOR := 1.5     # life ray can overheal to 150% max
const OVERHEAL_DRAIN := 1.0      # HP per second drain back to max_health

## A killing blow bigger than this tears the body apart instead of leaving it lying there —
## a wizard, a dragon, anything that would otherwise leave a corpse. It is the size of the
## LAST blow, not the overkill: a fireball bursts a wizard at full health as surely as a dying
## one, where a staff never does however little was left.
const GIB_DAMAGE := 30.0


## Did this blow tear the body apart? Lives here rather than on any one of the things it can
## happen to: a wizard asks, and so do a dragon and a bird shot out of the air.
static func damage_gibs(amount: float) -> bool:
	return amount > GIB_DAMAGE

# Physics collision layers (1-indexed, matching Godot project settings)
const LAYER_WORLD := 1       # World geometry (BSP faces, no sky — projectiles use this)
const LAYER_LADDER := 2      # Climbable surfaces
const LAYER_WATER := 3       # Water volumes
const LAYER_CORPSE := 4      # Corpses (non-interactive with players)
const LAYER_HAZARD := 5      # trigger_hurt volumes — query-only, so a colliderless entity (a projectile) can find the ones it is inside
const LAYER_CLIP := 6        # Clip brush collision (player movement only)
const LAYER_TRAP := 7        # Non-solid hittable traps (cockleburrs) — players walk through, melee can destroy
const LAYER_ENTITY := 8      # Solid placed entities (thornplants, beanstalks) — block player movement, not world geometry
const LAYER_WORLD_SKY := 9   # Sky-face trimesh (player movement only — projectiles pass through sky)
const LAYER_HITBOX := 10     # Per-bone hit volumes on player/monster models (Area3D, queryable-only)
# LAYER_PLAYER/LAYER_DYNAMIC = "locally simulated" (physics owned by this peer). Visual-only
# bodies (remote puppets, snapshot-driven entities) stay off these so triggers masking
# against them never see anything they can't authoritatively modify.
const LAYER_PLAYER := 11     # Player bodies (host puppets + own Client)
const LAYER_DYNAMIC := 12    # Dynamic physics bodies (satchel, rolling stone, …)
const LAYER_LAVA := 13       # Lava volumes — also on LAYER_WATER for swim physics
const LAYER_SLIME := 14      # Slime volumes — also on LAYER_WATER for swim physics

# Pre-computed collision masks (bit flags)
const MASK_WORLD := 1 << (LAYER_WORLD - 1)           # 1
const MASK_LADDER := 1 << (LAYER_LADDER - 1)          # 2
const MASK_WATER := 1 << (LAYER_WATER - 1)            # 4
const MASK_CORPSE := 1 << (LAYER_CORPSE - 1)          # 8
const MASK_HAZARD := 1 << (LAYER_HAZARD - 1)          # 16
const MASK_CLIP := 1 << (LAYER_CLIP - 1)              # 32
const MASK_TRAP := 1 << (LAYER_TRAP - 1)              # 64
const MASK_ENTITY := 1 << (LAYER_ENTITY - 1)          # 128
const MASK_WORLD_SKY := 1 << (LAYER_WORLD_SKY - 1)   # 256
const MASK_HITBOX := 1 << (LAYER_HITBOX - 1)          # 512
const MASK_PLAYER := 1 << (LAYER_PLAYER - 1)          # 1024
const MASK_DYNAMIC := 1 << (LAYER_DYNAMIC - 1)        # 2048
const MASK_LAVA := 1 << (LAYER_LAVA - 1)              # 4096
const MASK_SLIME := 1 << (LAYER_SLIME - 1)            # 8192
const MASK_FIELD_TRIGGER := MASK_PLAYER | MASK_DYNAMIC  # what trigger_push / trigger_gravity affect
const MASK_WORLD_AND_CLIP := MASK_WORLD | MASK_CLIP | MASK_WORLD_SKY  # 289 — player movement (world + clip + sky walls)
const MASK_MELEE := MASK_WORLD | MASK_TRAP | MASK_ENTITY | MASK_PLAYER  # melee hits world + traps + entities + player bodies
const MASK_HITSCAN := MASK_WORLD | MASK_HITBOX            # direct-hit weapons: world + per-bone hitboxes (areas)
## Bodies a door's touch volume answers to. Players have always been in it; monsters were not,
## because a summon was a short-lived prop on MASK_ENTITY that never had anywhere to walk to.
## A siege monster crossing a base is a walking participant, and a door it cannot even knock on
## is a wall. Used by FuncDoorBase and by the triggers that fire doors.
const MASK_DOOR_TOUCH := MASK_PLAYER | MASK_ENTITY

## Stamped on a body that may pass a team-gated door. The siege marks its monsters with it: they
## are on no playing team, so without it every base door on every map is shut to them and the
## wave piles up in the corridor outside. See FuncDoorBase._check_team.
const META_IGNORES_TEAM_DOORS := &"ignores_team_doors"

## What a point is submerged in. Lava and slime volumes carry MASK_WATER too (they swim the
## same), so the layer bits alone do not name a liquid — SpatialQuery.liquid_at_point does.
enum Liquid { NONE = 0, WATER = 1, SLIME = 2, LAVA = 3 }

# Hitbox groups (from MDL) — used for damage multipliers on headshots etc.
const HITBOX_GROUP_HEAD := 1
const HEADSHOT_MULT := 2.0

# Visual (render) layers — used for light cull masks
const VISUAL_LAYER_DEFAULT := 1   # Players, models, etc.
const VISUAL_LAYER_BSP := 2       # BSP world geometry
const LIGHT_CULL_ALL := VISUAL_LAYER_DEFAULT | VISUAL_LAYER_BSP  # 3 — weapon lights hit everything

# Custom movement flags — bits for InputCommand.custom_flags.
# Client sets these per-tick; server modifier callback reads them.
# Use powers of 2 for each new flag (1, 2, 4, 8, 16, ...).
const CMF_LEVITATING     := 1 << 0  # bit 0: held — reduced gravity while set
const CMF_LEVITATE_START := 1 << 1  # bit 1: edge — apply lift impulse this tick only
const CMF_FLYING         := 1 << 2  # bit 2: held — pitch-directed 3D flight, no gravity
const CMF_FORCEBLAST     := 1 << 3  # bit 3: edge — the caster's force blast kick, this tick only

enum Team { NONE = 0, BLUE = 1, RED = 2, YELLOW = 3, GREEN = 4 }
enum Element {
	ARCHMAGE = 1,
	LIFE = 2,
	DEATH = 3,
	FIRE = 4,
	ICE = 5,
	LIGHTNING = 6,
	NATURE = 7,
	EARTH = 8,
	WIND = 9,
}

const TEAM_COLORS := {
	Team.BLUE: Color(0.3, 0.4, 0.9),
	Team.RED: Color(0.9, 0.25, 0.2),
	Team.YELLOW: Color(0.9, 0.8, 0.2),
	Team.GREEN: Color(0.2, 0.8, 0.3),
}

const TEAM_NAMES := {
	Team.BLUE: "Blue",
	Team.RED: "Red",
	Team.YELLOW: "Yellow",
	Team.GREEN: "Green",
}

const ELEMENT_NAMES := {
	Element.ARCHMAGE: "archmage",
	Element.LIFE: "life",
	Element.DEATH: "death",
	Element.FIRE: "fire",
	Element.ICE: "ice",
	Element.LIGHTNING: "lightning",
	Element.NATURE: "nature",
	Element.EARTH: "earth",
	Element.WIND: "wind",
}

## The combo spells, keyed by the staff clash that earns one: two allied wizards of these
## elements beat their staves together until one of them walks away with the spell. This is also
## the complete pickup-only spell list — no class spawns holding one (see Wizard.pickup_weapons).
## The original mod had two more recipes, but both wanted the dragon wizard, a class this game
## doesn't have. Pairs are stored low element id first; look one up with combo_for().
const COMBO_RECIPES := {
	Vector2i(Element.LIFE, Element.NATURE): "spirit_wiz_weapon",
	Vector2i(Element.LIFE, Element.EARTH): "wombat_weapon",
	Vector2i(Element.DEATH, Element.FIRE): "meteor_weapon",
	Vector2i(Element.DEATH, Element.WIND): "raise_dead_weapon",
	Vector2i(Element.FIRE, Element.LIGHTNING): "ball_lightning_weapon",
	Vector2i(Element.ICE, Element.LIGHTNING): "lightning_cloud_weapon",
	Vector2i(Element.ICE, Element.NATURE): "giant_plant_weapon",
	Vector2i(Element.EARTH, Element.WIND): "tornado_weapon",
}


## The spell two elements make together, or "" if they make nothing. Order doesn't matter.
static func combo_for(a: int, b: int) -> String:
	return COMBO_RECIPES.get(Vector2i(mini(a, b), maxi(a, b)), "")


## Element id for a name ("fire", "ice", …), or -1 if unknown. Callers decide their own
## fallback (e.g. default to FIRE, or reject).
static func element_from_name(name: String) -> int:
	var lower := name.to_lower()
	for id in ELEMENT_NAMES:
		if ELEMENT_NAMES[id] == lower:
			return id
	return -1

const ELEMENT_COLORS := {
	Element.ARCHMAGE: Color(0.5, 0.7, 0.95),
	Element.LIFE: Color(0.95, 0.95, 0.95),
	Element.DEATH: Color(0.12, 0.1, 0.14),
	Element.FIRE: Color(0.9, 0.35, 0.1),
	Element.ICE: Color(0.2, 0.5, 0.9),
	Element.LIGHTNING: Color(0.95, 0.9, 0.2),
	Element.NATURE: Color(0.3, 0.7, 0.2),
	Element.EARTH: Color(0.6, 0.45, 0.25),
	Element.WIND: Color(0.55, 0.3, 0.75),
}

## What a damage type looks like, for any spell that has to show which one it is carrying — the
## skull an ally re-elemented, the death wizard's poison missile. Only the types that leave a
## status behind are here; PHYSICAL has nothing to show, so each spell falls back to its own
## plain colour rather than a shared "no element" one.
const DAMAGE_TYPE_COLORS := {
	DamageType.FIRE: Color(0.95, 0.15, 0.05),
	DamageType.ICE: Color(0.2, 0.5, 1.0),
	DamageType.LIGHTNING: Color(0.95, 0.9, 0.25),
	DamageType.DEATH: Color(0.3, 0.9, 0.2),
}

const ELEMENT_LABELS := {
	Element.ARCHMAGE: "Archmage",
	Element.LIFE: "Sanomancer",
	Element.DEATH: "Necromancer",
	Element.FIRE: "Pyromancer",
	Element.ICE: "Cryomancer",
	Element.LIGHTNING: "Fulgomancer",
	Element.NATURE: "Phytomancer",
	Element.EARTH: "Geomancer",
	Element.WIND: "Aeromancer",
}
