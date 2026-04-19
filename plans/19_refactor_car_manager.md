# Plan: Refactor `CarManager` into Focused Collaborators

## Goal

Break [`mygame/app/car_manager.rb`](/Users/gregory/dragoncity/mygame/app/car_manager.rb) (currently ~817 lines — by far the largest file in the app, 6× the next-largest `grid_renderer.rb`) into smaller, single-responsibility pieces. Each concern (fleet composition, leg planning, per-tick motion, traffic-gate arbitration, all-way-stop control, sprite rendering) should live with code that only cares about that concern.

The refactor must be **behavior-preserving**: no gameplay changes, no tuning changes, no new features. Only structure changes. The same constants with the same values, the same call order per tick, the same hash shape for `car`.

Follow the same split-and-inject pattern already used in plan `09_refactor_input_handler.md`.

---

## Current situation

`CarManager` mixes six concerns in one file:

1. **Rendering** (lines 2–7, 23–38, 92–130, 755–816)
   - Sprite dimensions, lane/art offset constants, screen projection, lane math, sprite picking, `enqueue_world`.
2. **Fleet composition** (lines 44–70, 481–517, 560–562)
   - `recompute`: discovers every building-pair, reuses or spawns a car per pair, drops cars with no viable path.
   - Pair key/identity helpers, `spawn_new_car`, `pair_far_enough?`.
3. **Leg planning** (lines 399–479, 518–562)
   - `plan_next_leg`, `update_existing_car`, `current_leg_valid?`, `recover_broken_leg`, `try_mid_leg_repath`, `best_road_path`, `better_path?`, `compare_paths`, `endpoints_for_direction`.
4. **Per-tick motion** (lines 72–90, 134–236, 564–596, 697–712)
   - `tick` loop, `advance_car`, the four `clamp_below_*` helpers, stall tracking, `prepare_car_for_tick`, `accelerate_toward_cruise`, `movement_speed`.
5. **Traffic-gate arbitration** (lines 238–397)
   - `build_slot_occupancy`, `current_slot`, midpoint/step crossings, `resolve_gate_crossings`, intent builders, right-hand yield, approach-from-right geometry.
6. **All-way-stop control** (lines 269–296, 598–753)
   - `resolve_all_way_stops`, owner selection, stop-line/queue/approach denials, `stop_controlled_crossroad_for`, stop-token lifecycle, `road_kind_at`.

Cross-concern smells:

- `tile_order(col, row) = row * GRID_SIZE + col` is redefined here even though `GridCoordinates` already exists as the home for pure grid helpers (see plan `09`). `GridRenderer` and `RoadPathfinder` likely re-derive the same thing.
- `road_kind_at` is a one-liner over `roads[GridCoordinates.tile_key(col, row)]` — identical to `RoadGraph.road_tile?` callers. It belongs in `RoadGraph` rather than living privately in `CarManager`.
- `projected_step_vector`, `tile_order`, `road_kind_at` are called by multiple concerns inside the file and would become duplicated between new files unless lifted into a shared module.
- The single `advance_car` method takes four boolean gate flags (`midpoint_denied`, `stop_denied`, `step_denied`, plus implicit stop-approach/queue checks inside) — a sign that traffic arbitration is leaking into motion. A dedicated gate object makes the flags self-describing.
- Car state keys (`:stop_crossroad`, `:stop_go_token`, `:stop_arrival_frame`) are touched from at least three concerns. Centralising their lifecycle in one collaborator removes the scatter.

---

## Proposed structure

```
mygame/app/
  car_manager.rb         # SHRUNK — orchestration only (recompute/tick/enqueue_world)
  car_renderer.rb        # NEW   — sprite + lane/art offset math, enqueue to render queue
  car_fleet.rb           # NEW   — building-pair discovery, spawn, pair-key, orphan drop
  car_path_planner.rb    # NEW   — best-path search, leg planning, repath/recovery
  car_motion.rb          # NEW   — per-tick speed control, clamps, stall, step advance
  traffic_gates.rb       # NEW   — slot occupancy + midpoint/step arbitration + yield
  all_way_stop.rb        # NEW   — stop-line state machine, owner selection, denials
  car_geometry.rb        # NEW   — shared pure helpers (projected_step_vector, slot keys)
```

Each new file is small: `car_renderer.rb` ~80 lines, `car_fleet.rb` ~60, `car_path_planner.rb` ~80, `car_motion.rb` ~90, `traffic_gates.rb` ~80, `all_way_stop.rb` ~120, `car_geometry.rb` ~30. `car_manager.rb` shrinks to ~60 lines.

