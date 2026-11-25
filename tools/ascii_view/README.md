# ASCII view

Play Wizard Wars in a terminal, or watch a bot match there. The game is drawn as text: walls as
outlines, floors as `,`, water as `~`, and wizards as little figures with their element's hat,
coloured by team.

```
health 100  mana 80  weapon Missile  keys [W* RIGHT]  22 ms
:::|          /--\  |.............|--....................|.|........
::::\--\--/---....-\..............|......................|.|........
::::|...--.........|..............|....______o...........|.|........
:::::\......____...|..............|...|..|  /^\./----_____----------
::::::\....||'|.|..|.../_______------------/___\-------.........,,,,
::::::|--------------------................(o o).........,,,,,,,,,,,
:::::::\..................................__|=|__.|,,,,,,,,,,,,,,,,,
::::::::\..........................._____/__|||__\|,,,,,,,,,,,,,,,,,
:::::::::\.....................,,,__________|||___|,,,,,__,,,,,,/---
::::::::::--\_...,,,,,,,,,,,,,,,,,,,,,,,,,,,|||,,,,,,,,|_-------....
:::::::::::::|,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,/,\,,,,,,,,,|_..........
:::::::::::::/,,,,,,,,,,,,,,,,,,,,,,,,,,,,,/,,,\,,,,,,,,,|__........
::::::::+:::|,,,,,,,,,,,,,,,,,,,,,,,,,,,,,_|,,,|_,,,,,,,,,,|_.......
```

*An enemy Archmage (`^` hat) on a ledge in ww_wstland4. The `+` at the bottom left is the
crosshair.*

