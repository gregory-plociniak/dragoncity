require 'app/isometric_camera.rb'
require 'app/grid_renderer.rb'
require 'app/input_handler.rb'

GRID_SIZE = 10
TILE_W    = 132
TILE_H    = 101
# ORIGIN_X ~540 centers the 10x10 grid (full width ~1188px) on a 1280px screen
ORIGIN_X  = 540
ORIGIN_Y  = 660
PAN_SPEED        = 4
BUILDING_TILE_X_OFFSET = 0
BUILDING_TILE_Y_OFFSET = 26

$camera = IsometricCamera.new
$grid_renderer = GridRenderer.new
$input_handler = InputHandler.new

def tick args
  args.state.mode           ||= :pan
  args.state.buildings      ||= {}
  args.state.roads          ||= {}
  args.state.road_preview   ||= {}
  args.state.road_drag_last ||= nil
  args.state.road_drag_kind ||= nil
  args.state.mode_buttons   ||= {
    pan:   Layout.rect(row: 0, col: 0, w: 3, h: 1),
    build: Layout.rect(row: 0, col: 3, w: 3, h: 1),
    roads: Layout.rect(row: 0, col: 6, w: 3, h: 1)
  }

  args.outputs.background_color = [0, 0, 0]
  $grid_renderer.render(args, $camera)
  $input_handler.process(args, $camera)
end
