module CarGeometry
  CROSSOVER_THRESHOLD = 0.5

  def self.projected_step_vector(delta_col, delta_row)
    [
      (delta_col - delta_row) * (TILE_W / 2.0),
      -(delta_col + delta_row) * (TILE_W / 4.0)
    ]
  end

  def self.current_slot(car)
    path = car[:leg][:path]
    idx = car[:step_index]
    return nil unless path && path[idx]

    from = path[idx]
    to = path[idx + 1]
    if from && to
      half = car[:progress] < CROSSOVER_THRESHOLD ? :first : :second
      return [from[0], from[1], to[0], to[1], half]
    end

    return [path[idx - 1][0], path[idx - 1][1], from[0], from[1], :second] if idx.positive? && path[idx - 1]

    [from[0], from[1], from[0], from[1], :second]
  end

  def self.second_half_slot(car)
    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx]
    to = path[idx + 1]
    return nil unless from && to

    [from[0], from[1], to[0], to[1], :second]
  end

  def self.crossroad_turn_context(roads, car)
    path = car.dig(:leg, :path)
    idx = car[:step_index]
    return nil unless path && idx

    incoming_context = build_turn_context(
      roads,
      path[idx],
      path[idx + 1],
      path[idx + 2],
      :incoming
    )
    return incoming_context if incoming_context

    return nil unless idx.positive?

    build_turn_context(
      roads,
      path[idx - 1],
      path[idx],
      path[idx + 1],
      :outgoing
    )
  end

  def self.build_turn_context(roads, from, via, to, segment_role)
    return nil unless from && via && to
    return nil unless RoadGraph.road_kind_at(roads, via[0], via[1]) == :cross

    inbound_delta = [via[0] - from[0], via[1] - from[1]]
    outbound_delta = [to[0] - via[0], to[1] - via[1]]
    return nil if inbound_delta == outbound_delta

    {
      crossroad: via,
      inbound_delta: inbound_delta,
      outbound_delta: outbound_delta,
      segment_role: segment_role
    }
  end
end
