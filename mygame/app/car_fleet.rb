class CarFleet
  MIN_PAIR_DISTANCE = 4
  DEFAULT_SPEED = 0.02

  def initialize(path_planner, gates)
    @path_planner = path_planner
    @gates = gates
  end

  def recompute(state)
    building_tiles = state.buildings.keys.map { |key| parse_key(key) }
    existing_by_key = state.cars.each_with_object({}) { |car, hash| hash[car[:pair_key]] = car }

    projected_slot_occupancy = @gates.build_slot_occupancy(state.cars)
    new_cars = []
    building_tiles.combination(2).each do |b1, b2|
      next unless pair_far_enough?(b1, b2)

      endpoints = [b1, b2].sort
      key = pair_key_for(endpoints)
      existing = existing_by_key[key]

      car = if existing
              @path_planner.update_existing_car(state.roads, existing, endpoints)
            else
              spawn_new_car(state.roads, endpoints, key, projected_slot_occupancy)
            end

      next unless car

      new_cars << car
      projected_slot_occupancy[CarGeometry.current_slot(car)] = car unless existing
    end

    state.cars = new_cars
  end

  private

  def spawn_new_car(roads, endpoints, key, slot_occupancy)
    path = @path_planner.best_road_path(roads, endpoints[0], endpoints[1])
    return nil unless path
    return nil if path.size < 2

    spawn_slot = [path[0][0], path[0][1], path[1][0], path[1][1], :first]
    return nil if slot_occupancy[spawn_slot]

    {
      pair_key: key,
      endpoints: endpoints,
      leg: { path: path, direction: 0 },
      step_index: 0,
      progress: 0.0,
      speed: DEFAULT_SPEED,
      current_speed: DEFAULT_SPEED,
      pending_repath: false,
      stall_ticks: 0,
      stop_crossroad: nil,
      stop_arrival_frame: nil,
      stop_go_token: nil
    }
  end

  def pair_far_enough?(b1, b2)
    [(b1[0] - b2[0]).abs, (b1[1] - b2[1]).abs].max >= MIN_PAIR_DISTANCE
  end

  def pair_key_for(endpoints)
    "#{endpoints[0][0]},#{endpoints[0][1]}|#{endpoints[1][0]},#{endpoints[1][1]}"
  end

  def parse_key(key)
    col, row = key.split(',')
    [col.to_i, row.to_i]
  end
end
