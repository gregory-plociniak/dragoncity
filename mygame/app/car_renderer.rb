class CarRenderer
  AMBULANCE_SPRITE_DIMENSIONS = {
    'sprites/ambulance_NE.png' => [35, 31],
    'sprites/ambulance_NW.png' => [35, 31],
    'sprites/ambulance_SE.png' => [35, 35],
    'sprites/ambulance_SW.png' => [35, 36]
  }
  TURN_BLEND_IN_START_PROGRESS = 0.72
  TURN_BLEND_OUT_END_PROGRESS = 0.28
  TURN_SPRITE_SWITCH_PHASE = 0.58
  # Main lane-distance control. Increase to push cars farther from the road
  # centerline; decrease to pull them back toward the middle.
  LANE_OFFSET_PIXELS = 5
  # Global vertical placement for the car sprite after lane math. Make this
  # more negative to raise all cars, or closer to 0 to lower them.
  GLOBAL_CAR_Y_BIAS = 25
  # Sprite-art compensation after the geometric lane offset. Use this when a
  # specific travel direction still rides too close to a sidewalk because the
  # road art is not visually centered on the tile.
  DIRECTIONAL_ART_BIAS = {
    [1, 0] => [0, 0], # bottom-right travel
    [-1, 0] => [0, 0],
    [0, 1] => [0, 0],
    [0, -1] => [-15, -8] # top-right travel: move left slightly and raise toward the asphalt
  }.freeze
  # Screen-space lane shift tuned by eye. The offset is computed from the
  # segment's actual projected screen vector, then rotated to the traveler's
  # right side so it stays perpendicular to the road in all four directions.

  def enqueue_world(cars, roads, camera, queue)
    cars.each do |car|
      path = car[:leg][:path]
      from = path[car[:step_index]]
      to   = path[car[:step_index] + 1]
      next unless from && to

      delta_col = to[0] - from[0]
      delta_row = to[1] - from[1]
      sx, sy = interpolated_screen_position(camera, from, to, car[:progress])
      lane_dx, lane_dy = lane_offset_for(roads, car)
      sx += lane_dx
      sy += lane_dy

      sprite_path = sprite_for_car(roads, car, delta_col, delta_row)
      w, h = AMBULANCE_SPRITE_DIMENSIONS[sprite_path]

      from_depth = from[0] + from[1]
      to_depth = to[0] + to[1]
      anchor_tile = to_depth >= from_depth ? to : from
      # Front-lane travel (SE/NE) sits on the screen-down side of the road
      # and must draw above back-lane travel (NW/SW) when two cars pass on
      # the same segment. Keep the bias inside [0, 1) so the car still sorts
      # above its anchor tile's ground and below the next tile's ground.
      lane_front_bias = (delta_col - delta_row) <=> 0
      queue.push(
        depth: [from_depth, to_depth].max + 0.5 + lane_front_bias * 0.1,
        layer: RenderQueue::LAYER_CAR,
        order: GridCoordinates.tile_order(anchor_tile[0], anchor_tile[1]),
        sprite: {
          x: sx - w / 2,
          y: sy - TILE_H / 2 - h / 2 + GLOBAL_CAR_Y_BIAS,
          w: w,
          h: h,
          path: sprite_path
        }
      )
    end
  end

  private

  def interpolated_screen_position(camera, from, to, progress)
    from_sx, from_sy = camera.world_to_screen(from[0], from[1], TILE_W, FOOTPRINT_H, ORIGIN_X, ORIGIN_Y)
    to_sx, to_sy = camera.world_to_screen(to[0], to[1], TILE_W, FOOTPRINT_H, ORIGIN_X, ORIGIN_Y)

    sx = from_sx + (to_sx - from_sx) * progress
    sy = from_sy + (to_sy - from_sy) * progress
    [sx, sy]
  end

  def lane_offset_for(roads, car)
    path = car[:leg][:path]
    step_index = car[:step_index]
    from = path[step_index]
    to = path[step_index + 1]
    return [0, 0] unless from && to

    turn_context = CarGeometry.crossroad_turn_context(roads, car)
    return total_direction_offset(to[0] - from[0], to[1] - from[1]) unless turn_context

    turn_offset_for(turn_context, car[:progress])
  end

  def right_hand_lane_offset(delta_col, delta_row)
    screen_dx, screen_dy = CarGeometry.projected_step_vector(delta_col, delta_row)
    # Flip these signs if the car ends up on the left side of travel instead of the right.
    right_dx = screen_dy
    right_dy = -screen_dx
    length = Math.sqrt((right_dx * right_dx) + (right_dy * right_dy))
    return [0, 0] if length.zero?

    [
      # LANE_OFFSET_PIXELS above is the main knob for how dramatic the lane shift looks.
      right_dx / length * LANE_OFFSET_PIXELS,
      right_dy / length * LANE_OFFSET_PIXELS
    ]
  end

  def total_direction_offset(delta_col, delta_row)
    lane_dx, lane_dy = right_hand_lane_offset(delta_col, delta_row)
    bias_dx, bias_dy = art_bias_for(delta_col, delta_row)
    [lane_dx + bias_dx, lane_dy + bias_dy]
  end

  def turn_offset_for(turn_context, progress)
    inbound_dx, inbound_dy = total_direction_offset(*turn_context[:inbound_delta])
    outbound_dx, outbound_dy = total_direction_offset(*turn_context[:outbound_delta])
    phase = turn_phase(turn_context, progress)

    [
      lerp(inbound_dx, outbound_dx, phase),
      lerp(inbound_dy, outbound_dy, phase)
    ]
  end

  def turn_phase(turn_context, progress)
    if turn_context[:segment_role] == :incoming
      blend_progress(progress, TURN_BLEND_IN_START_PROGRESS, 1.0) * 0.5
    else
      0.5 + blend_progress(progress, 0.0, TURN_BLEND_OUT_END_PROGRESS) * 0.5
    end
  end

  def blend_progress(progress, start_progress, end_progress)
    span = end_progress - start_progress
    return progress >= end_progress ? 1.0 : 0.0 if span <= 0.0

    ((progress - start_progress) / span).clamp(0.0, 1.0)
  end

  def lerp(from, to, phase)
    from + (to - from) * phase
  end

  def art_bias_for(delta_col, delta_row)
    # Fine-tune per-direction sidewalk compensation here. Negative Y raises the
    # car on screen; positive Y lowers it.
    DIRECTIONAL_ART_BIAS.fetch([delta_col, delta_row], [0, 0])
  end

  def sprite_for_car(roads, car, delta_col, delta_row)
    turn_context = CarGeometry.crossroad_turn_context(roads, car)
    return sprite_for_delta(delta_col, delta_row) unless turn_context

    sprite_delta = if turn_phase(turn_context, car[:progress]) < TURN_SPRITE_SWITCH_PHASE
                     turn_context[:inbound_delta]
                   else
                     turn_context[:outbound_delta]
                   end

    sprite_for_delta(*sprite_delta)
  end

  def sprite_for_delta(delta_col, delta_row)
    if delta_col > 0
      'sprites/ambulance_SE.png'
    elsif delta_col < 0
      'sprites/ambulance_NW.png'
    elsif delta_row > 0
      'sprites/ambulance_SW.png'
    else
      'sprites/ambulance_NE.png'
    end
  end
end
