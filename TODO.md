# TODO

## Performance: the physics tick

ww_2fort, 8 bots, release export under gl_compatibility (2026-11-22, after WW #77): the physics
step is ~40% of the main thread, about 4-7 ms per 60 Hz tick on an M1 Max, mostly GDScript. In
order of size (script profiler, debug build, so absolute numbers run high):

- Player movement, ~0.94 ms per tick for 8 bots (headless debug, after pmove's walk_move
  early-out). Per player-tick: simulate_tick ~55 us, mostly one move_and_slide ~20 us; get_modifiers
  ~50 us (hull probe ~18 of which body_test_motion ~7, water and ladder queries ~4.5 each,
  LadderWater.apply ~3, wet footing ~4, weapons ~3, status ~2.5); fire_frame and
  LagCompensation.record ~6 each. No single piece left is big; it is GDScript spread thin.
- Bots, ~1.0 ms per tick for 8 (bot_brain.tick ~0.18 self, ledge probes _drop_depth/_probe ~0.12).
  The A* re-path is a hitch rather than a cost: path_ids re-stamps all ~9.7k waypoint weights on
  nearly every query (~7 ms debug, about once a second across 8 bots). Almost every query brings
  a new salt or avoid set, not merely another bot's, so one AStar3D per bot would not help.

Smaller, per frame rather than per tick: BlobShadow casts a ray per shadow every frame, and the
voice mic's _process runs whenever the mic is open.

A headless dedicated server still runs visual-only _process work, ~0.9 ms per tick's worth:
BoneMerge ~0.28, BlobShadow ~0.24, puppet visual smoothing (_interpolate_from_buffer) ~0.28,
WeatherSystem ~0.06, voice mic ~0.05. Check what hitboxes read before skipping BoneMerge.

## Map fidelity

- Alternate textures (`+a`..`+j`) never switch. GoldSrc draws a brush entity's alternate
  sequence while its `pev->frame` is 1: func_button / func_rot_button while pressed
  (BUTTONS.CPP:720, 741), func_wall on each use (BMODELS.CPP:80), button_target on use or with
  SF_BTARGET_ON (BUTTONS.CPP:1245, 1252). No rotation map shows the gap today: ravine's and
  wstland4's `+a` lights are on worldspawn, which never switches, and chasm's are on
  func_wall_toggle, which hides rather than switching frame. With the GPU flipbook (goldsrc #82)
  the alternate set would be a second frame array on the material; materials are shared per
  (texture, lightmap page), so a switch has to be per entity (its own material or an instance
  uniform), not a write to the shared one.
