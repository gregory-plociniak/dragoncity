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
BUILDING_Y_OFFSET = 20   # pixels upward; tune this value
BUILDING_SCALE    = 0.8  # relative to tile size; tune this value

$camera = IsometricCamera.new
$grid_renderer = GridRenderer.new
$input_handler = InputHandler.new

def tick args
  args.state.mode      ||= :pan
  args.state.buildings ||= {}

  args.outputs.background_color = [0, 0, 0]
  $grid_renderer.render(args, $camera)
  $input_handler.process(args, $camera)
end
