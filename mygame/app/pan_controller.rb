class PanController
  def handle(args, camera)
    camera.x -= PAN_SPEED if args.inputs.keyboard.right
    camera.x += PAN_SPEED if args.inputs.keyboard.left
    camera.y -= PAN_SPEED if args.inputs.keyboard.up
    camera.y += PAN_SPEED if args.inputs.keyboard.down

    if args.inputs.mouse.button_left && args.inputs.mouse.moved
      camera.x += args.inputs.mouse.relative_x
      camera.y += args.inputs.mouse.relative_y
    end
  end
end
