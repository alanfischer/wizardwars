#!/usr/bin/env python3
"""Declare (or clear) combo chaos on a map, in its BSP entity lump.

Combo chaos turns a converted deathmatch map's leftover Half-Life pickups -- the weapon_*
and ammo_* entities -- into random combo spellbooks instead of mana. The map asks for it
with a "combo_chaos" key on its game-rules entity:

    "classname" "info_wwdetect"
    "combo_chaos" "1"

info_wwdetect (or TFC's info_tfdetect, which our InfoTFDetect script also answers for) is
the one map-wide rules entity every WW map is supposed to carry. The catch is that the maps
which actually have the DM pickups are the ones with no rules entity at all -- they were
plain deathmatch maps, so nobody placed one -- and this tool creates a minimal info_wwdetect
in that case. It carries nothing but the flag, which is exactly what a rules entity with no
teams to configure should say.

Both directions are idempotent. The entity lump is rewritten by bsp.save_entities, which
also drops the stale cached .scn so the game reconverts the edited map.

Usage:
  ww_combo_chaos.py show   <bsp>...          # what each map declares today
  ww_combo_chaos.py set    <bsp> [--dry]     # declare combo chaos
  ww_combo_chaos.py clear  <bsp> [--dry]     # stop declaring it
"""
import os
import re
import sys

from bsp import Bsp

DETECT_RE = r'"classname"\s+"(?:info_wwdetect|info_tfdetect)"'


def blocks(text):
    return re.findall(r"\{.*?\}", text, re.S)


def show(path):
    text = Bsp(path).entities
    detects = [b for b in blocks(text) if re.search(DETECT_RE, b)]
    flags = [re.search(r'"combo_chaos"\s+"([^"]*)"', b) for b in detects]
    state = next((f.group(1) for f in flags if f), None)
    guns = len(re.findall(r'"classname"\s+"(?:weapon|ammo)_[A-Za-z0-9_]*"', text))
    print("%-18s detect=%-2d combo_chaos=%-6s weapon/ammo pickups=%d"
          % (os.path.basename(path)[:-4], len(detects), state if state else "--", guns))


def write_entities(bsp, text, dry):
    if dry:
        print("--- rules entity after the edit (dry run, not written) ---")
        for b in blocks(text):
            if re.search(DETECT_RE, b):
                print(b.strip())
        return
    bsp.entities = text.rstrip()
    bsp.save_entities()


def first_origin(text):
    """Somewhere sensible to stand a created rules entity: a spawn point, else the world origin."""
    for b in blocks(text):
        if re.search(r'"classname"\s+"info_player_(?:deathmatch|start|teamspawn)"', b):
            m = re.search(r'"origin"\s+"([^"]*)"', b)
            if m:
                return m.group(1)
    return "0 0 0"


def set_flag(path, on, dry=False):
    bsp = Bsp(path)
    text = bsp.entities
    detects = [b for b in blocks(text) if re.search(DETECT_RE, b)]

    # Whatever it said before, say it once and say it here.
    for b in detects:
        stripped = re.sub(r'\s*"combo_chaos"\s+"[^"]*"', "", b)
        text = text.replace(b, stripped)

    if not on:
        # A rules entity this tool created, holding nothing else, goes away with the flag.
        for b in blocks(text):
            if re.search(DETECT_RE, b) and len(re.findall(r'"[^"]*"\s+"[^"]*"', b)) <= 2:
                text = text.replace(b, "").strip() + "\n"
        print("%s: combo chaos cleared" % os.path.basename(path))
        return write_entities(bsp, text, dry)

    if detects:
        target = [b for b in blocks(text) if re.search(DETECT_RE, b)][0]
        text = text.replace(target, target.rstrip()[:-1].rstrip() + '\n"combo_chaos" "1"\n}')
        print("%s: combo chaos declared on its existing rules entity" % os.path.basename(path))
    else:
        text = text.rstrip() + '\n{\n"origin" "%s"\n"classname" "info_wwdetect"\n"combo_chaos" "1"\n}\n' \
            % first_origin(text)
        print("%s: no rules entity — created an info_wwdetect for the flag"
              % os.path.basename(path))
    return write_entities(bsp, text, dry)


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("show", "set", "clear"):
        print(__doc__)
        sys.exit(1)
    cmd, args = sys.argv[1], [a for a in sys.argv[2:] if not a.startswith("--")]
    dry = "--dry" in sys.argv
    for bsp in args:
        if cmd == "show":
            show(bsp)
        else:
            set_flag(bsp, cmd == "set", dry)
