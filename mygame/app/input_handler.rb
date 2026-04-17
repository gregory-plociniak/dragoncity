class InputHandler
  def initialize
    @pan      = PanController.new
    @building = BuildingPlacer.new
    @roads    = RoadBuilder.new
  end

  def process(args, camera)
    @building.prune_expired(args.state)
    return if handle_ui_click(args)

    case args.state.mode
    when :pan
      @pan.handle(args, camera)
    when :build
      @building.handle_click(args, camera)
    when :roads
      @roads.handle_input(args, camera)
    end
  end

  private

  def handle_ui_click(args)
    return false unless args.inputs.mouse.click

    if args.inputs.mouse.intersect_rect?(args.state.reset_button)
      GTK.reset_next_tick
      return true
    end

    args.state.mode_buttons.each do |mode, rect|
      next unless args.inputs.mouse.intersect_rect?(rect)

      change_mode(args, mode)
      return true
    end

    false
  end

  def change_mode(args, new_mode)
    @roads.clear_preview(args.state)
    args.state.mode = new_mode
  end
end
