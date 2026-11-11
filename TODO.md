# TODO

- Keep peeling `main.gd`. Map load/unload is out (`Skybox`, `MapWorld`, `LocalView`, and
  `MapTransfer.ready_to_load`); what is left there peels separately:
  - VR setup: the rig, controllers, laser pointers, the lobby panel and its re-attach, and the
    head-clamped rig follow in `_process`. Living in main is why `LocalView` needs a second
    `bind_xr` once main has resolved the rig.
  - The unload sweep: main frees every child not in `_systems`, so each new system has to remember
    `_add_system` and `LocalView` needs a teardown that runs first. Each owner freeing what it
    built would shrink the sweep to the spawner-made bodies; `_release_override_materials` has to
    go with it.
  The rule the peels share: gameplay state comes off `Game`, node references come by injection.

  Each map still builds a new `SkyboxSky`, so the weather's `sky` is re-pointed per map; one per
  Skybox, re-measured with `OvercastSky.apply(params)`, would end the handover, but changes how
  storm state carries across a map change.

- Give the entities that never move a presence-only sync. 19 classes call `_register_for_sync()`
  and most are scenery — `env_sprite`, `light_entity`, `ambient_generic`, `info_tfgoal`,
  `item_healthkit` — which take a `MoverNetPublisher` purely because the MoverSync is also the PVS
  presence vehicle (`_set_present`). They then ship five transform slots that never change and take
  a `publish()` call per entity per net tick (ww_2fort alone has 160 env_sprites). A spec with no
  transform slots, registered the same way, would cost them nothing but the relevance events they
  actually want. Found while composing the mover protocol out of `EntityBase`.

- Extract a GoldSrc entity runtime as a fifth library. 40 of the 67 files in `src/entities/`
  name no WizardWars singleton outside a comment, and eight of those are still WW gameplay by
  name (`func_golem_*`, `golem_ladder`, `trigger_golem`, `siege_altar`, `ww_emitter`,
  `goal_messages`), so call it 32 genuinely generic: `func_door*`, `func_plat`, `func_platrot`,
  `func_train`, `func_tracktrain`, `func_rotating`, `func_pendulum`, `func_conveyor`,
  `func_water`, `func_ladder`, `func_button`, `func_rot_button`, `func_wall*`,
  `func_illusionary`, `multi_manager`, and most `trigger_*` and `env_*`. Nobody else loading a
  BSP through goldsrc-godot has them. Dependencies across that set: GameConsts (22 files),
  TriggerSystem (19), EntityRender (13), Log (7), GoldSrcEntity (6), AssetLoader (5).
  `trigger_system.gd` is 61 generic lines whose only non-generic statement is the authority gate
  at line 46, which is exactly `not NetworkManager.is_authority()`.

  Those files already lean on two WW-free modules: `EntityRender` (17 callers in
  `src/entities/`, two AssetLoader calls of its own) and `GoldSrcEntity` (11 callers, one
  GameConsts constant).

  What stands in the way is the other 27 files: the generic ones among them want eight host systems,
  not a few reach-throughs. `ambient_generic` → SentenceSystem; `env_beam` → BeamSystem; `env_model`
  → VisibilitySystem; `env_sound` and `func_door_base` → SoundSystem; `env_fade`, `env_shake`,
  `game_text` and `trigger_multiple` → NetworkManager's screen and HUD RPCs; `func_breakable` and
  `light_environment` → `sync_entity_state`; `trigger_multiple` → `Game.hud` / `Game.local_player`;
  `func_door_base` and `trigger_multiple` → Teams; `item_tfgoal` → `SpatialQuery.ground_y_below`;
  and `EntityBase` itself → `register_synced_entity`, `transport.relevance_events` and
  `VisibilitySystem.set_entity_game_visible`. `trigger_hurt` is not one of them: it only names
  SpatialQuery in a comment, and the point query runs from `Projectile._check_hazards` against the
  `hurt_volume` meta the trigger sets, which is already a decoupled contract.

  Tried and reverted 2026-10-11: one `EntityHost` autoload forwarding four of those calls. It worked
  and bought nothing — the seam has to carry sound, sentences, beams, visibility, HUD text and the
  entity-state protocol before a single entity file stops naming WizardWars, at which point it is an
  indirection layer over most of the game. Settle the shape before the plumbing: SoundSystem,
  SentenceSystem, BeamSystem, VisibilitySystem and SpatialQuery are platform the library can take by
  injection or ship itself, while Teams, Game and GoalSystem are gameplay that stays with the host.

## Library promotion

Every library is tagged (2026-11-09: goldsrc-godot v0.4.0, hop-godot v0.2.0, goldnet-godot v0.2.0,
overcast-godot v0.1.0, pmove-godot v0.1.0, hop and goldnet cores v0.1.0) and WW is pinned at the tags.

- goldnet-godot: Godot Asset Library, a write-up around the 25%-loss table, and each "What we
  wish Godot had" item filed as a godot-proposals issue linking back.
- pmove-godot: Asset Library, with a GIF of the demo.
- overcast-godot: the screenshots, in a showcase thread.
