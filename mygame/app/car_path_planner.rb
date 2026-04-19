class CarPathPlanner
  def initialize(pathfinder, stops)
    @pathfinder = pathfinder
    @stops = stops
  end

  def best_road_path(roads, start_building, goal_building)
    start_access_tiles = RoadGraph.building_access_tiles(roads, start_building[0], start_building[1])
    goal_access_tiles = RoadGraph.building_access_tiles(roads, goal_building[0], goal_building[1])
    return nil if start_access_tiles.empty? || goal_access_tiles.empty?

    best_path = nil

    start_access_tiles.each do |start_tile|
      goal_access_tiles.each do |goal_tile|
        candidate_path = @pathfinder.find_path(roads, start_tile, goal_tile)
        next unless candidate_path
        next unless better_path?(candidate_path, best_path)

        best_path = candidate_path
      end
    end

    best_path
  end

  def plan_next_leg(roads, car)
    new_direction = 1 - car[:leg][:direction]
    origin_building, destination_building = endpoints_for_direction(car[:endpoints], new_direction)

    path = best_road_path(roads, origin_building, destination_building)
    return nil unless path
    return nil if path.size < 2

    { path: path, direction: new_direction }
  end

  def update_existing_car(roads, car, endpoints)
    car[:endpoints] = endpoints

    if current_leg_valid?(roads, car)
      car[:pending_repath] = true
      return car
    end

    recover_broken_leg(roads, car) ? car : nil
  end

  def try_mid_leg_repath(state, car)
    path = car[:leg][:path]
    current = path[car[:step_index]]
    goal = path[-1]
    return false unless current && goal

    new_path = @pathfinder.find_path(state.roads, current, goal)
    return false unless new_path
    return false if new_path.size < 2
    return false if new_path == path[car[:step_index]..]

    car[:leg] = { path: new_path, direction: car[:leg][:direction] }
    car[:step_index] = 0
    car[:progress] = 0.0
    @stops.clear_state(car)
    true
  end

  private

  def current_leg_valid?(roads, car)
    path = car[:leg][:path]
    return false unless path
    idx = car[:step_index]
    return false if idx >= path.size - 1

    (idx...(path.size - 1)).each do |i|
      from_col, from_row = path[i]
      to_col, to_row = path[i + 1]
      return false unless RoadGraph.road_tile?(roads, from_col, from_row)
      return false unless RoadGraph.road_tile?(roads, to_col, to_row)
      return false unless RoadGraph.traversable_edge?(roads, from_col, from_row, to_col, to_row)
    end
    true
  end

  def recover_broken_leg(roads, car)
    path = car[:leg][:path]
    current_tile = path[car[:step_index]]
    goal_tile = path[-1]

    return false unless current_tile && goal_tile
    return false unless RoadGraph.road_tile?(roads, current_tile[0], current_tile[1])
    return false unless RoadGraph.road_tile?(roads, goal_tile[0], goal_tile[1])

    new_path = @pathfinder.find_path(roads, current_tile, goal_tile)
    return false unless new_path
    return false if new_path.size < 2

    car[:leg] = { path: new_path, direction: car[:leg][:direction] }
    car[:step_index] = 0
    car[:progress] = 0.0
    car[:pending_repath] = false
    car[:stall_ticks] = 0
    @stops.clear_state(car)
    true
  end

  def better_path?(candidate_path, current_best_path)
    return true unless current_best_path

    return true if candidate_path.length < current_best_path.length
    return false if candidate_path.length > current_best_path.length

    compare_paths(candidate_path, current_best_path) < 0
  end

  def compare_paths(left_path, right_path)
    left_path.each_with_index do |(left_col, left_row), index|
      right_col, right_row = right_path[index]
      left_order = GridCoordinates.tile_order(left_col, left_row)
      right_order = GridCoordinates.tile_order(right_col, right_row)
      next if left_order == right_order

      return left_order < right_order ? -1 : 1
    end

    0
  end

  def endpoints_for_direction(endpoints, direction)
    direction == 0 ? endpoints : endpoints.reverse
  end
end
