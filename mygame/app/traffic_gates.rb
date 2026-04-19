GateVerdict = Struct.new(:midpoint_denied, :stop_denied, :step_denied)

class TrafficGates
  CROSSOVER_THRESHOLD = 0.5
  DEFAULT_SPEED = 0.02

  def build_slot_occupancy(cars)
    occupancy = {}
    cars.each do |car|
      slot = CarGeometry.current_slot(car)
      occupancy[slot] = car if slot
    end
    occupancy
  end

  def resolve(cars, occupancy)
    midpoint_denied = resolve_midpoint_crossings(cars, occupancy)
    step_denied = resolve_step_crossings(cars, occupancy)

    verdicts = {}
    cars.each do |car|
      verdicts[car] = GateVerdict.new(
        midpoint_denied.include?(car),
        false,
        step_denied.include?(car)
      )
    end
    verdicts
  end

  def rank_by_right_hand_yield(group)
    group.sort_by do |intent|
      yielders = group.count do |other|
        !other.equal?(intent) && approaching_from_right?(intent, other)
      end
      from_col, from_row = yield_origin_tile(intent)
      [yielders, GridCoordinates.tile_order(from_col, from_row)]
    end
  end

  private

  def resolve_midpoint_crossings(cars, occupancy)
    intents = cars.filter_map { |car| midpoint_intent(car) }
    resolve_gate_crossings(intents, occupancy)
  end

  def resolve_step_crossings(cars, occupancy)
    intents = cars.filter_map { |car| step_intent(car) }
    resolve_gate_crossings(intents, occupancy)
  end

  def resolve_gate_crossings(intents, occupancy)
    denied = []

    intents.group_by { |intent| intent[:target_slot] }.each do |target_slot, group|
      if target_slot_occupied_by_other?(target_slot, occupancy, group)
        group.each { |intent| denied << intent[:car] }
        next
      end

      next if group.size <= 1

      losers = rank_by_right_hand_yield(group).drop(1)
      losers.each { |intent| denied << intent[:car] }
    end

    denied
  end

  def target_slot_occupied_by_other?(target_slot, occupancy, group)
    occupant = occupancy[target_slot]
    return false unless occupant

    group.none? { |intent| intent[:car].equal?(occupant) }
  end

  def midpoint_intent(car)
    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx]
    to = path[idx + 1]
    speed = movement_speed(car)
    return nil unless from && to
    return nil unless car[:progress] < CROSSOVER_THRESHOLD
    return nil unless car[:progress] + speed >= CROSSOVER_THRESHOLD

    {
      car: car,
      target_slot: [from[0], from[1], to[0], to[1], :second],
      from_tile: from,
      to_tile: to
    }
  end

  def step_intent(car)
    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx]
    to = path[idx + 1]
    next_to = path[idx + 2]
    speed = movement_speed(car)
    return nil unless from && to && next_to
    return nil unless car[:progress] >= CROSSOVER_THRESHOLD
    return nil unless car[:progress] + speed >= 1.0

    {
      car: car,
      target_slot: [to[0], to[1], next_to[0], next_to[1], :first],
      from_tile: to,
      to_tile: next_to,
      approach_from: from
    }
  end

  def approaching_from_right?(intent, other)
    my_dx, my_dy = intent_step_vector(intent)
    other_dx, other_dy = intent_step_vector(other)
    # Screen-space cross product: negative means `other` is 90° clockwise
    # (to the right) of `intent`, matching the same right-perpendicular
    # convention used by right_hand_lane_offset.
    (my_dx * other_dy) - (my_dy * other_dx) < 0
  end

  def intent_step_vector(intent)
    from_tile = intent[:approach_from] || intent[:from_tile]
    to_tile = intent[:approach_from] ? intent[:from_tile] : intent[:to_tile]

    CarGeometry.projected_step_vector(
      to_tile[0] - from_tile[0],
      to_tile[1] - from_tile[1]
    )
  end

  def yield_origin_tile(intent)
    intent[:approach_from] || intent[:from_tile]
  end

  def movement_speed(car)
    car[:current_speed] || car[:speed] || DEFAULT_SPEED
  end
end