No new third-party dependencies.

---

## New class responsibilities

### `CarGeometry` (module)

Pure functions, no state, no `args`. Home for helpers that would otherwise duplicate between the motion, gate, and stop collaborators.

- `projected_step_vector(delta_col, delta_row)` → `[screen_dx, screen_dy]` (the two-line formula at lines 799–804).
- `current_slot(car)` → `[from_col, from_row, to_col, to_row, :first|:second]` — the canonical identifier for a half-segment occupancy cell (lines 247–262).
- `second_half_slot(car)` → the always-`:second` variant used by stop-queue denial (lines 672–680).

**Why a module:** all three collaborators call these, and they have no state. Matches the `GridCoordinates` precedent from plan `09`.

**Do not** move `tile_order` here — lift it into `GridCoordinates` in the same refactor (see "Shared cleanups" below).

### `CarRenderer`

Owns everything that was in lines 2–7, 23–38, 92–130, 755–816.

- `enqueue_world(cars, camera, queue)` — mirrors the current method; pushes sprites to the render queue with the existing `depth`/`layer`/`order` keys so `RenderQueue` output is bit-identical.
- Private helpers: `interpolated_screen_position`, `lane_offset_for`, `right_hand_lane_offset`, `total_direction_offset`, `art_bias_for`, `sprite_for_delta`.
- Constants moved in from `CarManager`:
  - `AMBULANCE_SPRITE_DIMENSIONS`
  - `LANE_OFFSET_PIXELS`
  - `GLOBAL_CAR_Y_BIAS`
  - `DIRECTIONAL_ART_BIAS`
- Uses `CarGeometry.projected_step_vector` instead of a private copy.

### `CarFleet`

Owns composition of the active car list each time roads/buildings change.

- `recompute(state)` — current `CarManager#recompute` body.
- `spawn_new_car(roads, endpoints, key, slot_occupancy)` — unchanged.
- Private: `pair_far_enough?`, `pair_key_for`, `parse_key`.
- Uses `CarPathPlanner` for `best_road_path` + `update_existing_car` (delegated; see below).
- Keeps `MIN_PAIR_DISTANCE` and `DEFAULT_SPEED` constants local (DEFAULT_SPEED could arguably live with motion, but the only current reader besides `spawn_new_car` is `movement_speed` which falls back to a per-car `:speed` field — set once here).

Entry point: `CarManager#recompute` becomes `@fleet.recompute(state)`.

### `CarPathPlanner`

Owns every path/leg decision.

- `best_road_path(roads, start_building, goal_building)` — unchanged.
- `plan_next_leg(roads, car)` — unchanged.
- `update_existing_car(roads, car, endpoints)` — unchanged.
- `try_mid_leg_repath(state, car)` — unchanged.
- Private: `current_leg_valid?`, `recover_broken_leg`, `better_path?`, `compare_paths`, `endpoints_for_direction`.
- Takes the shared `RoadPathfinder` via its constructor (`CarManager` currently holds `@pathfinder`; pass it through to `CarFleet` which passes to `CarPathPlanner`, or inject directly).

Callers: `CarFleet` (for spawn + update) and `CarMotion` (for `plan_next_leg` when a leg ends, and `try_mid_leg_repath` when a stall threshold trips).

### `CarMotion`

Owns per-tick speed control and advancing one car by one tick.

- `prepare(state, car)` — current `prepare_car_for_tick`.
- `advance(state, car, gate_verdict)` — current `advance_car`, but takes a single `GateVerdict` struct instead of three booleans.
- Private: four `clamp_below_*` helpers, `reset_stall`, `record_stall`, `accelerate_toward_cruise`, `movement_speed`.
- Constants moved here: `CROSSOVER_THRESHOLD`, `CROSSOVER_EPSILON`, `STOP_BRAKE_PER_TICK`, `STOP_ACCEL_PER_TICK`, `STALL_TICKS_BEFORE_REPATH`.
- Depends on `CarPathPlanner` for `plan_next_leg` (leg exhaustion) and `try_mid_leg_repath` (stall threshold).
- Depends on `AllWayStopController` for the stop-crossroad lookups and `clear_stop_control_state` — inject it so `CarMotion` asks, rather than re-deriving.

