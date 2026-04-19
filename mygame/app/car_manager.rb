class CarManager
  def initialize(pathfinder = RoadPathfinder.new)
    @gates        = TrafficGates.new
    @stops        = AllWayStopController.new(@gates)
    @path_planner = CarPathPlanner.new(pathfinder, @stops)
    @fleet        = CarFleet.new(@path_planner, @gates)
    @motion       = CarMotion.new(@path_planner, @stops)
    @renderer     = CarRenderer.new
  end

  def recompute(state)
    @fleet.recompute(state)
  end

  def tick(state)
    state.cars.each { |car| @motion.prepare(state, car) }
    state.car_slot_occupancy = @gates.build_slot_occupancy(state.cars)

    verdicts = @gates.resolve(state.cars, state.car_slot_occupancy)
    stop_denied = @stops.resolve(state, state.cars)

    survivors = []
    state.cars.each do |car|
      verdict = verdicts[car]
      verdict.stop_denied = stop_denied.include?(car)
      survivors << car if @motion.advance(state, car, verdict)
    end
    state.cars = survivors
  end

  def enqueue_world(args, camera, queue)
    @renderer.enqueue_world(args.state.cars, args.state.roads, camera, queue)
  end
end
