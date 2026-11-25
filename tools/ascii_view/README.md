# ASCII view

Draws a running match as text, and lets you play it from the terminal. Nothing in the game knows
it exists. It boots `src/main.tscn` from its own scene, keeps a renderer node beside it, and works
out what each thing is by looking at it.

## Play

```
tools/ascii_view/play.sh                                    # ww_2fort, 4 bots, blue fire
tools/ascii_view/play.sh --map ww_chasm --bots 6 --team 2 --class ice
```

| Keys | |
|---|---|
| `w` / `s` | run forward / back. These latch: press again, or the opposite key, to stop |
| `a` / `d` | strafe |
| arrows | look. A tap nudges, holding turns |
| `space` `c` | jump, crouch |
| `f` `g` `x` `e` | fire, alt fire, satchel, use |
| `1`–`9` `q` `r` | spell slot, last spell, next spell |
| Ctrl-C | quit |

You see through the game's own camera, with a crosshair and a status line.

**Held keys.** A terminal sends no key-up, only the OS key repeat, so a key counts as held while
its repeats keep arriving. Only the last key pressed repeats, which is why running latches: you
can run, turn and fire at once. `play.sh` reads your repeat delay and rate from macOS settings.

**The game window.** Playing needs a real window, because the game reads look and fire only with
the mouse captured, and a headless display can't capture. A borderless 160×90 window sits in the
bottom-right corner. It can't take focus, so the captured mouse stays a mode the game sees, and
your cursor and keyboard stay with the terminal. It hosts the match, so UDP 9050 and TCP 8080 must
be free.

The frame fills the terminal up to 140×45; set `ASCII_COLS`/`ASCII_ROWS` to override.

## Watch

```
tools/ascii_view/watch.sh                     # a bot match, chase camera
tools/ascii_view/watch.sh --map ww_chasm --bots 4
```

or record frames to a file:

```
ASCII_OUT=frames.txt ASCII_APPEND=1 ASCII_FRAMES=20 ASCII_EVERY=1 \
  Godot --headless --path . res://tools/ascii_view/ascii_view.tscn -- --server --map ww_2fort --bots 8
```

## How a frame is drawn

1. **World rays.** One ray per cell against `world_layers`. Each cell keeps depth, normal, hit
   point and owner. This is the z-buffer.
2. **World glyphs.** Outlines go where a neighbour is off this cell's plane or bends away from it.
   The nearer side of a step draws the outline. Everything else is shaded by surface: `,` floors,
   `'` ceilings, a ramp for walls, `~` liquids.
3. **Entities.** Each tracked entity, far to near, picks the tallest template in
   `templates.txt` that fits its projected height and draws it at its own depth. A glyph lands
   only where the world ray in that cell hit something farther away. A wizard in a doorway is
   cut by the frame, and something smaller than a cell still claims its cell if nothing is in
   front of it.
4. **Close up.** Once a figure is taller than any template, it is drawn from its hitboxes
   instead: rays against `hitbox_layers`, capped at the world depth. Hitbox group 1 (from the
   MDL, via goldsrc-godot) is the head; bone names give arms and legs.

## What things are

`rules.json` maps nodes to kinds. The first rule matching a node wins. A rule matches on

- `script`: a global class name anywhere in the node's script inheritance chain
- `native`: an engine class (`is_class`)
- `name`: a node-name glob

and can read node properties for `tags` (template variants such as `dead`), `hat` (the `$` in a
template) and `color` (an ANSI SGR code). Each is a `{property: {value: result}}` lookup. An empty
property name gives a constant. Facing and velocity are observed between frames, never asked
for.

The `play` section maps terminal keys to the game's input actions and lists the status-line
properties. Keys go in as ordinary `InputEventAction`s and mouse motion.

All game-specific knowledge lives in the rules file. If the game renames a class or property,
the fix goes here.

## Settings

All are environment variables, because the game reports unknown command-line flags.

| Variable | Default | |
|---|---|---|
| `ASCII_COLS`, `ASCII_ROWS` | 120, 40 | cells |
| `ASCII_FOV` | 90 | horizontal degrees |
| `ASCII_EVERY` | 0.2 | seconds between frames |
| `ASCII_START` | 3 | seconds before the first frame |
| `ASCII_FRAMES` | 0 | quit after this many; 0 runs on |
| `ASCII_OUT` | stdout | file to write; replaced each frame unless `ASCII_APPEND=1` |
| `ASCII_COLOR` | off | `1` for ANSI colour (`watch.sh` turns it on) |
| `ASCII_FOLLOW` | first player | follow the first tracked node whose name contains this, e.g. `Bot_3`, `item_tfgoal` |
| `ASCII_KEYS` | unset | key file to read; set by `play.sh`, and it switches to the game's own camera |
| `ASCII_REPEAT_DELAY`, `ASCII_REPEAT_INTERVAL` | 0.375, 0.09 | seconds; `play.sh` reads them from macOS |
