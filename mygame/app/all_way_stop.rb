class AllWayStopController
  # Hold earlier on the incoming segment so the sprite waits before the
  # crossroad tile instead of visually overlapping the intersection art.
  ALL_WAY_STOP_LINE_PROGRESS = 0.65
  # Keep the next car visibly behind a stopped leader on the same approach
  # segment instead of letting it clamp almost at the midpoint.
  ALL_WAY_STOP_QUEUE_PROGRESS = 0.3
  CROSSOVER_THRESHOLD = 0.5
  CROSSOVER_EPSILON = 0.001
  STOP_BRAKE_PER_TICK = 0.003
  DEFAULT_SPEED = 0.02

  def initialize(gates)
    @gates = gates
  end

  def resolve(state, cars)
    denied = []

    cars
      .group_by { |car| active_stop_crossroad_for(state.roads, car) }
      .each do |crossroad, group|
        next unless crossroad

        waiting_group = group.select do |car|
          at_or_past_stop_line?(car) || car[:stop_go_token] == crossroad
        end
        next if waiting_group.empty?

        owner = waiting_group.find { |car| car[:stop_go_token] == crossroad }
        owner ||= select_all_way_stop_owner(state.roads, crossroad, waiting_group)

        waiting_group.each do |car|
          if owner&.equal?(car)
            car[:stop_go_token] = crossroad
          else
            car[:stop_go_token] = nil if car[:stop_go_token] == crossroad
            denied << car if at_or_past_stop_line?(car)
          end
        end
      end

    denied
  end

  def approach_entry_denied?(roads, occupancy, car)
    target_slot = upcoming_stop_approach_slot(roads, car)
    return false unless target_slot
    return false unless car[:progress] + movement_speed(car) >= 1.0

    occupant = occupancy[[target_slot[0], target_slot[1], target_slot[2], target_slot[3], :second]]
    occupant && !occupant.equal?(car)
  end

  def queue_denied?(occupancy, car, stop_crossroad)
    return false unless stop_crossroad
    return false if car[:stop_go_token] == stop_crossroad
    return false if car[:progress] >= ALL_WAY_STOP_QUEUE_PROGRESS
    return false unless car[:progress] + movement_speed(car) >= ALL_WAY_STOP_QUEUE_PROGRESS

    occupant = occupancy[CarGeometry.second_half_slot(car)]
    occupant && !occupant.equal?(car)
  end

  def stop_crossroad_for(roads, car)
    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx]
    to = path[idx + 1]
    next_to = path[idx + 2]
    return nil unless from && to && next_to
    return nil unless RoadGraph.road_kind_at(roads, to[0], to[1]) == :cross

    to
  end

  def active_stop_crossroad_for(roads, car)
    stop_crossroad_for(roads, car) || exiting_owned_crossroad?(car)
  end

  def exiting_owned_crossroad?(car)
    owned_crossroad = car[:stop_go_token]
    return nil unless owned_crossroad

    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx]
    to = path[idx + 1]
    return nil unless from && to
    return nil unless from == owned_crossroad
    return nil unless car[:progress] < CROSSOVER_THRESHOLD

    owned_crossroad
  end

  def waits_at_stop_line_without_go_token?(car, stop_crossroad)
    stop_crossroad &&
      car[:stop_crossroad] == stop_crossroad &&
      car[:stop_go_token] != stop_crossroad &&
      at_or_past_stop_line?(car)
  end

  def at_or_past_stop_line?(car)
    car[:progress] >= ALL_WAY_STOP_LINE_PROGRESS - CROSSOVER_EPSILON
  end

  def should_brake_for_stop_line?(car)
    remaining_distance = ALL_WAY_STOP_LINE_PROGRESS - car[:progress]
    return false unless remaining_distance.positive?

    speed = movement_speed(car)
    return false unless speed.positive?

    stopping_distance = (speed * speed) / (2.0 * STOP_BRAKE_PER_TICK)
    remaining_distance <= stopping_distance + speed
  end

  def clear_state(car)
    car[:stop_crossroad] = nil
    car[:stop_arrival_frame] = nil
    car[:stop_go_token] = nil
  end

  private

  def select_all_way_stop_owner(roads, crossroad, waiting_group)
    stopped_cars = waiting_group.select { |car| fully_stopped_at_crossroad?(car, crossroad) }
    return nil if stopped_cars.empty?

    earliest_arrival = stopped_cars.map { |car| car[:stop_arrival_frame] }.min
    contenders = stopped_cars.select { |car| car[:stop_arrival_frame] == earliest_arrival }
    intents = contenders.map { |car| all_way_stop_intent(roads, car) }.compact
    return nil if intents.empty?

    @gates.rank_by_right_hand_yield(intents).first[:car]
  end

  def all_way_stop_intent(roads, car)
    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx]
    to = path[idx + 1]
    next_to = path[idx + 2]
    return nil unless from && to && next_to
    return nil unless RoadGraph.road_kind_at(roads, to[0], to[1]) == :cross

    {
      car: car,
      from_tile: to,
      to_tile: next_to,
      approach_from: from
    }
  end

  def fully_stopped_at_crossroad?(car, crossroad)
    car[:stop_crossroad] == crossroad &&
      car[:stop_arrival_frame] &&
      at_or_past_stop_line?(car) &&
      movement_speed(car).zero?
  end

  def upcoming_stop_approach_slot(roads, car)
    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx + 1]
    to = path[idx + 2]
    next_to = path[idx + 3]
    return nil unless from && to && next_to
    return nil unless RoadGraph.road_kind_at(roads, to[0], to[1]) == :cross

    [from[0], from[1], to[0], to[1], :first]
  end

  def movement_speed(car)
    car[:current_speed] || car[:speed] || DEFAULT_SPEED
  end
end
