# Server-Authoritative Movement with Client-Side Prediction

## Directory Structure

```
netmove/
  movement.gd            # Pure movement simulation (static functions)
  input_command.gd        # InputCommand data class
  prediction_buffer.gd    # Client-side prediction + reconciliation
  server_movement.gd      # Server-side per-peer input processing
  tests/
    test_movement.gd
    test_input_command.gd
    test_prediction_buffer.gd
    test_server_movement.gd
    test_integration.gd   # Needs scene tree + CharacterBody3D
```

## Data Types

### InputCommand (RefCounted)

```
seq: int                  # monotonic sequence number
move_input: Vector2       # x=right, y=forward (raw WASD/stick)
yaw: float                # body rotation.y
pitch: float              # camera pitch (for water/ladder look-direction)
jump: bool                # held
jump_just_pressed: bool   # edge-triggered (single frame)
crouch: bool              # held
walk: bool                # held
noclip: bool              # active
delta: float              # physics delta this tick
```

Wire format: single RPC with typed args, booleans packed into a flags bitmask.

### MovementState (inner class of Movement)

```
position: Vector3
velocity: Vector3
is_crouched: bool
is_jumping: bool
on_floor: bool
on_ladder: bool
ladder_normal: Vector3
in_water: bool
gravity_scale: float      # default 1.0
eye_y: float              # camera eye height (crouch interpolation)

# Generic modifiers — game sets these before simulate_tick
friction_scale: float     # default 1.0 (game: frost, ice, etc.)
accel_scale: float        # default 1.0 (game: buffs, debuffs)
speed_scale: float        # default 1.0 (game: haste, slow)
is_move_locked: bool         # default false (game: freeze, stun)
```

## Movement Constants

Extracted from player.gd as-is. Live as consts in movement.gd:

```
MAX_SPEED, STOP_SPEED, ACCELERATE, AIR_ACCELERATE, AIR_SPEED_CAP,
FRICTION, GRAVITY, JUMP_SPEED, LADDER_SPEED, LADDER_JUMP,
MAX_VELOCITY, WATER_SPEED, WATER_FRICTION, STEP_HEIGHT,
STAND_HEIGHT, CROUCH_HEIGHT, STAND_EYE, CROUCH_EYE,
DUCK_MULT, WALK_MULT, DUCK_TIME, SCALE
```

## Movement API

All static functions on Movement:

### Pure math (no body needed)

- `apply_friction(state, delta)` — Quake PM_Friction
- `ground_accelerate(state, wish_dir, wish_speed, delta)` — PM_Accelerate
- `air_accelerate(state, wish_dir, wish_speed, delta)` — PM_AirAccelerate
- `apply_gravity_half(state, delta)` — half-step gravity
- `get_max_speed(state, cmd) -> float` — with crouch/walk/speed_scale
- `clamp_velocity(state)` — sv_maxvelocity cap
- `calc_wish(cmd, state) -> {wish_dir, wish_speed}` — resolve input + yaw into world-space wish vector

### Body-coupled (minimal Godot dependency)

- `simulate_tick(body, state, cmd)` — full tick:
  1. If is_move_locked: zero velocity, return
  2. Update crouch (changes body collision shape)
  3. Mode select: noclip / ladder / water / normal
  4. Compute velocity changes (calls pure math functions)
  5. Apply to body: move_and_slide or walk_move
  6. Post-move half-gravity
  7. Read back position, velocity, on_floor from body into state
- `walk_move(body, state, cmd)` — PM_WalkMove stair stepping
- `update_crouch(body, state, cmd)` — collision shape resize + eye_y interpolation

## Network RPCs

### Client → Server (unreliable_ordered, every tick)

```gdscript
send_input_command(seq: int, move_x: float, move_y: float, yaw: float,
                   pitch: float, flags: int, delta: float)
```

### Server → Owning client (unreliable)

```gdscript
sync_server_state(seq: int, pos: Vector3, vel: Vector3,
                  crouched: bool, on_floor: bool)
```

### Server → All other clients (unreliable)

```gdscript
broadcast_player_state(peer_id: int, pos: Vector3, rot_y: float,
                       crouched: bool, pitch: float, jumping: bool)
```

Host's own player: runs movement locally (that IS authoritative), broadcasts via same path.

## Client Flow (per tick in player.gd _physics_process)

```
1. Sample Input.* → build InputCommand (seq from PredictionBuffer)
2. Set state modifiers (frost → friction_scale, etc.)
3. Detect ladder/water from Area3D overlaps → set state.on_ladder, state.in_water
4. Movement.simulate_tick(self, state, cmd)
5. prediction_buffer.record(cmd, state snapshot)
6. Send cmd to server via send_input_command RPC
7. Apply camera smoothing (step offset, eye_y) — visual only, not part of state
```

### On server state arrival (_on_server_state)

```
1. replay_cmds = prediction_buffer.reconcile(server_seq, server_pos, server_vel, ...)
2. If empty: prediction was correct, done
3. If non-empty:
   a. Snap body to server state (position, velocity)
   b. apply_floor_snap() if server says on_floor
   c. For each cmd in replay_cmds:
      Movement.simulate_tick(self, state, cmd)
   d. Updated state is new prediction baseline
```

