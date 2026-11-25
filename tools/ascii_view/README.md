# ASCII view

Draws a running match as text, as a chase camera behind one wizard. Nothing in the game knows it
exists. It boots `src/main.tscn` from its own scene, keeps a renderer node beside it, and works
out what each thing is by looking at it.

```
tools/ascii_view/watch.sh                     # live, in this terminal
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
