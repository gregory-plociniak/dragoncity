module GameState
  def self.initialize!(state)
    state.mode           ||= :pan
    state.buildings      ||= {}
    state.roads          ||= {}
    state.road_preview   ||= {}
    state.road_drag_last ||= nil
    state.road_drag_kind ||= nil
    state.invalid_build_tiles ||= {}
    state.frame_index    ||= 0
    state.mode_buttons   ||= {
      pan:   Layout.rect(row: 0, col: 0, w: 3, h: 1),
      build: Layout.rect(row: 0, col: 3, w: 3, h: 1),
      roads: Layout.rect(row: 0, col: 6, w: 3, h: 1)
    }
    state.reset_button   ||= Layout.rect(row: 0, col: 21, w: 3, h: 1)
  end
end
