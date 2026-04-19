class CarMotion
  CROSSOVER_THRESHOLD = 0.5
  CROSSOVER_EPSILON = 0.001
  ALL_WAY_STOP_LINE_PROGRESS = 0.65
  ALL_WAY_STOP_QUEUE_PROGRESS = 0.3
  STOP_BRAKE_PER_TICK = 0.003
  STOP_ACCEL_PER_TICK = 0.004
  STALL_TICKS_BEFORE_REPATH = 180
  DEFAULT_SPEED = 0.02

  def initialize(path_planner, stops)
    @path_planner = path_planner
    @stops = stops
  end

  def prepare(state, car)
    car[:current_speed] ||= car[:speed] || DEFAULT_SPEED
    stop_crossroad = @stops.active_stop_crossroad_for(state.roads, car)

    unless stop_crossroad
      @stops.clear_state(car)
      car[:current_speed] = accelerate_toward_cruise(car)
      return
    end

    if car[:stop_crossroad] != stop_crossroad
      @stops.clear_state(car)
      car[:stop_crossroad] = stop_crossroad
    end

    if car[:stop_go_token] == stop_crossroad
      car[:current_speed] = accelerate_toward_cruise(car)
      return
    end

    if @stops.at_or_past_stop_line?(car)
      car[:progress] = ALL_WAY_STOP_LINE_PROGRESS
      car[:current_speed] = 0.0
      car[:stop_arrival_frame] ||= state.frame_index
      return
    end

    if @stops.should_brake_for_stop_line?(car)
      car[:current_speed] = [movement_speed(car) - STOP_BRAKE_PER_TICK, 0.0].max
    else
      car[:current_speed] = accelerate_toward_cruise(car)
    end
  end

  def advance(state, car, verdict)
    stop_crossroad = @stops.stop_crossroad_for(state.roads, car)

    if @stops.approach_entry_denied?(state.roads, state.car_slot_occupancy, car)
      clamp_below_step(car)
      reset_stall(car)
      return true
    end

    if @stops.queue_denied?(state.car_slot_occupancy, car, stop_crossroad)
      clamp_below_stop_queue(car)
      reset_stall(car)
      return true
    end

    if verdict.midpoint_denied
      clamp_below_midpoint(car)
      record_stall(state, car)
      return true
    end

    if verdict.stop_denied
      clamp_below_stop_line(car)
      reset_stall(car)
      return true
    end

    if verdict.step_denied
      if @stops.waits_at_stop_line_without_go_token?(car, stop_crossroad)
        clamp_below_stop_line(car)
        reset_stall(car)
      elsif stop_crossroad && car[:stop_go_token] == stop_crossroad &&
            car[:progress] <= ALL_WAY_STOP_LINE_PROGRESS + CROSSOVER_EPSILON
        clamp_below_stop_line(car)
        record_stall(state, car)
      else
        clamp_below_step(car)
        record_stall(state, car)
      end
      return true
    end

    car[:progress] += movement_speed(car)
    if @stops.exiting_owned_crossroad?(car) && car[:progress] >= CROSSOVER_THRESHOLD
      @stops.clear_state(car)
    end

    if stop_crossroad && car[:stop_go_token] != stop_crossroad &&
       car[:progress] >= ALL_WAY_STOP_LINE_PROGRESS
      car[:progress] = ALL_WAY_STOP_LINE_PROGRESS
      car[:current_speed] = 0.0
      car[:stop_arrival_frame] ||= state.frame_index
      reset_stall(car)
      return true
    end

    reset_stall(car)
    while car[:progress] >= 1.0
      car[:progress] -= 1.0
      car[:step_index] += 1

      next if car[:step_index] < car[:leg][:path].size - 1

      next_leg = @path_planner.plan_next_leg(state.roads, car)
      return false unless next_leg

      car[:leg] = next_leg
      car[:step_index] = 0
      car[:pending_repath] = false
    end
    true
  end

  private

  def clamp_below_midpoint(car)
    car[:progress] = [car[:progress] + movement_speed(car), CROSSOVER_THRESHOLD - CROSSOVER_EPSILON].min
  end

  def clamp_below_stop_queue(car)
    limit = [car[:progress], ALL_WAY_STOP_QUEUE_PROGRESS].max
    car[:progress] = [car[:progress] + movement_speed(car), limit].min
    car[:current_speed] = 0.0 if car[:progress] >= ALL_WAY_STOP_QUEUE_PROGRESS
  end

  def clamp_below_stop_line(car)
    car[:progress] = [car[:progress] + movement_speed(car), ALL_WAY_STOP_LINE_PROGRESS].min
    car[:current_speed] = 0.0 if car[:progress] >= ALL_WAY_STOP_LINE_PROGRESS
  end

  def clamp_below_step(car)
    car[:progress] = [car[:progress] + movement_speed(car), 1.0 - CROSSOVER_EPSILON].min
  end

  def reset_stall(car)
    car[:stall_ticks] = 0
  end

  def record_stall(state, car)
    car[:stall_ticks] = (car[:stall_ticks] || 0) + 1
    if car[:stall_ticks] >= STALL_TICKS_BEFORE_REPATH
      @path_planner.try_mid_leg_repath(state, car)
      car[:stall_ticks] = 0
    end
  end

  def accelerate_toward_cruise(car)
    cruise_speed = car[:speed] || DEFAULT_SPEED
    current_speed = movement_speed(car)

    if current_speed < cruise_speed
      [current_speed + STOP_ACCEL_PER_TICK, cruise_speed].min
    elsif current_speed > cruise_speed
      [current_speed - STOP_BRAKE_PER_TICK, cruise_speed].max
    else
      cruise_speed
    end
  end

  def movement_speed(car)
    car[:current_speed] || car[:speed] || DEFAULT_SPEED
  end
end
