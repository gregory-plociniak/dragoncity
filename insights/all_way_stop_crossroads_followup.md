# All-Way Stop Crossroads Follow-Up

## Context

After the initial all-way-stop crossroad implementation, three gameplay issues still showed up in `mygame/app/car_manager.rb`:

- the next car could start moving before the previous car had fully cleared the intersection
- cars were stopping too close to, or visually on top of, the crossroad tile
- a follower could still drive into a car that was already stopped before the crossroad

This follow-up tightened crossroad ownership lifetime and added more spacing on stop-controlled approaches.

## What changed

### Crossroad ownership now lasts until the car is actually clearing the exit

The original stop token was being cleared too early, on the step into the `:cross` tile.

The release point was moved so ownership survives while the car is leaving the crossroad and only clears once the car reaches the midpoint of the outgoing segment. Two helpers were added to support that:

- `active_stop_controlled_crossroad_for`
- `exiting_owned_crossroad?`

This keeps the crossroad reserved for the active car until it is visibly out of the intersection, so the next car cannot enter too soon.

### Stop line moved farther back from the intersection

The stop line constant was retuned:

- `ALL_WAY_STOP_LINE_PROGRESS` changed from `0.8` to `0.65`

That makes cars stop earlier on the incoming segment so the sprite reads as waiting before the crossroad tile instead of sitting on top of the intersection art.

### Queue spacing added behind a stopped stop-line car

Stopping earlier exposed a queue-spacing problem: the follower could still creep too close to the lead car on the same approach segment.

To address that, a separate queue hold point was added:

- `ALL_WAY_STOP_QUEUE_PROGRESS = 0.3`

And the approach logic gained:

- `stop_queue_denied?`
- `clamp_below_stop_queue`

This creates a second visual wait point behind the actual stop line, so the next car pauses farther back instead of running up to the midpoint behind the leader.

### Followers are now blocked before entering an occupied stop approach

There was still one more collision case: a follower could step onto the segment leading into the stop-controlled crossroad even when the lead car was already occupying that segment's front half.

To prevent that, the movement phase now checks the next stop-approach segment before allowing the step:

- `stop_approach_entry_denied?`
- `upcoming_stop_approach_slot`

If the approach segment into the crossroad already has a car in its `:second` half, the follower is clamped one segment earlier and waits there.

## Resulting behavior

The intended behavior after these follow-up fixes is:

- one car owns the crossroad until it is actually clearing the intersection
- stop-sign cars wait before the crossroad tile, not on it
- queued followers leave visible space instead of touching the stopped car
- a follower cannot step onto an already-occupied stop-approach segment

## Verification

Ran:

```text
ruby -c mygame/app/car_manager.rb
```

Result: `Syntax OK`

## Remaining caveat

This follow-up still only verified syntax. The next in-game check should confirm:

- the owner is not released until it is visibly past the intersection
- the stop line at `0.65` looks right with the current sprite art
- queued cars leave enough space on all four approach directions
- no new deadlocks were introduced by the earlier stop-approach gate
