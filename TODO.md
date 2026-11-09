# TODO

- Keep peeling `main.gd` (2016 lines, 80 methods). ClientSync was the first peel; ClientPerf
  (`src/systems/client_perf.gd`, done 2026-10-11) was the second — the overlay, the [ClientPerf]
  report and the scene inventory, plus `--perf-log`/`--perf-quit` and their `_process`/
  `_physics_process` hooks, all of which the node now runs for itself. ClientJoin
  (`src/systems/client_join.gd`, done 2026-10-11) was the third: the nine methods from
  `_on_team_class_selected` to `_join_watchdog`, the three class-change fields and the two watchdog
  ones, down to four call sites on main (`bind_menu`, `select_team_class`, `clear_watchdog`,
  `abandon`). The rule the three peels share: gameplay state comes off `Game` (`Game.local_player`,
  `Game.hud`) and node references come by injection, so ClientSync and ClientPerf each bind main for
  one specific node and ClientJoin, needing none, binds nothing.

  Both seams the ClientJoin review named are done: sync handlers are a list, newest first, so
  `_on_reject_team_join` lives in `client_join.gd`; and ClientJoin owns the class menu
  (`build_menu`/`teardown_menu`, `open_team_menu`/`open_class_menu`) and the `--team`/`--class`
  role, with `start_game()` holding the "come back on the scripted role, else put the menu up"
  policy. Main's remaining calls are the two setters, `build_menu`, `teardown_menu`, `start_game`,
  the two opens and `clear_watchdog`.

  Next: **map load/unload** (`_load_map`, `_unload_map`), the larger one. The persistent-children
  registry it needed is done: `_add_system(node)` records main's long-lived children as it parents
  them, and `_unload_map` frees everything else.

- Retire the offline class-change path's private copy of a mechanism `Player` already has.
  `client_join.gd`'s `_queue_local_class_change` / `_on_local_class_change_timeout` reach into
  LocalPlayer's privates from outside — read `_respawn_timer`, disconnect the player's own
  `_respawn` Callable from it, substitute their own, and later null the field — with three fields
  and a `_waiting` latch to keep that swap honest. `player.gd` 339 `die_for_class_change(team,
  element)` is the same mechanism on the object that owns it, documented as safe to call
  repeatedly while counting down, and the authoritative path already uses it
  (`server_requests.gd` 172). Found during the ClientJoin peel review; left alone there because a
  pure move was the commit's job.

  Three things to settle rather than assume, which is why this is its own item and not a cleanup:
  `die_for_class_change` guards only `if not is_dead`, so it would `die()` a never-spawned
  spectator that the current `was_alive` check deliberately spares (a `spectating` guard on it
  would also harden the server path); `local_player.gd` 1054-1060, the consumer that would start
  carrying this, is dead code today — nothing sets `class_change_pending_team` on a LocalPlayer, so
  it has never run; and `_finish_class_change` currently calls `apply_local_spawn_state` and then
  `_join_team` -> `spawn_at`, which re-runs `reset_for_spawn` + `_on_spawn_state_reset`, so the two
  routes are not bit-identical today. That double reset is worth fixing on its own terms, but note
  it is load-bearing in one case: when `get_spawn_for_team` returns null, the first reset is what
  still applies the new element. While in there, `_join_team`'s `is_online()` branches are
  unreachable — `_finish_class_change` is only reached from the offline tail of
  `select_team_class` — and they are a fourth copy of the `set_player_team` +
  `sync_team_for_peer.rpc` pair (`bot_system.gd` 107, `remote_player.gd` 1489,
  `server_requests.gd` 193).

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

  The EntityUtil split (done 2026-10-11) gave those files two WW-free modules to lean on:
  `EntityRender` (17 callers in `src/entities/`, two AssetLoader calls of its own) and
  `GoldSrcEntity` (11 callers, one GameConsts constant).

  What stands in the way is the other 27 files, and it is NOT a short list of reach-throughs —
  the "exactly four" this bullet used to claim was wrong. Audited 2026-10-11: the generic ones
  among them want eight host systems, not four functions. `ambient_generic` → SentenceSystem;
  `env_beam` → BeamSystem; `env_model` → VisibilitySystem; `env_sound` and `func_door_base` →
  SoundSystem; `env_fade`, `env_shake`, `game_text` and `trigger_multiple` → NetworkManager's
  screen and HUD RPCs; `func_breakable` and `light_environment` → `sync_entity_state`;
  `trigger_multiple` → `Game.hud` / `Game.local_player`; `func_door_base` and `trigger_multiple`
  → Teams; `item_tfgoal` → `SpatialQuery.ground_y_below`; and `EntityBase` itself →
  `register_synced_entity`, `transport.relevance_events` and
  `VisibilitySystem.set_entity_game_visible`. `trigger_hurt` is not one of them: it only names
  SpatialQuery in a comment, and the point query runs from `Projectile._check_hazards` against
  the `hurt_volume` meta the trigger sets, which is already a decoupled contract.

  Tried and reverted 2026-10-11: one `EntityHost` autoload forwarding the four calls this bullet
  used to name. It worked and bought nothing — the seam has to carry sound, sentences, beams,
  visibility, HUD text and the entity-state protocol before a single entity file stops naming
  WizardWars, at which point it is an indirection layer over most of the game. Settle the shape
  before the plumbing: SoundSystem, SentenceSystem, BeamSystem, VisibilitySystem and SpatialQuery
  are platform the library can take by injection or ship itself, while Teams, Game and GoalSystem
  are gameplay that stays with the host.