## Server Flow (per tick in main.gd _physics_process, host only)

```
For each remote peer with a ServerMovement instance:
  1. Pop queued InputCommands (up to MAX_QUEUE=10)
  2. For each cmd in order:
     a. Set state modifiers from game systems (StatusSystem → friction_scale, etc.)
     b. Detect ladder/water from puppet's Area3D overlaps
     c. Movement.simulate_tick(puppet_body, state, cmd)
     d. Record last_processed_seq
  3. sync_server_state.rpc_id(peer_id, last_seq, state.pos, state.vel, ...)
  4. broadcast_player_state.rpc(peer_id, state.pos, ...) to all other clients
```

## Reconciliation Details

- **Tolerance**: 0.01 units (~0.4 GoldSrc units)
- **Buffer size**: 128 entries (~2.1s at 60Hz)
- **Edge cases that reset the buffer:**
  - Death: clear buffer, stop sending commands
  - Respawn: clear buffer, snap to spawn position, resume
  - Teleport: server sends flag with sync_server_state indicating hard snap
  - Knockback: server applies to ServerMovement.state.velocity, client predicts locally

## Test Plan

### Unit tests — test_movement.gd

1. test_apply_friction_reduces_speed
2. test_apply_friction_stops_below_threshold
3. test_apply_friction_respects_friction_scale
4. test_ground_accelerate_toward_wish
5. test_ground_accelerate_capped_at_max
6. test_ground_accelerate_respects_accel_scale
7. test_air_accelerate_speed_cap
8. test_air_accelerate_preserves_existing_speed
9. test_gravity_half
10. test_gravity_respects_gravity_scale
11. test_get_max_speed_crouch
12. test_get_max_speed_walk
13. test_get_max_speed_speed_scale
14. test_get_max_speed_stacks
15. test_clamp_velocity
16. test_is_move_locked_zeroes_velocity
17. test_calc_wish_forward
18. test_calc_wish_strafe
19. test_calc_wish_no_input

### Unit tests — test_input_command.gd

20. test_pack_unpack_roundtrip
21. test_flags_bitmask_all_combinations
22. test_default_values

### Unit tests — test_prediction_buffer.gd

23. test_record_increments_seq
24. test_reconcile_match_no_replay
25. test_reconcile_mismatch_returns_commands
26. test_reconcile_within_tolerance
27. test_reconcile_beyond_tolerance
28. test_buffer_overflow_prunes_old
29. test_reconcile_stale_seq
30. test_reconcile_clears_old_entries

### Unit tests — test_server_movement.gd

31. test_enqueue_and_process
32. test_queue_ordering
33. test_queue_overflow_drops_oldest
34. test_duplicate_seq_ignored

### Integration tests — test_integration.gd

35. test_simulate_tick_moves_forward
36. test_simulate_tick_jump
37. test_simulate_tick_gravity
38. test_simulate_tick_friction_stops
39. test_walk_move_steps_up
40. test_crouch_changes_shape
41. test_determinism
42. test_prediction_reconciliation_e2e

## Migration Phases

### Phase 0: Test framework setup

- Install Gut into addons/gut/
- Enable plugin in project.godot
- Add .gutconfig.json pointing at netmove/tests/
- Create a trivial test to verify the runner works
- Verify headless CLI: godot --headless -s addons/gut/gut_cmdln.gd

### Phase 1: Extract movement into netmove/

- Create netmove/movement.gd with MovementState and all static movement functions
- Create netmove/input_command.gd
- Refactor player.gd._physics_process to build InputCommand, call Movement.simulate_tick
- All movement constants move to movement.gd
- Camera smoothing, weapon cooldowns, attack logic stay in player.gd
- Write tests 1–22, 35–42
- Verify: offline play feels identical

### Phase 2: Prediction buffer

- Create netmove/prediction_buffer.gd
- In player.gd, record predictions each tick after simulate_tick
- Still sends old sync_player_state RPC — no server changes yet
- Write tests 23–30
- Verify: game plays identically, buffer fills silently

### Phase 3: Server-side simulation

- Create netmove/server_movement.gd
- Add send_input_command RPC to network_manager.gd
- On host: create ServerMovement per remote peer, attached to puppet
- main.gd host loop: process input queues, call Movement.simulate_tick on puppet bodies
- Add sync_server_state RPC (server → owning client, received but ignored for now)
- Host broadcasts authoritative positions to other clients
- Write tests 31–34
- Verify: other clients see server-simulated movement

### Phase 4: Reconciliation

- Wire up PredictionBuffer.reconcile() in player.gd on sync_server_state receipt
- Implement replay loop: snap to server state, replay unacked commands
- Client stops sending old sync_player_state
- Verify: client movement responsive, corrections rare on LAN

### Phase 5: Cleanup & edge cases

- Remove old sync_player_state client→server RPC
- Death: clear prediction buffer, stop sending commands
- Respawn: clear buffer, snap to spawn, resume
- Teleport: server flags hard-snap, client resets buffer
- Knockback: server applies to ServerMovement.state.velocity
- Remove dead code
- Final pass on all tests
