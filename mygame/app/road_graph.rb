module RoadGraph
  CONNECTIONS = {
    ne: [[-1, 0], [1, 0]],
    nw: [[0, -1], [0, 1]],
    cross: [[-1, 0], [1, 0], [0, -1], [0, 1]]
  }.freeze

  BUILDING_ACCESS_DELTAS = [[0, -1], [-1, 0], [1, 0], [0, 1]].freeze

  def self.road_tile?(roads, col, row)
    CONNECTIONS.key?(roads[GridCoordinates.tile_key(col, row)])
  end

  def self.road_neighbors(roads, col, row)
    road_kind = roads[GridCoordinates.tile_key(col, row)]
    return [] unless CONNECTIONS.key?(road_kind)

    CONNECTIONS[road_kind].filter_map do |delta_col, delta_row|
      next_col = col + delta_col
      next_row = row + delta_row
      next unless GridCoordinates.in_bounds?(next_col, next_row)
      next unless traversable_edge?(roads, col, row, next_col, next_row)

      [next_col, next_row]
    end
  end

  def self.building_access_tiles(roads, col, row)
    BUILDING_ACCESS_DELTAS.filter_map do |delta_col, delta_row|
      next_col = col + delta_col
      next_row = row + delta_row
      next unless GridCoordinates.in_bounds?(next_col, next_row)
      next unless road_tile?(roads, next_col, next_row)

      [next_col, next_row]
    end.sort_by { |next_col, next_row| tile_order(next_col, next_row) }
  end

  def self.traversable_edge?(roads, from_col, from_row, to_col, to_row)
    delta_col = to_col - from_col
    delta_row = to_row - from_row

    supports_direction?(roads, from_col, from_row, delta_col, delta_row) &&
      supports_direction?(roads, to_col, to_row, -delta_col, -delta_row)
  end

  def self.supports_direction?(roads, col, row, delta_col, delta_row)
    road_kind = roads[GridCoordinates.tile_key(col, row)]
    CONNECTIONS.fetch(road_kind, []).include?([delta_col, delta_row])
  end

  def self.tile_order(col, row)
    row * GRID_SIZE + col
  end
end