`GateVerdict` is a tiny Struct: `Struct.new(:midpoint_denied, :stop_denied, :step_denied)`. Living in `traffic_gates.rb`.

### `TrafficGates`

Owns half-segment arbitration for normal travel (not stop-sign lifecycle — that is next).

- `build_slot_occupancy(cars)` — unchanged.
- `resolve(cars, occupancy)` → returns a hash `{ car => GateVerdict }` combining midpoint and step decisions in one pass.
- Private: `resolve_midpoint_crossings`, `resolve_step_crossings`, `resolve_gate_crossings`, `target_slot_occupied_by_other?`, `midpoint_intent`, `step_intent`, `rank_by_right_hand_yield`, `approaching_from_right?`, `intent_step_vector`, `yield_origin_tile`.
- Uses `CarGeometry.projected_step_vector` and `CarGeometry.current_slot` rather than private copies.

### `AllWayStopController`

Owns everything stop-sign-related, including the car-state fields `:stop_crossroad`, `:stop_go_token`, `:stop_arrival_frame`.

- `resolve(state, cars)` — current `resolve_all_way_stops`, returns the set of denied cars.
- `approach_entry_denied?(roads, occupancy, car)` — current `stop_approach_entry_denied?`.
- `queue_denied?(occupancy, car, stop_crossroad)` — current `stop_queue_denied?`.
- `stop_crossroad_for(roads, car)` — current `stop_controlled_crossroad_for`.
- `active_stop_crossroad_for(roads, car)` — current `active_stop_controlled_crossroad_for`.
- `exiting_owned_crossroad?(car)` — unchanged.
- `waits_at_stop_line_without_go_token?(car, stop_crossroad)` — unchanged.
- `at_or_past_stop_line?(car)` — unchanged.
- `should_brake_for_stop_line?(car)` — unchanged (used only by `CarMotion#prepare`, but lives with the stop logic so the constants stay co-located).
- `clear_state(car)` — current `clear_stop_control_state`.
- Private: `select_all_way_stop_owner`, `all_way_stop_intent`, `fully_stopped_at_crossroad?`, `upcoming_stop_approach_slot`.
- Uses `CarGeometry.second_half_slot` instead of a private copy.
- Uses `RoadGraph.road_tile?` / a new `RoadGraph.crossroad?` if introduced, or the existing `road_kind_at` helper — see "Shared cleanups."
- Constants moved here: `ALL_WAY_STOP_LINE_PROGRESS`, `ALL_WAY_STOP_QUEUE_PROGRESS`.

### `CarManager` (shrunk)

After the split, `CarManager` owns only wiring and the three public entry points:

```ruby
class CarManager
  def initialize(pathfinder = RoadPathfinder.new)
    @path_planner = CarPathPlanner.new(pathfinder)
    @fleet        = CarFleet.new(@path_planner)
    @stops        = AllWayStopController.new
    @gates        = TrafficGates.new
    @motion       = CarMotion.new(@path_planner, @stops)
    @renderer     = CarRenderer.new
  end

  def recompute(state)
    @fleet.recompute(state)
  end

  def tick(state)
    state.cars.each { |car| @motion.prepare(state, car) }
    state.car_slot_occupancy = @gates.build_slot_occupancy(state.cars)

    verdicts = @gates.resolve(state.cars, state.car_slot_occupancy)
    stop_denied = @stops.resolve(state, state.cars)

    survivors = []
    state.cars.each do |car|
      verdict = verdicts[car]
      verdict = verdict.dup
      verdict.stop_denied = stop_denied.include?(car)
      survivors << car if @motion.advance(state, car, verdict)
    end
    state.cars = survivors
  end

  def enqueue_world(args, camera, queue)
    @renderer.enqueue_world(args.state.cars, camera, queue)
  end
end
```

Target size: ≤ 60 lines. The `state.car_slot_occupancy` assignment stays so `stop_approach_entry_denied?` / `stop_queue_denied?` continue to read the same canonical snapshot during `advance`.

---

## Shared cleanups (small, bundled in the same PR)

These are minor and don't need their own plan, but they remove duplication exposed by the split.

1. **Move `tile_order` to `GridCoordinates`.**
   - Add `GridCoordinates.tile_order(col, row) = row * GRID_SIZE + col`.
   - Replace call sites in `CarManager` (lines 118, 120, 372, 550–551, 560–562) with `GridCoordinates.tile_order(...)`.
   - `grep` `GridRenderer` and `RoadPathfinder` for the same formula and switch those too if present.
