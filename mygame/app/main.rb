require 'app/isometric_camera.rb'
require 'app/grid_coordinates.rb'
require 'app/game_state.rb'
require 'app/render_queue.rb'
require 'app/grid_renderer.rb'
require 'app/pan_controller.rb'
require 'app/building_placer.rb'
require 'app/road_builder.rb'
require 'app/road_graph.rb'
require 'app/road_pathfinder.rb'
require 'app/car_manager.rb'
require 'app/input_handler.rb'

GRID_SIZE = 10
TILE_W = 132
TILE_H = 101
# Diamond footprint height (ground projection), distinct from TILE_H which is the
# full sprite height including elevation pixels above the diamond.
FOOTPRINT_H = TILE_W / 2
# ORIGIN_X ~540 centers the 10x10 grid (full width ~1188px) on a 1280px screen
ORIGIN_X = 540
ORIGIN_Y = 660
PAN_SPEED = 4
BUILDING_TILE_X_OFFSET = 0
BUILDING_TILE_Y_OFFSET = 26
BUILD_INVALID_FLASH_FRAMES = 20

def initialize_runtime_objects
  $camera = IsometricCamera.new
  $grid_renderer = GridRenderer.new
  $car_manager = CarManager.new
  $input_handler = InputHandler.new
  $render_queue = RenderQueue.new
end

initialize_runtime_objects

def tick(args)
  GameState.initialize!(args.state)
  args.state.frame_index += 1

  args.outputs.background_color = [0, 0, 0]
  $car_manager.tick(args.state)
  $grid_renderer.enqueue_world(args, $camera, $render_queue)
  $car_manager.enqueue_world(args, $camera, $render_queue)
  $render_queue.flush_to(args.outputs)
  $grid_renderer.render_ui(args)
  $input_handler.process(args, $camera)
end

def reset(args)
  initialize_runtime_objects
end
