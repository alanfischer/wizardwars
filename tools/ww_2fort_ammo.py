#!/usr/bin/env python3
"""Add four neutral ammo-and-grenade backpacks to ww_2fort.

ww_2fort only ever hands out ammo in the spawn rooms: 24 team-locked
`info_tfgoal` backpacks, twelve per team. This drops four more into the
contested ground between them, mirrored across the map's axis (x' = -x + 64,
y' = -y) so both halves get the same two, and with no `team_no` so either team
can take them.

Payload is the map's own backpack minus the heal: TFC ammo (shells/nails/
cells/rockets -> mana) plus `no_grenades_1/2` (-> satchels, or a combo spell
when combo chaos is on). Respawns `wait` seconds after a pickup.

Re-runnable: previously injected packs are stripped by their marker key first.

Usage:
  ww_2fort_ammo.py <bsp> [--dry]
"""
import re
import sys

from bsp import Bsp

MARKER = "ww_ammo_pack"          # targetname, so a re-run replaces its own work

# Floor-level spots; the pack rides FLOOR_LIFT above each, the way the map's own
# 24 backpacks do -- backpack.mdl is centred on its origin, so a pack placed at
# floor Z is half-sunk in it.
FLOOR_LIFT = 20
FLOOR_SPOTS = [
    (448, 1736, 202),
    (-955, 1750, -374),
    (-382, -1736, 202),
    (1027, -1750, -374),
]
ORIGINS = [(x, y, z + FLOOR_LIFT) for (x, y, z) in FLOOR_SPOTS]

KEYS = [
    ("classname", "info_tfgoal"),
    ("targetname", MARKER),
    ("mdl", "models/backpack.mdl"),
    ("goal_activation", "1"),    # TFGA_TOUCH
    ("goal_effects", "1"),       # TFGE_AP — affects the toucher
    ("goal_state", "2"),         # inactive: sitting there waiting to be touched
    ("ammo_shells", "500"),
    ("ammo_nails", "500"),
    ("ammo_cells", "500"),
    ("ammo_rockets", "200"),
    ("no_grenades_1", "4"),
    ("no_grenades_2", "4"),
    ("noise", "weapons/scock1.wav"),
    ("wait", "5"),               # respawn delay, matches the map's own packs
]


def build_entities():
    blocks = []
    for (x, y, z) in ORIGINS:
        lines = ["{", '"origin" "%d %d %d"' % (x, y, z)]
        lines += ['"%s" "%s"' % kv for kv in KEYS]
        lines.append("}")
        blocks.append("\n".join(lines))
    return "\n".join(blocks)


def inject(path, dry=False):
    b = Bsp(path)
    ent_text = re.sub(r'\{[^{}]*"targetname"\s+"%s"[^{}]*\}\s*' % MARKER,
                      "", b.entities).rstrip()

    block = build_entities()
    if dry:
        print(block)
        print("--- (dry run, not written) ---")

    b.entities = ent_text + "\n" + block
    if b.save_entities(dry=dry, quiet=True) and not dry:
        print("wrote %s: %d ammo packs; backup at %s.bak" % (path, len(ORIGINS), path))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    inject(sys.argv[1], dry="--dry" in sys.argv)
