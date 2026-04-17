class InputHandler
  def process(args, camera)
    if args.inputs.keyboard.key_down.b
      args.state.mode = (args.state.mode == :build) ? :pan : :build
    end

    if args.state.mode == :pan
      camera.x -= PAN_SPEED if args.inputs.keyboard.right
      camera.x += PAN_SPEED if args.inputs.keyboard.left
      camera.y -= PAN_SPEED if args.inputs.keyboard.up
      camera.y += PAN_SPEED if args.inputs.keyboard.down

      if args.inputs.mouse.button_left && args.inputs.mouse.moved
        camera.x += args.inputs.mouse.relative_x
        camera.y += args.inputs.mouse.relative_y
      end
    else
      if args.inputs.mouse.click
        col, row = screen_to_grid(
          args.inputs.mouse.click.x,
          args.inputs.mouse.click.y,
          TILE_W, ORIGIN_X, ORIGIN_Y, camera
        )
        if col >= 0 && col < GRID_SIZE && row >= 0 && row < GRID_SIZE
          key = "#{col},#{row}"
          if args.state.buildings[key]
            args.state.buildings.delete(key)
          else
            args.state.buildings[key] = true
          end
        end
      end
    end
  end

  private

  def screen_to_grid(mx, my, tile_w, origin_x, origin_y, camera)
    dx =  (mx - origin_x - camera.x).to_f
    dy = -(my - origin_y - camera.y).to_f

    u = dx / (tile_w / 2.0)
    v = dy / (tile_w / 4.0)

    col = ((u + v) / 2.0).floor
    row = ((v - u) / 2.0).floor
    [col, row]
  end
end
