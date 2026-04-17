require 'app/isometric_camera.rb'
require 'app/grid_coordinates.rb'
require 'app/game_state.rb'
require 'app/grid_renderer.rb'
require 'app/pan_controller.rb'
require 'app/building_placer.rb'
require 'app/road_builder.rb'
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
BUILD_INVALID_FLASH_FRAMES = 20

def initialize_runtime_objects
  $camera = IsometricCamera.new
  $grid_renderer = GridRenderer.new
  $input_handler = InputHandler.new
end

initialize_runtime_objects

def tick args
  GameState.initialize!(args.state)
  args.state.frame_index += 1

  args.outputs.background_color = [0, 0, 0]
  $grid_renderer.render(args, $camera)
  $input_handler.process(args, $camera)
end

def reset args
  initialize_runtime_objects
end