2. **Move `road_kind_at` to `RoadGraph`.**
   - Add `RoadGraph.road_kind_at(roads, col, row)` returning the kind symbol or `nil`.
   - Replace the three private uses in `CarManager` with `RoadGraph.road_kind_at(...)`.
   - Leaves a single place to add `:cross`/`:straight` predicates later.

Both cleanups are low-risk textual substitutions; they go in step 1 of the migration.

---

## What does NOT need a new class

- **`GateVerdict`** is a three-field `Struct`. Don't wrap it in a class — it's a dumb value object.
- **Car hash itself.** Tempting to make it a `Struct` or `Data`, but it's accessed in many places by symbol key and DragonRuby is sensitive to allocation churn. Leave as a Hash.
- **Mode-specific "controller" classes beyond all-way stop** (e.g. a YieldController or MergeController). Plain traffic-gate logic is small enough to share one class.

---

## Migration order

Each step is independently runnable; commit between steps. Each step moves code, nothing changes logic.

1. **Shared cleanups.** Add `GridCoordinates.tile_order` and `RoadGraph.road_kind_at`, swap call sites, confirm visuals unchanged. No new files yet.
2. **Extract `CarGeometry`.** Move `projected_step_vector` + the slot helpers into a module. `CarManager` calls through `CarGeometry.foo`. Still one class, otherwise.
3. **Extract `CarRenderer`.** Move sprite constants, `enqueue_world` body, and the lane/projection helpers. `CarManager#enqueue_world` becomes a one-line delegator.
4. **Extract `CarPathPlanner`.** Move leg/path methods. Inject into `CarManager`. `recompute` still lives in `CarManager` but calls `@path_planner` for `best_road_path`/`update_existing_car`.
5. **Extract `CarFleet`.** Move `recompute` body + spawn/pair helpers. `CarManager#recompute` becomes a delegator.
6. **Extract `TrafficGates`.** Move slot occupancy, midpoint/step intents, yield logic. Introduce `GateVerdict`. `tick` in `CarManager` starts calling `@gates.resolve` and threading verdicts into `advance`.
7. **Extract `AllWayStopController`.** Move stop-line methods, owner selection, denials, and the `stop_*` car-hash fields' lifecycle. Inject into `CarMotion`.
8. **Extract `CarMotion`.** Move `prepare_car_for_tick`, `advance_car`, clamps, stall tracking, speed control. `CarManager#tick` shrinks to the orchestration shown above.
9. **Final pass on `CarManager`.** File should be ≤ ~60 lines; only constructor + the three public methods.

After step 9, run the validation checklist end-to-end.

---

## Edge cases to preserve

1. **Tick ordering is load-bearing.** `prepare_car_for_tick` must run for every car **before** `build_slot_occupancy`, because `prepare` may clamp `:progress` back to the stop line (line 585) and that clamp must be visible to slot-occupancy math in the same tick. Keep this order in the new orchestrator.
2. **Single canonical slot snapshot per tick.** `state.car_slot_occupancy` is read by `stop_approach_entry_denied?` and `stop_queue_denied?` during `advance`. The new `CarMotion` must read the snapshot `CarManager#tick` stored on state, not rebuild it.
3. **Stop-token lifecycle across owners.** `clear_stop_control_state` runs both when a car leaves the stop-controlled window (`prepare`) and when a car is mid-leg-repathed (`try_mid_leg_repath`) and when a broken leg is recovered (`recover_broken_leg`). All three call sites must still hit it — that means `CarPathPlanner` and `CarFleet` need access to `AllWayStopController#clear_state`, or they inject it, or they expose a hook method.
4. **`stop_denied` is stitched into the `GateVerdict` after gate resolution.** `TrafficGates#resolve` only produces midpoint+step verdicts; all-way-stop denials come from a separate pass (they depend on frame-indexed arrival order and right-hand yield over stop intents, not gate intents). The orchestrator merges them.
5. **`endpoints_for_direction` direction flip.** `plan_next_leg` flips `0↔1` when a car finishes a leg. This must keep running through `CarPathPlanner` — don't accidentally drop the flip when moving the method.
6. **`:pending_repath` flag.** Currently set on `update_existing_car` (line 436) and cleared on the first successful leg transition (line 202) or a broken-leg recovery (line 475). The split between `CarFleet` (sets) and `CarMotion`/`CarPathPlanner` (clears) must keep both sides behaving.
7. **Spawn-slot contention.** `spawn_new_car` reads the projected slot occupancy built from currently-alive cars; this deduplicates spawns that would collide on frame 0 of their existence (line 487). Keep this check inside `CarFleet` and feed it the same `projected_slot_occupancy` hash.
8. **Sprite front-lane bias.** `lane_front_bias = (delta_col - delta_row) <=> 0` at line 116 is not obvious; copy it verbatim. Same for the `[from_depth, to_depth].max + 0.5 + lane_front_bias * 0.1` depth expression on line 118.

