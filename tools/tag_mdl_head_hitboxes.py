#!/usr/bin/env python3
"""Tag head hit boxes in the shipped MDLs with HITGROUP_HEAD, so nothing has to guess later.

GoldSrc reports a hit box's `group` as TraceResult.iHitgroup, and that is what a headshot
multiplier keys off. Wizard Wars' own body models ship every box at group 0 (HITGROUP_GENERIC)
with the head box sitting on a bone that says "head" in its name -- so the group field carries
no anatomy and the game cannot tell a head from a knee.

goldsrc-godot used to paper over this inside the MDL loader: when it saw group 0 it searched the
bone name for "head" and reported group 1 anyway. That is game policy living in a shared asset
importer, it reads the files as saying something they do not say, and because both the editor
importer and resource_converter.gd bake the answer into their .scn output, the guess was frozen
into derived artifacts where nobody could see it.

This fixes the data instead. Four bytes per head box, in place, no offset in the file moves --
the same byte surgery tools/mdl.py already does for vertices, and for the same reason: studiomdl
is a Windows tool and the .qc/.smd sources are not in the repo, so the compiled .mdl *is* the
editable source.

    tools/tag_mdl_head_hitboxes.py            # show what would change, touch nothing
    tools/tag_mdl_head_hitboxes.py --apply    # write it
    tools/tag_mdl_head_hitboxes.py --check    # exit 1 if any head box is still untagged

Run --apply again after re-extracting models from an installer; it is idempotent, and --check is
what test_mdl_hitbox_groups.gd calls so a silent regression fails the suite instead of quietly
removing headshots.

A box that already carries an explicit non-zero group is never touched -- models/combo/
raisedead.mdl uses the full HL convention and is right as it stands.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mdl

HITGROUP_HEAD = 1

# "head" as its own word or as the stem of one: `head`, `head1`, `headtop`, `Bip01 Head`.
# Deliberately not a bare substring search -- that is what the loader did, and it would also
# claim a `forehead` or a `headband`. Neither exists in the current set, but the rule should
# not depend on that staying true.
HEAD_BONE = re.compile(r"(?:^|[^a-z])head(?:[0-9]*|top|bottom|base|mid)?$", re.IGNORECASE)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def mdl_paths():
    for base, _dirs, files in os.walk(os.path.join(ROOT, "models")):
        for f in sorted(files):
            if f.lower().endswith(".mdl"):
                yield os.path.join(base, f)


def candidates(path):
    """Head boxes in this model that still read as HITGROUP_GENERIC."""
    try:
        m = mdl.Mdl(path)
    except (ValueError, OSError, IndexError):
        return None, []
    return m, [hb for hb in m.hitboxes()
               if hb["group"] == 0 and HEAD_BONE.search(hb["bone_name"])]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--apply", action="store_true", help="write the tags")
    g.add_argument("--check", action="store_true", help="exit 1 if anything is untagged")
    args = ap.parse_args()

    pending = []
    for path in mdl_paths():
        m, hbs = candidates(path)
        if hbs:
            pending.append((path, m, hbs))

    if not pending:
        print("all head hit boxes are tagged HITGROUP_HEAD")
        return 0

    for path, _m, hbs in pending:
        rel = os.path.relpath(path, ROOT)
        names = ", ".join("%s[%d]" % (hb["bone_name"], hb["index"]) for hb in hbs)
        print("%-38s %d  %s" % (rel, len(hbs), names))

    if args.check:
        print("\n%d model(s) still rely on bone-name guessing" % len(pending), file=sys.stderr)
        return 1
    if not args.apply:
        print("\n%d model(s) would change; re-run with --apply" % len(pending))
        return 0

    for path, m, hbs in pending:
        for hb in hbs:
            m.set_hitbox_group(hb["index"], HITGROUP_HEAD)
        m.save()
    print("\ntagged %d box(es) across %d model(s)"
          % (sum(len(h) for _p, _m, h in pending), len(pending)))
    print("re-run ./convert.sh --force --resources-only (and reimport in the editor) --"
          " hitbox_group is baked into every derived .scn")
    return 0


if __name__ == "__main__":
    sys.exit(main())
