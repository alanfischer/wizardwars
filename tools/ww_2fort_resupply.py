#!/usr/bin/env python3
"""Unstick ww_2fort's basement resupply doors.

Each of the map's six resupply closets is a func_door with two trigger_multiples on it, one
either side, so walking up to it from in or out opens it. Four of them carry `wait .001` on
those triggers and work: the door shuts behind you (its own `wait 2`), you step back toward
it, and it opens again straight away.

The two basement closets -- blue_resupply_3 and red_resupply_3, the only pair down at
z -507 -- carry `wait 10` instead. `wait` on a trigger_multiple is ActivateMultiTrigger's
reset time: once it has fired, that trigger is deaf for that long, to anyone. So you open the
door, walk in, the door shuts two seconds later, and the inside trigger will not fire again
until ten seconds after you tripped it. You are shut in a resupply closet for the rest of it.

Nothing is special about the basement rooms, and the other four prove the intent, so this is
a typo in the map and the fix is to make those four triggers read like the other eight.

Re-runnable: it only ever rewrites `wait` on triggers targeting *_resupply_3.

Usage:
  ww_2fort_resupply.py <bsp> [--dry]
"""
import re
import sys

from bsp import Bsp

DOORS = ("blue_resupply_3", "red_resupply_3")
WAIT = ".001"            # what the four working closets' triggers use


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    dry = "--dry" in argv
    if len(args) != 1:
        print(__doc__)
        return 2
    bsp = Bsp(args[0])
    text = bsp.entities
    patched = 0
    for block in bsp.find("trigger_multiple"):
        if Bsp.key(block, "target") not in DOORS:
            continue
        was = Bsp.key(block, "wait")
        if was == WAIT:
            continue
        fixed = re.sub(r'("wait"\s+")[^"]*(")', r"\g<1>%s\g<2>" % WAIT, block)
        text = text.replace(block, fixed)
        print('%s trigger: wait "%s" -> "%s"' % (Bsp.key(block, "target"), was, WAIT))
        patched += 1
    if not patched:
        print("nothing to do -- already patched")
        return 0
    bsp.entities = text
    bsp.save_entities(dry=dry)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
