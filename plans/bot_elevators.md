# Riding lifts: what bots need to play ww_storm and ww_2fort's shafts

## The gap

The fill samples a static world at one instant. A platform you *ride* is not
geometry you *walk*, so a `func_plat` / `func_platrot` is invisible to it: the
deck is sampled wherever it happens to be resting, the level it serves is not
connected to it, and no edge in the graph ever says "stand here and wait".

This is not the same as the door handling already in `src/bot/waypoint_bake.gd`,
which fast-forwards `BAKE_WARMUP_SEC` of round start and then deletes doors still
shut. That works because a door's two states are *open* and *closed* — one of them
is the play-time topology. A lift's two states are both real and the bot has to
move between them deliberately.

Two maps pay for it:

* **ww_storm** loses a whole game mode. Both capture dropoffs sit on top of a
  `func_platrot`, so the bake has no node within 4m of either (nearest is 7.2m
  away and 4.5m below; nothing in the graph is above y 1.62 while the dropoff
  plate is at y 2.9). Bots reach the enemy grail and carry it home fine, then
  mill under the lift because the objective is somewhere the graph cannot
  describe. Fixing the lift fixes storm's scoring.
* **ww_2fort** is subtler. Its hand-authored HPB file *does* link the lift
  shafts, because the human who placed those waypoints rode them — so the edges
  exist and nothing in the file says a lift is involved. `WP_GIVEUP` gives up on
  a waypoint it is not closing on and A* routes around, which is right when an
  alternative exists; where the lift is the only way, the bot re-tries it on an
  escalating penalty forever. The baked graph has the opposite failure: it never
  invents a lift edge, so those routes simply do not exist.

## What already works

* **The physics.** `netmove` carries riders itself (`MovementState.carry_motion`,
  see `godot_body.gd` and `PlayerMovementContext`), so a bot standing on a moving
  deck moves with it. Nothing needs doing here.
* **The entities.** `func_plat` exposes its two stops directly: `position1` is the
  top, `position2` is `(0, -height, 0)`, both relative to `_base_position`. A
  freestanding plat starts at the bottom and builds a call volume spanning the
  whole travel zone, so *touching it is what summons it*. A plat with a
  targetname starts at the top and moves only when triggered.
* **The round-start simulation** in `waypoint_bake.gd` already settles timed
  chains before sampling, so a lift's resting pose at bake time is the one bots
  will meet.

## Baker: teach the fill a lift is a bridge between two stops

Model a lift the way ladders are already modelled by `_link_ladders` — as a
synthetic connection between two real landings, not as walkable floor.

1. **Find the lifts.** Collect `FuncPlat` and `FuncPlatRot` (and any `FuncDoor`
   whose travel is vertical and whose brush is a floor rather than a barrier —
   the drawbridge lesson in `waypoint_bake.gd` applies, so classify by whether the
   deck's top face is standable, not by class name).
2. **Derive both stops.** From `_base_position + position1` and
   `+ position2`, with the deck's top surface taken from its AABB. That gives two
   world-space deck rectangles without moving anything.
3. **Sample the deck at both stops.** Run the existing floor probe over the deck
   rectangle at each stop height. These become nodes flagged `FL_LIFT`
   (bit 20 is free). They are *not* linked to each other by the normal edge
   tests — a 4m vertical gap is neither a walk, a jump nor a survivable-drop
   edge, and the geometric tests would reject it anyway.
4. **Link each stop to its landing.** For each stop, try ordinary edges from the
   deck nodes to whatever floor sits within a step of that stop's height. This is
   where `_try_edge` earns its keep: the deck at the bottom stop genuinely is
   walk-on-able from the lower floor.
5. **Add the ride edge.** Link bottom-deck ↔ top-deck directly, flagged
   `FL_LIFT`, bypassing the geometric tests. Direction matters: a triggered plat
   that only descends when called gives a one-way ride until something sends it
   back, so emit the reverse edge only when the entity can be summoned from the
   far stop (freestanding plats, which have a call volume spanning the shaft).
6. **Re-check objective coverage.** ww_storm's dropoffs sit *on* the deck, so
   once the deck is sampled the cap nodes come with it — but the coverage
   diagnostic measures straight-line distance to a static position and the plate
   moves. Coverage for a goal riding a mover should be measured against the
   deck's stops, not its bake-time pose.

## Brain: a waypoint you stand still on

Riding is the first behaviour where *not moving is correct*, and almost every
anti-stuck mechanism in `bot_brain` is built to punish exactly that. The work is
mostly in teaching them to shut up.

1. **Ride state.** On arriving at an `FL_LIFT` node, latch "riding": hold
   position on the deck, face the exit landing, and advance the route only when
   the deck reaches the far stop (test the bot's own height against the target
   stop, not the platform's state, so it survives the platform being interrupted).
2. **Summon it.** A freestanding plat comes when touched — so simply standing on,
   or stepping into, the call volume is enough. A triggered plat needs whatever
   fires it; if nothing a bot can do will move it, the ride edge should not have
   been emitted in the first place (step 5 above).
3. **Suppress the watchdogs while riding.** All of these will otherwise fire on a
   stationary bot:
   - `WP_GIVEUP` / `_wp_min_id` no-progress watchdog — would penalise the lift
     node and re-route around the only way up.
   - The wedge detector (`WEDGE_T` 12s, `WEDGE_DIST` 0.15) — would teleport the
     bot to spawn mid-ride.
   - `PENNED_GIVEUPS` — same.
   - The anti-stuck hop — hopping on a moving deck is how you fall off it.
   The cleanest shape is one `_riding` flag consulted by each, rather than four
   independent exemptions.
4. **Give up honestly.** A bot that has waited `LIFT_PATIENCE` (the shaft's
   travel time plus a margin, derivable from `move_speed` and the stop
   separation) without arriving should drop the route and re-path, so a lift
   blocked by another player is not a permanent trap.

## What to measure

* **ww_storm**: scoring events in a 600s soak. It is 0 today — the grail gets
  carried home and the cap never happens. Any capture at all is the result.
* **ww_2fort**: bake it, delete nothing, and check the baked graph reaches the
  upper floors the hand file reaches via its lift edges. The hand file is the
  reference for what *should* be connected.
* **Regression**: the 19-map sweep. Lifts exist on maps nobody has looked at, and
  a synthetic `FL_LIFT` edge that the mover cannot actually perform is exactly the
  kind of thing that looks fine in the bake statistics and strands bots in play.

## Order

Storm first. Its objective sits on the deck, so it exercises sampling, linking
and riding in one map, and it has an unambiguous pass mark: the scoreboard moves.
2fort's shafts are the harder case (several lifts, alternatives around most of
them) and are better attempted once riding is known to work.
