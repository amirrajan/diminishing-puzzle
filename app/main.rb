require 'app/camera.rb'

class Game
  attr_gtk

  def tick
    defaults
    input
    calc
    render
    outputs.watch "#{GTK.current_framerate} FPS"
  end

  def defaults
    state.gravity              ||= -1
    state.player ||= {}

    player.x                   ||= 400
    player.y                   ||= 64
    player.w                   ||= 50
    player.h                   ||= 50
    player.dx                  ||= 0
    player.dy                  ||= 0
    player.on_ground           ||= false

    player.max_speed           ||= 10
    player.jump_power          ||= 28
    state.preview ||= []

    state.tile_size            ||= 64
    if !state.tiles
      state.tiles = load_level "data/level-1.txt"
    end

    if !state.camera
      state.camera = {
        x: 0,
        y: 0,
        target_x: 0,
        target_y: 0,
        target_scale: 0.75,
        scale: 0.75
      }
    end
  end

  def load_level file_path
    contents = GTK.read_file file_path
    contents.each_line.map do |l|
      ordinal_x, ordinal_y = l.split(",").map(&:to_i)
      r = { ordinal_x: ordinal_x, ordinal_y: ordinal_y }

      r.merge(x: r.ordinal_x * state.tile_size,
              y: r.ordinal_y * state.tile_size,
              w: state.tile_size,
              h: state.tile_size)
    end
  end

  def save_level file_path
    contents = state.tiles.map do |t|
      "#{t[:ordinal_x]},#{t[:ordinal_y]}"
    end.join("\n")
    GTK.write_file file_path, contents
  end

  def input
    input_jump
    input_move
  end

  def input_jump
    if inputs.keyboard.key_down.space || inputs.controller_one.key_down.a
      state.previous_player_state = player.merge({})
      entity_jump player
    end
  end

  def input_move
    if inputs.left
      player.dx -= player.max_speed
    elsif inputs.right
      player.dx += player.max_speed
    else
      player.dx = 0
    end
    player.dx = player.dx.clamp(-player.max_speed, player.max_speed)
  end

  def calc
    calc_physics player
    calc_game_over
    calc_level_edit
    calc_camera
  end

  def mouse_tile_rect
    ordinal_x = inputs.mouse.x.idiv(64)
    ordinal_y = inputs.mouse.y.idiv(64)
    { x: ordinal_x * 64, y: ordinal_y * 64, w: 64, h: 64, ordinal_x: ordinal_x, ordinal_y: ordinal_y }
  end

  def calc_level_edit
    calc_preview

    state.hovered_tile = { x_ordinal: inputs.mouse.x.idiv(64),
                           x: inputs.mouse.x.idiv(64) * 64,
                           y_ordinal: inputs.mouse.x.idiv(64),
                           y: inputs.mouse.y.idiv(64) * 64,
                           path: "sprites/square/white.png",
                           w: 64,
                           h: 64 }

    world_mouse = Camera.to_world_space state.camera, inputs.mouse
    ifloor_x = world_mouse.x.ifloor(64)
    ifloor_y = world_mouse.y.ifloor(64)

    state.mouse_world_rect =  { x: ifloor_x,
                                y: ifloor_y,
                                w: 64,
                                h: 64 }

    if inputs.mouse.click
      rect = state.mouse_world_rect
      collision = Geometry.find_intersect_rect rect, state.tiles
      if collision
        state.tiles.delete collision
      else
        state.tiles << { ordinal_x: rect.x.idiv(64), ordinal_y: rect.y.idiv(64) }
      end
      save_level "data/temp-1.txt"
      state.tiles = load_level "data/temp-1.txt"
    end

    if inputs.controller_one.key_down.select
      state.player = state.previous_player_state if state.previous_player_state
    end

    if inputs.keyboard.key_down.equal_sign || inputs.keyboard.key_down.plus
      state.camera.target_scale += 0.25
    elsif inputs.keyboard.key_down.minus
      state.camera.target_scale -= 0.25
      state.camera.target_scale = 0.25 if state.camera.target_scale < 0.25
    elsif inputs.keyboard.zero
      state.camera.target_scale = 1
    end
  end

  def calc_camera
    if !state.camera
      state.camera = {
        x: 0,
        y: 0,
        target_x: 0,
        target_y: 0,
        target_scale: 1,
        scale: 1
      }
    end

    ease = 0.1
    state.camera.scale += (state.camera.target_scale - state.camera.scale) * ease
    state.camera.target_x = player.x
    state.camera.target_y = player.y

    state.camera.x += (state.camera.target_x - state.camera.x) * ease
    state.camera.y += (state.camera.target_y - state.camera.y) * ease
  end

  def calc_preview
    if Kernel.tick_count.zmod? 60
      entity = state.player.merge({})
      entity.dx = 0
      entity_jump entity
      state.preview << entity

      entity = state.player.merge({})
      entity.dx = state.player.max_speed
      entity_jump entity
      state.preview << entity

      entity = state.player.merge({})
      entity.dx = -state.player.max_speed
      entity_jump entity
      state.preview << entity

      entity = state.player.merge({})
      entity.dx = state.player.max_speed
      entity.dy = 0
      state.preview << entity

      entity = state.player.merge({})
      entity.dx = -state.player.max_speed
      entity.dy = 0
      state.preview << entity
    end

    state.preview.each do |entity|
      calc_physics entity
    end

    state.preview.reject! do |entity|
      entity.on_ground_at && entity.on_ground_at.elapsed_time > 30 || entity.y < -64
    end
  end

  def calc_physics target
    target.x  += target.dx
    collision = Geometry.find_intersect_rect target, state.tiles
    if collision
      if target.dx > 0
        target.x = collision.rect.x - target.w
      elsif target.dx < 0
        target.x = collision.rect.x + collision.rect.w
      end
    end

    target.dy ||= 0

    target.y += target.dy
    collision = Geometry.find_intersect_rect target, state.tiles
    if collision
      if target.dy > 0
        target.y = collision.rect.y - target.h
      elsif target.dy < 0
        target.y = collision.rect.y + collision.rect.h
        target.on_ground = true
        target.on_ground_at ||= Kernel.tick_count
      end
      target.dy = 0
      target.jump_at = nil
      target.started_falling_at = nil
    else
      target.on_ground = false
      target.on_ground_at = nil
      target.started_falling_at ||= Kernel.tick_count
    end
    target.dy = target.dy + state.gravity
    drop_fast = target.dy < 0
    if drop_fast
      target.dy = target.dy + state.gravity
      target.dy = target.dy + state.gravity
    end
    target.dy = target.dy.clamp(-state.tile_size, state.tile_size)
  end

  def calc_game_over
    if player.y < -64 || inputs.controller_one.key_down.start
      player.x = 400
      player.y = 64
      player.dx = 0
      player.dy = 0
      player.jump_power = 28
    end
  end

  def render
    render_player
    render_tiles

    outputs[:scene].w = 1500
    outputs[:scene].h = 1500
    outputs[:scene].primitives << Camera.to_screen_space(state.camera,
                                                         state.mouse_world_rect.merge(path: "sprites/square/white.png",
                                                                                      r: 255,
                                                                                      g: 255,
                                                                                      b: 255,
                                                                                      a: 128))

    outputs.sprites << { **Camera.viewport, path: :scene }
  end

  def render_player
    player_prefab = Camera.to_screen_space state.camera, (player.merge path: "sprites/square/red.png")

    outputs[:scene].sprites << player_prefab

    outputs[:scene].sprites << state.preview.map do |t|
      Camera.to_screen_space state.camera, (t.merge path: "sprites/square/blue.png", a: 128)
    end
  end

  def render_tiles
    outputs[:scene].sprites << state.tiles.map do |t|
      Camera.to_screen_space state.camera, (t.merge path: 'sprites/square/white.png',
                                                    x: t.ordinal_x * state.tile_size,
                                                    y: t.ordinal_y * state.tile_size,
                                                    w: state.tile_size,
                                                    h: state.tile_size)
    end
  end

  def player
    state.player ||= {}
  end

  def entity_jump target
    can_jump = target.on_ground || (target.started_falling_at && target.started_falling_at.elapsed_time < 4)
    return if !can_jump
    target.jump_power = (target.jump_power * 0.90).floor
    target.dy = target.jump_power
    target.jump_at = Kernel.tick_count
  end
end

def boot args
  args.state = {}
end

def tick args
  $game ||= Game.new
  $game.args = args
  $game.tick
end

def reset args
  $game = nil
end

# GTK.reset_and_replay "replay.txt", speed: 3
