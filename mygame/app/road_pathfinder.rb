class RoadPathfinder
  def find_path(roads, start_tile, goal_tile)
    return nil unless start_tile && goal_tile

    start_col, start_row = start_tile
    goal_col, goal_row = goal_tile

    return nil unless RoadGraph.road_tile?(roads, start_col, start_row)
    return nil unless RoadGraph.road_tile?(roads, goal_col, goal_row)
    return [start_tile] if start_tile == goal_tile

    open_set = [start_tile]
    came_from = {}
    g_score = Hash.new(Float::INFINITY)
    f_score = Hash.new(Float::INFINITY)

    g_score[start_tile] = 0
    f_score[start_tile] = heuristic(start_tile, goal_tile)

    until open_set.empty?
      current = best_open_tile(open_set, f_score, g_score)

      return rebuild_path(came_from, current) if current == goal_tile

      open_set.delete(current)

      RoadGraph.road_neighbors(roads, current[0], current[1])
               .sort_by { |col, row| tile_order(col, row) }
               .each do |neighbor|
        tentative_g = g_score[current] + 1
        next unless tentative_g < g_score[neighbor]

        came_from[neighbor] = current
        g_score[neighbor] = tentative_g
        f_score[neighbor] = tentative_g + heuristic(neighbor, goal_tile)
        open_set << neighbor unless open_set.include?(neighbor)
      end
    end

    nil
  end

  private

  def best_open_tile(open_set, f_score, g_score)
    best_tile = open_set[0]

    open_set.each do |tile|
      next unless better_tile?(tile, best_tile, f_score, g_score)

      best_tile = tile
    end

    best_tile
  end

  def better_tile?(candidate, current_best, f_score, g_score)
    return true unless current_best

    candidate_f = f_score[candidate]
    best_f = f_score[current_best]
    return true if candidate_f < best_f
    return false if candidate_f > best_f

    candidate_g = g_score[candidate]
    best_g = g_score[current_best]
    return true if candidate_g < best_g
    return false if candidate_g > best_g

    candidate_order = tile_order(candidate[0], candidate[1])
    best_order = tile_order(current_best[0], current_best[1])
    candidate_order < best_order
  end

  def heuristic(tile, goal_tile)
    (tile[0] - goal_tile[0]).abs + (tile[1] - goal_tile[1]).abs
  end

  def tile_order(col, row)
    row * GRID_SIZE + col
  end

  def rebuild_path(came_from, current)
    path = [current]

    while came_from[current]
      current = came_from[current]
      path << current
    end

    path.reverse
  end
end