---

## Acceptance criteria

1. `mygame/app/car_manager.rb` is ≤ 60 lines and only handles orchestration.
2. New files `car_renderer.rb`, `car_fleet.rb`, `car_path_planner.rb`, `car_motion.rb`, `traffic_gates.rb`, `all_way_stop.rb`, `car_geometry.rb` exist and are required from `main.rb`.
3. No file in `mygame/app/` exceeds ~150 lines after the split (excluding `repl.rb`).
4. `tile_order` is defined only in `GridCoordinates`; `grep -rn 'row \* GRID_SIZE + col' mygame/app/` returns a single hit.
5. `road_kind_at` is defined only in `RoadGraph`; no private duplicate in `CarManager` / derivatives.
6. All constants keep their original numeric values at their new homes.
7. All existing gameplay works identically: cars spawn between distant buildings, obey right-hand lane offsets, queue at half-segments, obey all-way stops with right-hand tiebreaking, re-path on stall, vanish cleanly when a path is broken, and draw with the existing z-sort behaviour.
8. Frame rate is unchanged within noise with a full road grid and active cars (the extra indirection should not allocate per tick — collaborators are instantiated once in `CarManager#initialize`).

---

## Verification checklist

1. Launch the game. Place two buildings far apart and connect them with a straight road. One ambulance spawns and loops.
2. Add a second pair; both ambulances run concurrently without colliding and yield correctly at half-segment crossings.
3. Build a crossroad with four approach arms and four buildings. Confirm:
   - cars stop at the stop line, not overlapping the intersection art,
   - the earliest-arrival car gets the go token,
   - simultaneous arrivals are broken by right-hand yield,
   - a car mid-intersection keeps its token until it exits, and the next car doesn't enter prematurely.
4. Break a road mid-leg (delete a tile a car is about to enter). Within ~3 seconds the car re-paths or vanishes; no ghost cars persist.
5. Delete a building that owns an active pair. That car disappears on the next `recompute`; others are unaffected.
6. Place a road preview over a tile a car is passing through. Z-order remains correct (no flicker, no car-under-preview artifact).
7. `wc -l mygame/app/car_manager.rb` is ≤ 60.
8. `grep -rn 'row \* GRID_SIZE + col' mygame/app/` — single hit in `grid_coordinates.rb`.
9. `grep -rn 'def road_kind_at' mygame/app/` — single hit in `road_graph.rb`.
10. Playtest stop-sign flow from plan `17`'s verification list — behaviour should match pre-refactor.

---

## Notes / Decisions

- **Why seven files and not three?** The concerns split cleanly along the six numbered groupings in "Current situation" plus a shared helper module. A coarser split (e.g. a single `CarTraffic` that merged gates + stops) would keep ~400 lines in one file and leave the stop-token lifecycle tangled with right-hand yield on straight road. The finer split mirrors the successful `InputHandler` breakup in plan `09`.
- **Why inject collaborators through `CarManager` instead of making them module singletons?** Keeps unit tests and the REPL able to swap `@pathfinder` or stub `@stops` without patching globals. Matches the existing `RoadPathfinder.new` parameter on `CarManager#initialize`.
- **Why a `GateVerdict` struct instead of keeping three booleans?** The current `advance_car` signature (`car, midpoint_denied, stop_denied, step_denied`) is already the max readable arity. Adding the approach/queue flags without a value object would push it to five. A struct lets `CarMotion#advance(car, verdict)` stay a two-argument method while remaining explicit at call sites.
- **Why leave `DEFAULT_SPEED` on `CarFleet` rather than `CarMotion`?** It's the spawn-time cruise speed; `CarMotion` reads it via `car[:speed]` which is set at spawn and never mutated. Keeping it with the spawner matches where it's actually authoritative.
- **Scope:** this plan intentionally does not touch path-finding internals (`RoadPathfinder`), road graph traversal, or the render queue. It only redistributes methods currently inside `CarManager`.
