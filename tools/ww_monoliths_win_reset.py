#!/usr/bin/env python3
"""Patch ww_monoliths so the command points reset to their starting colours on a win.

ww_monoliths is a sequential warpath: blue owns point 1 and pushes 2-3-4-5, red
owns point 5 and pushes 4-3-2-1. Taking the enemy's home point wins the round,
after which `victory` restores every goal and re-fires `cap1` / `cap5` to hand
each home point back to its owner.

The GOAL side of that reset is complete. The VISUAL side is not: each point's
colour is an env_beam recoloured by env_render, plus a pair of START_OFF lights
that the map drives with TOGGLE fires, and the two win multi_managers do not
undo the same things.

  `b5` (blue wins on point 5) is nearly right -- it whites out beams 2/3/4,
  puts beam 5 back to red, and pre-toggles blight1 off so cap1's re-toggle
  lights it again. It only forgets to clear its own blight5.

  `r1` (red wins on point 1) is the broken mirror. It fires beam_b1 and beam_r1
  at the SAME delay, and equal delays fire in key order (GoldSrc bubble-sorts
  them stably, so does MultiManager here), so beam_r1 lands last and point 1
  stays RED for the next round. It also never whites out beam 4, never clears
  the rlight1 it just switched on, and never pre-toggles rlight5 off -- so
  cap5's re-toggle turns red's own home light OFF instead of on.

Measured before this patch, red winning left: beam1 RED (want BLU), beam4 RED
(want WHT), rlight1 ON (want off), rlight5 off (want ON).

The fix is entirely in those two multi_managers:
  r1  beam_r1 2 -> 0   (keep the capture flash, stop it clobbering the reset)
      + beam_w4 2      (white out point 4 like b5 does)
      + rlight1#1 2    (clear the capture light)
      + rlight5 2      (so cap5's toggle re-lights red's home point)
  b5  + blight5#1 2    (clear the capture light)
      + beam_b5 0      (flash point 5 blue on capture, mirroring r1's beam_r1)

beam_b5 is an env_render the mapper built and then never wired to anything, so
blue taking point 5 turned no beam at all while red taking point 1 turned one.
Firing it at delay 0 against the existing beam_r5 at 2 is exactly the
flash-then-restore pair r1 now has.

`name#suffix` keys are how GoldSrc lets a multi_manager fire one target twice
(UTIL_StripToken cuts at the '#'); MultiManager here strips it the same way.

Writes the BSP the way ww_clipbrush.py / ww_setsky.py do: the rewritten entity
lump is appended at EOF and lump 0 is repointed, so no other lump moves.

NOTE: the runtime map cache keys off map_converter.CACHE_VERSION, not the BSP's
contents -- delete user://resources/maps/ww_monoliths.{scn,hash,version} (or
bump CACHE_VERSION) or the stale cached scene silently wins.

Usage:
  ww_monoliths_win_reset.py <bsp> [--dry]
"""
import re
import sys

from bsp import Bsp

# targetname -> [(marker, find, replace), ...]. Each edit is guarded by its own
# marker so the tool stays re-runnable as edits are added to a block over time.
PATCHES = {
    "r1": [
        # Flash point 1 red on capture, then let the delay-2 reset batch win.
        ('"beam_r1" "0"',
         '"beam_b1" "2"\n"beam_r1" "2"', '"beam_r1" "0"\n"beam_b1" "2"'),
        # White out point 4 too, and undo both of red's own point lights.
        ('"rlight5"', '"beam_w3" "2"',
         '"beam_w3" "2"\n"beam_w4" "2"\n"rlight1#1" "2"\n"rlight5" "2"'),
    ],
    "b5": [
        # Clear the capture light, and give blue the beam flash red already had.
        ('"blight5#1"', '"beam_r5" "2"', '"beam_r5" "2"\n"blight5#1" "2"'),
        ('"beam_b5"', '"blight5" "0"', '"blight5" "0"\n"beam_b5" "0"'),
    ],
}


def patch(path, dry=False):
    b = Bsp(path)
    ent_text = b.entities

    changed = False
    for targetname, edits in PATCHES.items():
        pat = (r'\{[^{}]*"targetname"\s+"%s"[^{}]*"classname"\s+"multi_manager"[^{}]*\}'
               % re.escape(targetname))
        m = re.search(pat, ent_text)
        if not m:
            print("multi_manager %r not found" % targetname)
            return 1
        block = m.group(0)
        new_block = block
        for marker, find, repl in edits:
            if marker in new_block:
                print("multi_manager %r: %s already applied" % (targetname, marker))
                continue
            if new_block.count(find) != 1:
                print("multi_manager %r: %r appears %d times, expected 1"
                      % (targetname, find, new_block.count(find)))
                return 1
            new_block = new_block.replace(find, repl)
        if new_block == block:
            continue
        print("--- multi_manager %r ---\n%s" % (targetname, new_block))
        ent_text = ent_text[:m.start()] + new_block + ent_text[m.end():]
        changed = True

    if not changed:
        print("nothing to do")
        return 0
    if dry:
        print("--- (dry run, not written) ---")
        return 0

    b.entities = ent_text
    b.save_entities()
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    sys.exit(patch(sys.argv[1], dry="--dry" in sys.argv))
