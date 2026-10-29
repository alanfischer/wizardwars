#!/usr/bin/env python3
"""Patch ww_golem so smashing a forward house closes the spawns inside it.

ww_golem's two forward spawn groups sit INSIDE breakable buildings — group 2
(team 1) is wholly inside house1's brush, group 4 (team 2) inside house3 (one of
its three sits on the roof). Nothing in the shipped map connects a house's
destruction to its spawns, so the golem can flatten a building players are
actively spawning in and they arrive in rubble, or on a roof that is gone.

Every piece needed to fix it already exists in the map's own scripting language:
`house1off` / `house3off` are the PotatoC entities the golem's impact trigger
fires, and `spawncheck1` is the 2-second poll that owns which groups are open.
This threads two new globals through those, plus `reset2` (the round reset):

  house1off    sets house1dead, closes group 2, reopens the team's home group 1
  house3off    same for house3dead / group 4 / group 3
  spawncheck1  will not reopen a forward group whose house is dead
  reset2       clears both flags, so the next round starts whole

Closed immediately AND gated in the poll, deliberately: the gate alone leaves up
to 2s where a destroyed house still spawns people. Each house also reopens its
team's home group as it closes the forward one, so a team is never momentarily
left with no active group at all.

The patch is derived from the entity text in the BSP, never hand-transcribed:
each target's code keys are concatenated, edited by exact substring replacement,
and re-emitted. Splitting back into code/code1/code2... is free because the
runtime simply concatenates them in order (see PotatoCEntity._ready), so the
chunk boundaries carry no meaning. Every replacement is guarded on its own
marker, so re-running the tool is a no-op.

Writes the BSP the way ww_clipbrush.py does: only the entity lump is rewritten
(bsp.save_entities); every other lump's bytes are unchanged.

NOTE: the runtime map cache keys off map_converter.CACHE_VERSION, not the BSP's
contents — bump that (or delete user://resources/maps/ww_golem*) or the stale
cached scene silently wins.

Usage:
  ww_golem_house_spawns.py <bsp> [--dry]
"""
import re
import sys

from bsp import Bsp


GLOBALS = "house1dead;house3dead;"
CHUNK = 120  # max chars per code key, matching how the map's author split his own

# targetname -> [(marker, find, replace)]. `marker` present in the concatenated
# code means this edit is already applied. `find` must appear exactly once.
PATCHES = {
    # Golem smashed the house: flag it, close the spawns inside it, and put the
    # team back on its home group in the same breath.
    "house1off": [
        ("house1dead", "TurnOff('house1');",
         "TurnOff('house1');house1dead=1;RemSG(2);ResSG(1);")],
    "house3off": [
        ("house3dead", "TurnOff('house3smoke');",
         "TurnOff('house3smoke');house3dead=1;RemSG(4);ResSG(3);")],
    # The 2s poll may only open a forward group while its house still stands.
    "spawncheck1": [
        ("house1dead", "if(x<-400&&y>-1200)", "if(x<-400&&y>-1200&&house1dead==0)"),
        ("house3dead", "if(x>400&&y>-1200)", "if(x>400&&y>-1200&&house3dead==0)")],
    # Round reset already rebuilds the houses; clear their flags alongside the
    # rock globals it resets on the same line.
    "reset2": [
        ("house1dead", "rock1=0;rock3=0;rock5=0;rock7=0;",
         "rock1=0;rock3=0;rock5=0;rock7=0;house1dead=0;house3dead=0;")],
}


def parse_kv(block):
    """Ordered [(key, value)] for one entity block."""
    return re.findall(r'"([^"]*)"\s+"([^"]*)"', block)


def is_code_key(k):
    return k == "code" or (k.startswith("code") and k[4:].isdigit())


def code_of(kv):
    """Concatenate code, code1, code2 ... in the order the runtime does."""
    codes = [(-1 if k == "code" else int(k[4:]), v) for k, v in kv if is_code_key(k)]
    return "".join(v for _, v in sorted(codes))


def split_code(code):
    """Chop into <=CHUNK pieces, preferring a break just after a ';'."""
    out = []
    while len(code) > CHUNK:
        cut = code.rfind(";", 0, CHUNK + 1) + 1
        if cut <= 0:
            cut = CHUNK
        out.append(code[:cut])
        code = code[cut:]
    out.append(code)
    return out


def patch_block(block, edits, name):
    kv = parse_kv(block)
    code = code_of(kv)
    if not code:
        raise SystemExit("ERROR: '%s' has no code keys" % name)
    changed = False
    for marker, find, repl in edits:
        if marker in code:
            continue  # already applied
        if code.count(find) != 1:
            raise SystemExit("ERROR: '%s': expected exactly one %r, found %d"
                             % (name, find, code.count(find)))
        code = code.replace(find, repl)
        changed = True
    if not changed:
        return block, False
    kept = [(k, v) for k, v in kv if not is_code_key(k) and k != "globals"]
    lines = ["{"]
    lines += ['"%s" "%s"' % (k, v) for k, v in kept]
    lines.append('"globals" "%s"' % GLOBALS)   # every toucher declares them: PotatoC
    for i, part in enumerate(split_code(code)):  # writes an UNdeclared name to a
        lines.append('"%s" "%s"'                 # per-run local scope, where it is
                     % ("code" if i == 0 else "code%d" % i, part))  # promptly lost
    lines.append("}")
    return "\n".join(lines), True


def patch_entities(text):
    edits, names = [], []
    for m in re.finditer(r"\{.*?\}", text, re.S):
        kv = dict(parse_kv(m.group(0)))
        name = kv.get("targetname", "")
        if kv.get("classname") != "potatoc" or name not in PATCHES:
            continue
        new, changed = patch_block(m.group(0), PATCHES[name], name)
        names.append(name)
        if changed:
            edits.append((m.start(), m.end(), new))
    missing = set(PATCHES) - set(names)
    if missing:
        raise SystemExit("ERROR: entities not found: %s" % ", ".join(sorted(missing)))
    out = text
    for start, end, new in reversed(edits):  # back-to-front keeps offsets valid
        out = out[:start] + new + out[end:]
    return out, len(edits)


def main(path, dry=False):
    b = Bsp(path)
    text = b.entities

    new_text, n = patch_entities(text)
    if n == 0:
        print("already patched — nothing to do")
        return
    print("patched %d entities" % n)
    for m in re.finditer(r"\{.*?\}", new_text, re.S):
        kv = dict(parse_kv(m.group(0)))
        if kv.get("classname") == "potatoc" and kv.get("targetname", "") in PATCHES:
            print("\n%s:\n  %s" % (kv["targetname"], code_of(parse_kv(m.group(0)))))
    if dry:
        print("\n--- (dry run, not written) ---")
        return

    b.entities = new_text
    print()
    b.save_entities()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1], dry="--dry" in sys.argv)
