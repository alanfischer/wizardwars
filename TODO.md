# TODO

## Performance: the physics tick

ww_2fort, 8 bots, release export under gl_compatibility (2026-11-22, after WW #77): the physics
step is ~40% of the main thread, about 4-7 ms per 60 Hz tick on an M1 Max, mostly GDScript. In
order of size (script profiler, debug build, so absolute numbers run high):

- Player movement, ~0.9 ms per tick for 9 players. PlayerMovementContext.get_modifiers is ~35 us
  a call (headless debug). The physics-server part is down to the hull probe's body_test_motion
  ~7 us (BSP hull walks) and ~1.5 us per area query. The rest is pmove GDScript: HullContacts
  ~10 us around that probe (reading its contacts ~4, corrections + unstick ~4, carry ~2),
  LadderWater.apply ~4, weapon modifiers ~3.
- VisibilitySystem._physics_process, ~0.55 ms: _refresh_entry_aabb on ~430 entries a tick
  compares transforms of entities that never move. The set_notify_transform wake that
  MoverNetPublisher uses (WW #77) fits here too.
- hop's _flush_queries, ~4.5% of the thread: a state-sync callback to every kinematic body each
  flush whether it moved or not (plus a Callable::is_valid per body), and the area overlap tests.
- send_entity_transforms still sweeps all synced entities every tick for freed ones.

Smaller, per frame rather than per tick: BlobShadow casts a ray per shadow every frame, and the
voice mic's _process runs whenever the mic is open.

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