Nothing in the game knows this exists. It boots the game from its own scene and works out what
each thing is by looking at it. See [How a frame is drawn](#how-a-frame-is-drawn).

## Play

From the repository root:

```
tools/ascii_view/play.sh
```

That hosts a match on ww_2fort against 4 bots, with you as a blue Pyromancer. Game flags
replace those defaults:

```
tools/ascii_view/play.sh --map ww_wstland4 --bots 8 --team 1 --class fire
tools/ascii_view/play.sh --map ww_hunt --bots 6 --team 2 --class ice --botskill 0.3
```

`--team` is 1 (blue) or 2 (red). `--class` takes the element name: `fire`, `ice`, `lightning`,
`earth`, `wind`, `nature`, `life` or `death`. Any other game flag works too (`--timelimit`,
`--fraglimit`, …). `--botskill` runs from 0 (sloppy) to 1 (crack shot). ww_wstland4 is the smallest rotation map, so it's the quickest way into a
fight.

Ctrl-C quits and puts your terminal back the way it was.

### Controls

| Keys | |
|---|---|
| `w` / `s` | run forward / back. These **latch**: press once to start, again (or the opposite key) to stop |
| `a` / `d` | strafe while held |
| ← → ↑ ↓ | look. A tap nudges a few degrees; holding turns |
| `f` | fire (hold for continuous fire) |
| `g` | alt fire |
| `x` | satchel: hold to prime, let go to throw |
| `e` | use |
| `space` / `c` | jump / crouch |
| `1`–`9` | pick a spell slot |
| `q` / `r` | last spell / next spell |
| Ctrl-C | quit |

### The screen

- **The top line** shows your health, mana and spell, the keys the game thinks you're holding,
  and how long the last frame took to draw. A latched key shows with a star (`W*`).
- **The `+` in the middle** is your crosshair. Spells go where it points.
- **Team colours:** blue is team 1 and red is team 2. Teammates and enemies are coloured, and so
  are the flags. Water is cyan.
- **Wizards** grow from a `@` in the distance to a stick figure to a full figure with a hat as
  they get closer: `^` Archmage, `*` Pyromancer, `<>` Cryomancer, `Z` Fulgomancer, `m`
  Geomancer, `~` Aeromancer, `&` Phytomancer, `o` Sanomancer, `n` Necromancer. Right in your
  face, a wizard is drawn from its actual body parts: `@` head, `=` arms.
- **Other things:** `*` with a `.` trail is a projectile. `%` is a corpse. `|>` is a flag. `+` is
  a health pack, and `!` and `?` are other pickups.

### Tips

- **Run with `w`, steer with the arrows.** A terminal only repeats the last key you pressed, so
  holding `w` and then pressing an arrow would stop you running. That's why `w` latches.
- **Tap the arrows to aim, hold them to turn.** The first press nudges; the turn starts once your
  keyboard's key repeat kicks in.
- **Keys feel slightly sticky.** A terminal never says when you let go of a key, so a key counts
  as held until its repeats stop arriving. `play.sh` reads your macOS key-repeat settings to time
  this. Shorter settings in System Settings → Keyboard make it more responsive.
- **Bigger terminal, more detail.** The view fills your terminal, up to 140×45 cells. Past that,
  frames take too long to draw; `ASCII_COLS` and `ASCII_ROWS` override the cap.
- **Sound works.** The game plays its sounds as normal, which helps a lot.

### The little window in the corner

While you play, a small borderless window sits in the bottom-right corner of your screen. That's
the game itself. It needs a real window: the game only accepts looking and firing while the mouse
is captured, and a windowless game can't capture the mouse. The window never takes focus, so
your keyboard and mouse stay with the terminal. Leave it alone, and don't minimize it: a
minimized window stops drawing, and the game won't spawn you until a frame has been drawn.

### Changing the keys or turn speed

Everything is in the `play` section of `tools/ascii_view/rules.json`:

- **`keys`** maps a key to a game action. Use a single character, or `UP`, `DOWN`, `LEFT` or
  `RIGHT` for the arrows. Add `"latch": true` to make a key toggle, and `"opposite"` to name the
  action that cancels it.
- **`look_speed`** is how fast a held arrow turns, and **`look_nudge`** is how far a tap turns.
  Both are in mouse pixels, at the game's mouse sensitivity.
- **`hud`** lists what the top line shows: player properties, with a dotted path or a `()` call,
  such as `weapon.get_display_name()`.

### If something goes wrong

| What you see | Why, and what to do |
|---|---|
| "Starting Wizard Wars..." for more than a few seconds | The first run of a map converts it, which takes a while. Otherwise quit and read the game log; `play.sh` prints its path when it exits |
| The game log says "Failed to host" | Something else holds UDP 9050 or TCP 8080, usually a dedicated server. Stop it (`pkill -f "Godot.*--server"`) and start again |
| Nothing happens when you press keys | The keyboard went to the game window instead of the terminal. Click the terminal |
| The picture scrolls or flickers | The terminal is smaller than the frame. Make it bigger, or set `ASCII_ROWS` lower |
| Turning is too fast or too slow | Change `look_speed` / `look_nudge` in `rules.json` |
| `play.sh` can't find Godot | Set `GODOT=/path/to/Godot` |

## Watch

A bot match with a chase camera behind one bot. It runs headless, so no window appears, and it
needs the same free ports.

```
tools/ascii_view/watch.sh                          # ww_2fort, 8 bots
tools/ascii_view/watch.sh --map ww_chasm --bots 4
ASCII_FOLLOW=Bot_3 tools/ascii_view/watch.sh       # follow a particular bot
ASCII_FOLLOW=item_tfgoal tools/ascii_view/watch.sh # or follow a flag
```

To record frames to a file instead:

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
| `ASCII_FOV` | 90 | horizontal degrees (watching only; playing uses the game camera's) |
| `ASCII_EVERY` | 0.2 | seconds between frames (`play.sh` uses 0.066) |
| `ASCII_START` | 3 | seconds before the first frame |
| `ASCII_FRAMES` | 0 | quit after this many; 0 runs on |
| `ASCII_OUT` | stdout | file to write; replaced each frame unless `ASCII_APPEND=1` |
| `ASCII_COLOR` | off | `1` for ANSI colour (`watch.sh` turns it on) |
| `ASCII_FOLLOW` | first player | follow the first tracked node whose name contains this, e.g. `Bot_3`, `item_tfgoal` |
| `ASCII_KEYS` | unset | key file to read; set by `play.sh`, and it switches to the game's own camera |
| `ASCII_REPEAT_DELAY`, `ASCII_REPEAT_INTERVAL` | 0.375, 0.09 | seconds; `play.sh` reads them from macOS |
