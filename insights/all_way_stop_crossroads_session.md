# All-Way Stop Crossroads Session

## Context

Implemented `plans/17_all_way_stop_crossroads.md` in `mygame/app/car_manager.rb`.

The goal was to replace the previous rolling right-hand-yield behavior at 4-way `:cross` tiles with a simple deterministic all-way-stop model:

- approaching cars visibly slow down
- cars stop before entering the crossroad
- one car owns the crossroad at a time
- priority is based on stop completion time, then the existing right-hand rule, then `tile_order`

## What changed

### Per-car stop-control state

Added transient stop-sign fields to cars:

- `current_speed`
- `stop_crossroad`
- `stop_arrival_frame`
- `stop_go_token`

This lets movement use an instantaneous speed and lets arbitration remember which car has already earned the right to enter a specific crossroad.

### Braking and stop-line clamping

Added stop-control tuning constants:

- `ALL_WAY_STOP_LINE_PROGRESS = 0.8`
- `STOP_BRAKE_PER_TICK = 0.003`
- `STOP_ACCEL_PER_TICK = 0.004`

Cars approaching a `:cross` tile now brake toward a stop line on the incoming segment, clamp at that line without entering the intersection, and only accelerate again once they own the crossroad.

### Crossroad ownership before normal step gating

Inserted a new `resolve_all_way_stops` phase in `CarManager#tick` between midpoint resolution and normal step resolution.

This resolver groups cars by destination crossroad tile and enforces:

1. existing owner keeps the token until it crosses
2. otherwise the next owner is the earliest fully stopped car
3. same-tick stop ties fall back to `rank_by_right_hand_yield`
4. final tie-break is still `tile_order`

This is intentionally per crossroad tile, not per outgoing slot, so only one car moves through a 4-way stop at a time.

### Stall handling changed for polite queues

Normal waiting at the stop line without a go token now resets `stall_ticks` instead of incrementing them.

That prevents the mid-leg repath logic from treating a correct stop-sign queue like a traffic jam. A car that already has the go token but is blocked by downstream slot occupancy still records a stall.

### State reset hooks

Stop-control state is cleared when:

- a car clears the crossroad
- a mid-leg repath succeeds
- a broken leg is recovered

Newly spawned cars now initialize the stop-control fields as well.

## Verification

Ran:

```text
ruby -c mygame/app/car_manager.rb
```

Result: `Syntax OK`

## Remaining caveat

This session only verified syntax, not live gameplay. The next check should be an in-game validation that cars:

- stop visibly before the center of a `:cross`
- release ownership correctly after entering
- do not deadlock when one owner is waiting on downstream slot occupancy
