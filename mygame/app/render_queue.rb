class RenderQueue
  LAYER_GROUND = 0
  LAYER_PREVIEW = 1
  LAYER_BUILDING = 2
  LAYER_CAR = 3

  def initialize
    @items = []
  end

  def push(depth:, layer:, order:, sprite:)
    @items << [depth, layer, order, @items.size, sprite]
  end

  def flush_to(outputs)
    sorted = @items.sort_by { |depth, layer, order, seq, _| [depth, layer, order, seq] }
    sorted.each { |_, _, _, _, sprite| outputs.sprites << sprite }
    @items.clear
  end
end
