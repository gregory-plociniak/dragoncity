# Plan: Prevent Building Placement on Roads

## Objective
Ensure that buildings can only be placed on empty ground tiles, preventing them from being placed on top of existing roads.

## Current Behavior
In `mygame/app/building_placer.rb`, the `handle_click` method checks if there is a building to delete, and if not, it checks if there is a road nearby (`road_nearby?`). However, it does not check if the current tile already contains a road, which allows buildings to overwrite or be placed on top of roads.

## Proposed Changes
Modify `mygame/app/building_placer.rb`. Update the `handle_click` method to also check that the target tile is not currently occupied by a road before allowing placement.

Update the condition from:
```ruby
    elsif road_nearby?(args.state.roads, col, row)
```
To:
```ruby
    elsif !args.state.roads[key] && road_nearby?(args.state.roads, col, row)
```

## Validation Steps
1. Start the game.
2. Place a road on an empty tile.
3. Switch to building placement mode.
4. Attempt to place a building directly on the previously placed road. It should not be placed (it should flash as invalid).
5. Ensure buildings can still be placed on empty ground tiles adjacent to roads.
6. Verify that existing buildings can still be deleted by clicking on them.
