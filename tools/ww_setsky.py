#!/usr/bin/env python3
"""Set (or add) the worldspawn "skyname" key in a GoldSrc BSP.

Some WizardWars maps ship with no skyname in worldspawn, so the runtime loads
no skybox (black void). Every other map carries the key in the BSP entity lump,
so we patch it there to stay consistent.

Usage:
  ww_setsky.py <bsp> <skyname> [--dry]
"""
import re
import sys

from bsp import Bsp


def set_skyname(path, sky, dry=False):
    b = Bsp(path)

    # Locate the worldspawn entity block (first entity that declares it).
    m = re.search(r'\{[^{}]*"classname"\s+"worldspawn"[^{}]*\}', b.entities)
    if not m:
        print("no worldspawn entity found")
        return
    block = m.group(0)

    key = '"skyname" "%s"' % sky
    if re.search(r'"skyname"\s+"[^"]*"', block):
        new_block = re.sub(r'"skyname"\s+"[^"]*"', key, block)
    else:
        # insert the key right after the opening brace
        new_block = block.replace("{", "{\n" + key, 1)

    if new_block == block:
        print("skyname already set to %r, nothing to do" % sky)
        return

    if dry:
        print("--- patched worldspawn ---")
        print(new_block)

    b.entities = b.entities[:m.start()] + new_block + b.entities[m.end():]
    b.save_entities(dry=dry)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    set_skyname(sys.argv[1], sys.argv[2], dry="--dry" in sys.argv)
