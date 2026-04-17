# A* Car Pathfinding Runtime Fixes

## Context

The A* road-pathfinding work introduced two issues that showed up in DragonRuby at runtime even though the code was valid in standard Ruby.

## Fix 1: `RoadGraph` module methods

### Symptom

Runtime error:

```text
The method named :building_access_tiles ... doesn't exist on [Module, RoadGraph]
```

### Root cause

`RoadGraph` was initially written with `module_function`. In plain Ruby that exposes module-level calls like `RoadGraph.building_access_tiles(...)`, but DragonRuby did not surface the method that way in this case.

### Fix

Replace the helper definitions with explicit singleton methods:

```ruby
def self.building_access_tiles(...)
def self.road_neighbors(...)
def self.road_tile?(...)
```

### Reasoning

This makes the call site unambiguous for the runtime. `CarManager` and `RoadPathfinder` both depend on `RoadGraph` as a module namespace, so explicit `self.` methods are the safest form.

## Fix 2: Array-based ordering and comparison

### Symptom

Runtime error:

```text
The method named :< with args [[8, 1, 3, 0]] doesn't exist on [Array, ...]
```

### Root cause

The first A* implementation used array ordering in three places:

- `min_by { [f_score, g_score, row, col] }`
- `sort_by { [row, col] }`
- comparing path sort keys with `candidate_key < current_key`

That style works in standard Ruby because arrays are lexicographically comparable. DragonRuby did not support those array comparisons here.

### Fix

Replace array-based ordering with scalar/manual comparisons:

- For tile ordering, use a scalar key such as `row * GRID_SIZE + col`
- For best-open-node selection, compare `f`, then `g`, then tile order explicitly
- For best-path tie breaking, compare path length first, then compare tile order element-by-element

### Reasoning

The algorithm still needs deterministic tie breaking, but it cannot rely on array comparison operators in this runtime. Manual comparisons preserve the intended behavior while staying compatible with DragonRuby.

## Result

The pathfinding behavior stayed the same:

- roads are traversed only when both tiles support the shared edge
- A* still chooses the shortest orthogonal route
- tie breaking remains stable and deterministic

The implementation just avoids Ruby features that DragonRuby handles differently.
