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
end