- Send sounds and `MSG_PAS` temp entities to the PAS. `VisibilityManager` has it now
  (`is_position_audible_to_observer`, goldsrc-godot #77) and `VisibilitySystem.peers_hearing` picks
  the peers, but nothing calls it yet. The original sent every non-static sound to the PAS
  (`SV_StartSound`); the port has no occlusion, so today they play through walls: within
  320u, 15% of sound pairs on ravine and ~6% on hunt and roc2 sit outside the PAS. Wire
  `SoundSystem.play_3d`, the lightning cloud's zap (`send_entity_event`) and the staff's gunshot decal
  (`DecalSystem.place_rpc`, a `call_local` broadcast today). Check how the original made the golem's
  clap and steps before filtering them; the port carries them 40 m and 20 m on purpose. The
  original's other `MSG_PAS` sends — spirit wizard beam, `env_bubbles`, `env_explosion`, the
  earthquake satchel's torus — need their port paths checked too.
- `VisibilitySystem` does two jobs: client render culling, and choosing which peers get a send
  (`peers_seeing`, `peers_hearing`, the epochs). The second could be its own autoload.

## Library APIs (review 2026-11-09)

Each item is a branch + PR in its own submodule, then a pin bump here. Done so far: Godot 4.7
minimums, WW internals out of the READMEs, goldsrc-godot's metadata table as the one hull spec,
goldnet-godot's Usage first with `GoldNetMultiplayer.new()`, hop's pipeline private, pmove's
classes prefixed (goldsrc-godot #74, goldnet-godot #52, hop #110, hop-godot #83,
pmove-godot #16, WW #48); `GoldSrcBSP` and `GoldSrcMDL` as RefCounted loaders whose
`build_scene()` returns the finished scene, MDL skins and sequences included, and team skins
that apply and take the map's lighting (goldsrc-godot #75 and #76, WW #50).

goldsrc-godot:

- Split `GoldSrcBSP`: the light grid, sun fraction and rain floor bakers into their own classes
  or files.
- The rain floor is weather in an asset loader. It is a "first solid surface going down" query;
  name it that.

hop (core):

- Replace the tuning setter/getter pairs on `simulator` with a `simulator_config` struct with
  documented defaults; point the README at the handful people change.
- Header comments narrate history ("used to phrase it differently…"); make them say what is.
- Reconcile "zero-allocation simulation" with `std::shared_ptr` being required for every solid and
  shape.

overcast-godot:

- Split the ground state (snow, ice and wetness fields, and their net sync: three values, heat
  events, the late-join cell grids) out of `OvercastWeather` into its own object.

Then tag every library once, after the changes above, so each first or next release carries
its final API: overcast-godot, pmove-godot, the hop core and the goldnet core have never been
tagged; goldsrc-godot, hop-godot and goldnet-godot have moved past their last tags. Hold
overcast's API a week or two without breaking changes before its tag. Pin WW at the tags.

Promotion, once tagged:

- goldnet-godot: Godot Asset Library, a write-up around the 25%-loss table, and each "What we
  wish Godot had" item filed as a godot-proposals issue linking back.
- pmove-godot: Asset Library, with a GIF of the demo.
- overcast-godot: the screenshots, in a showcase thread.
