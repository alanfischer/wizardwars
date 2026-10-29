#!/usr/bin/env python3
"""Make ww_golem's two liquid pads hurt: the lava one burns, the icy one is slime.

ww_golem's water is almost all worldspawn brushwork -- 568 faces of !waterblue
baked into the BSP with no entity at all. Sitting apart from it are two small
func_water brushes, 256x256x32 each and clearly a matched pair:

  *35  !ww_icy   at ( 896..1152, 128..384, 0..32)
  *36  !ww_lava  at (-1280..-1024, 128..384, 0..32)

Both ship as `skin -3`, which is CONTENTS_WATER. So despite the textures they
are plain water: you can stand in the lava and nothing happens. The textures
were decoration and the contents were never set to match.

This patch sets them to what they look like:

  *35  skin -3 -> -4   CONTENTS_SLIME
  *36  skin -3 -> -5   CONTENTS_LAVA

Nothing else has to change. `skin` is the only input to the damage path:
FuncWater ORs MASK_SLIME / MASK_LAVA onto the pad's Volume Area3D, and
PlayerMovementContext.tick_liquid_damage runs a shape query against those masks
every LIQUID_DMG_INTERVAL (0.5s), applying LAVA_DMG_PER_TICK 5.0 as FIRE and
SLIME_DMG_PER_TICK 2.0 as PHYSICAL. That machinery already carries ww_volcano
and ww_keep; these pads simply were not declared into it.

Two visible side effects, both of them the map becoming self-consistent:
  - the lava pad finally MOVES like lava. liquid_type is read from skin, so it
    picks up the slow wide warp instead of water's.
  - the icy pad warps at slime's rate. Subtler, and the reason to eyeball it.
Their transparency does not change: with rendermode 0 the alpha path leaves the
liquid shader on its own water_alpha default of 0.6 either way.

Only two `skin -3` keys exist in the lump and both are these pads, so the match
is unambiguous -- the map's other 15 skins are goal-model skins of 1 plus one
func_illusionary at -1.

Writes the BSP the way ww_clipbrush.py / ww_setsky.py / ww_monoliths_win_reset.py
do: only the entity lump is rewritten (bsp.save_entities); every other lump's
bytes are unchanged. Re-running is a no-op once the skins are already set.

NOTE: the runtime map cache keys off map_converter.CACHE_VERSION, not the BSP's
contents -- delete user://resources/maps/ww_golem.{scn,hash} (or bump
CACHE_VERSION) or the stale cached scene silently wins.

Usage:
  ww_golem_liquid_skins.py <bsp> [--dry]
"""
import re
import sys

from bsp import Bsp

# model key -> (expected shipped skin, wanted skin, what it becomes)
WANTED = {
    "*35": ("-3", "-4", "slime"),
    "*36": ("-3", "-5", "lava"),
}


def patch(path, dry=False):
    b = Bsp(path)
    ent_text = b.entities

    changed = False
    for block in re.finditer(r"\{[^{}]*\}", ent_text):
        text = block.group(0)
        model = re.search(r'"model"\s+"([^"]*)"', text)
        if not model or model.group(1) not in WANTED:
            continue
        was, want, label = WANTED[model.group(1)]
        skin = re.search(r'"skin"\s+"([^"]*)"', text)
        if not skin:
            print("%s: no skin key -- not the entity this expects" % model.group(1))
            return 1
        if skin.group(1) == want:
            print("%s: already %s (skin %s)" % (model.group(1), label, want))
            continue
        if skin.group(1) != was:
            print("%s: skin is %r, expected the shipped %r -- refusing to guess"
                  % (model.group(1), skin.group(1), was))
            return 1
        new_text = text[:skin.start(1)] + want + text[skin.end(1):]
        print("%s: skin %s -> %s (%s)" % (model.group(1), was, want, label))
        ent_text = ent_text[:block.start()] + new_text + ent_text[block.end():]
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
