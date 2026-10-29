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

  Two seams the ClientJoin review named, both worth doing before or with the next peel:

  - `_on_reject_team_join` is a pure forwarder (`main.gd` 1007) only because
    `network_manager.gd`'s `_sync_handler` is a single slot that ClientSync already holds. Make it
    an `Array[Node]` with first-match-wins (register to the FRONT, so a later registrant shadows
    and today's replace semantics survive) and the handler moves into `client_join.gd` verbatim,
    with every future peel owning its own RPCs. `test_sync_dispatch.gd` passes unchanged — none of
    its four cases encode "exactly one handler"; `test_sync_name_rule.gd` needs `client_join.gd`
    appended to `HANDLER_SOURCES`. `_on_assign_spawn` should NOT move either way: it drives
    `spawn_at_transform` and clears main's `_recent_cmds`, so it is genuinely main's and its
    `clear_watchdog()` call is a real notification, not a workaround.
  - ClientJoin should own the class menu's lifecycle, not just borrow the reference. Main creates
    `_team_select_ui` in `_load_map` (VR branch included) and frees it in `_unload_map`, so the
    node holds a second copy nobody nulls — which is the only reason `abandon()` needs
    `is_instance_valid`, and `game.gd` already states the one-copy rule. `build_menu(parent)` /
    `teardown_menu()` would retire the guard. It is five more call sites than the signal, though:
    `main.gd` 993 (`show_ui` on spectating), 1185-1191 (`team_menu`/`class_menu` actions) and
    1206-1211 (VR menu) all poke the menu, and the first two duplicate the same
    `team != Team.NONE` test. Fold `_auto_team`/`_auto_class` in at the same time — they are join
    inputs, and `_set_game_active` 978-996 still holds the whole "come back on the scripted role,
    else put the menu up" policy, which is the ClientPerf treatment (flag table calls a setter,
    state lives in the node) that ClientJoin only got half of.

  Next: **map load/unload** (`_load_map` 681, `_unload_map` 821), the larger one. Note what
  ClientJoin exposed about it — `_unload_map`'s `keep` list is now eleven entries and every peel
  adds one, which is the shape of a "persistent children" registry rather than a literal. Two
  designs for that registry that do NOT work, checked: snapshotting `get_children()` at the end of
  `_ready` would catch all eleven, but `_ready` can tail-call `_on_lobby_host` (465) under `--host`,
  which loads a map, so the snapshot would have to be taken mid-`_ready`; and reparenting them
  under a `Systems` container breaks both spawners, whose `spawn_path` is pinned to `..` = Main
  (1648). A group marker or an `_add_system(node)` helper that records as it parents survives both.

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

- Investigate a PAS (potentially audible set). GoldSrc built it at map load by OR-ing together the
  PVS of every leaf in each leaf's PVS, and sent `MSG_PAS` temp entities and world sounds only to
  clients inside it. The port has only the PVS (`VisibilityManager` in goldsrc-godot), so the two
  `MSG_PAS` sends (the lightning cloud's zap, the staff's gunshot decal) and every
  `SoundSystem.play_3d` currently go to everyone, a superset. Questions: the bake cost on the
  big maps (PVS is per leaf, so PAS is leaves² bits before compression); whether it belongs in
  goldsrc-godot next to the PVS; and whether sounds should be PAS-filtered at all, given the port
  attenuates by `max_dist` already and a far sound costs a little bandwidth, not a wrong result.
