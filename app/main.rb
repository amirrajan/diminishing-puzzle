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

  def new_player
    {
      x: 330,
      y: 64,
      w: 50,
      h: 50,
      dx: 0,
      dy: 0,
      on_ground: false,
      facing_x: 1,
      max_speed: 10,
      jump_power: 29,
      jumps_left: 6,
      jumps_performed: 0,
      collected_goals: [],
      dashes_left: 5,
      is_dashing: false,
      dashing_at: 0,
      start_dash_x: 0,
      end_dash_x: 0,
      is_dead: false,
      jump_at: 0,
      started_falling_at: nil,
      on_ground_at: 0,
      action: :idle,
      action_at: 0,
      animations: {
        idle: {
          frame_count: 16,
          hold_for: 4,
          repeat: true
        },
        jump: {
          frame_count: 2,
          hold_for: 4,
          repeat: true
        }
      }
    }
  end

  def defaults
    state.gravity              ||= -1

    if Kernel.tick_count == 0
      state.player = new_player
      state.level_editor_enabled = !GTK.production?
    end

    # simulation/physics DT (bullet time option)
    state.sim_dt        ||= 1.0
    state.target_sim_dt ||= 1.0

    state.preview ||= []
    state.dash_spline ||= [
      [0, 0.66, 1.0, 1.0]
    ]

    state.tile_size            ||= 64

    if !state.tiles
      load_level 0
    end

    if !state.camera
      state.camera = {
        x: player.x,
        y: player.y,
        target_x: 0,
        target_y: 0,
        target_scale: 0.75,
        target_scale_changed_at: 30,
        scale_lerp_duration: 30,
        scale: 0.25,
      }
    end
  end

  def load_level number
    state.current_level = number
    state.tiles =  load_rects "data/level-#{state.current_level}.txt"
    state.goals =  load_rects "data/level-#{state.current_level}-goals.txt"
    state.spikes = load_rects "data/level-#{state.current_level}-spikes.txt"
  end

  def load_rects file_path
    contents = GTK.read_file(file_path) || ""
    contents.each_line.map do |l|
      ordinal_x, ordinal_y = l.split(",").map(&:to_i)
      r = { ordinal_x: ordinal_x, ordinal_y: ordinal_y }

      r.merge(x: r.ordinal_x * state.tile_size,
              y: r.ordinal_y * state.tile_size,
              w: state.tile_size,
              h: state.tile_size)
    end
  end

  def save_rects file_path, rects
    contents = rects.map do |t|
      "#{t[:ordinal_x]},#{t[:ordinal_y]}"
    end.join("\n")
    GTK.write_file file_path, contents
  end

  def input
    input_jump
    input_move
    input_dash
  end

  def input_jump
    if inputs.keyboard.key_down.space || inputs.controller_one.key_down.a
      state.previous_player_state = player.copy
      entity_jump player
      # state.target_sim_dt = 0.25
    end
  end

  def input_move
    if inputs.left
      player.dx -= player.max_speed
      player.facing_x = -1
      player.left_at ||= Kernel.tick_count
      player.right_at  = nil
    elsif inputs.right
      player.dx += player.max_speed
      player.facing_x =  1
      player.right_at ||= Kernel.tick_count
      player.left_at    = nil
    else
      player.dx = 0
      player.left_at = nil
      player.right_at = nil
    end
    player.dx = player.dx.clamp(-player.max_speed, player.max_speed)
  end

  def input_dash
    if inputs.controller_one.key_down.r1 || inputs.keyboard.key_down.f || inputs.keyboard.key_down.l
      player.is_dashing = true
      player.dashing_at = Kernel.tick_count
      player.start_dash_x = player.x
      player.end_dash_x = player.x + state.tile_size * player.dashes_left * player.facing_x
      player.dashes_left -= 1
      player.dashes_left = player.dashes_left.clamp(0, 5)
    end
  end

  def calc
    state.sim_dt = state.sim_dt.lerp(state.target_sim_dt, 0.1)
    calc_physics player
    calc_goals
    calc_spikes
    calc_game_over
    calc_level_edit
    calc_camera
    # state.target_sim_dt = 1.0 if player.on_ground
  end

  def calc_goals
    goal = Geometry.find_intersect_rect player, state.goals
    if goal && !state.player.collected_goals.include?(goal)
      state.player.collected_goals << goal
    end
  end

  def calc_spikes
    spike = Geometry.find_intersect_rect player, state.spikes
    if spike
      state.player.is_dead = true
    end
  end

  def mouse_tile_rect
    ordinal_x = inputs.mouse.x.idiv(64)
    ordinal_y = inputs.mouse.y.idiv(64)
    { x: ordinal_x * 64, y: ordinal_y * 64, w: 64, h: 64, ordinal_x: ordinal_x, ordinal_y: ordinal_y }
  end

  def calc_level_edit
    return if !state.level_editor_enabled

    calc_preview

    if inputs.keyboard.ctrl_s
      save_rects "data/level-#{state.current_level}.txt", state.tiles
      save_rects "data/level-#{state.current_level}-goals.txt", state.goals
      save_rects "data/level-#{state.current_level}-spikes.txt", state.spikes
      GTK.notify "Saved level-#{state.current_level}"
    end

    state.level_editor_tile_type ||= :ground
    if inputs.keyboard.key_down.tab
      case state.level_editor_tile_type
      when :ground
        state.level_editor_tile_type = :goal
        GTK.notify "Tile type set to :goal"
      when :goal
        state.level_editor_tile_type = :spikes
        GTK.notify "Tile type set to :spikes"
      when :spikes
        state.level_editor_tile_type = :ground
        GTK.notify "Tile type set to :ground"
      end
    end

    world_mouse = Camera.to_world_space state.camera, inputs.mouse
    ifloor_x = world_mouse.x.ifloor(64)
    ifloor_y = world_mouse.y.ifloor(64)

    state.level_editor_mouse_rect =  { x: ifloor_x,
                                       y: ifloor_y,
                                       w: 64,
                                       h: 64 }

    target_rects = case state.level_editor_tile_type
                   when :ground
                     state.tiles
                   when :goal
                     state.goals
                   when :spikes
                     state.spikes
                   end

    if inputs.mouse.click
      rect = state.level_editor_mouse_rect
      collision = Geometry.find_intersect_rect rect, target_rects
      if collision
        target_rects.delete collision
      else
        target_rects << { ordinal_x: rect.x.idiv(64), ordinal_y: rect.y.idiv(64) }
      end

      save_rects "data/temp.txt", state.tiles
      state.tiles = load_rects "data/temp.txt"

      save_rects "data/temp-goals.txt", state.goals
      state.goals = load_rects "data/temp-goals.txt"

      save_rects "data/temp-spikes.txt", state.spikes
      state.spikes = load_rects "data/temp-spikes.txt"
    end

    if inputs.controller_one.key_down.select || inputs.keyboard.key_down.u
      state.player = state.previous_player_state if state.previous_player_state
    end

    if inputs.keyboard.key_down.equal_sign || inputs.keyboard.key_down.plus
      state.camera.target_scale /= 0.75
      if state.camera.target_scale_changed_at && state.camera.target_scale_changed_at.elapsed_time >= state.camera.scale_lerp_duration
        state.camera.target_scale_changed_at = Kernel.tick_count
      end
    elsif inputs.keyboard.key_down.minus
      state.camera.target_scale *= 0.75
      if state.camera.target_scale_changed_at && state.camera.target_scale_changed_at.elapsed_time >= state.camera.scale_lerp_duration
        state.camera.target_scale_changed_at = Kernel.tick_count
      end
      if state.camera.target_scale < 0.10
        state.camera.target_scale = 0.10
      end
    elsif inputs.keyboard.zero
      state.camera.target_scale = 1
      state.camera.target_scale_changed_at = Kernel.tick_count
    end
  end

  def calc_camera
    return if !state.camera.target_scale_changed_at

    ease = 0.01
    perc = Easing.smooth_start(start_at: state.camera.target_scale_changed_at,
                               duration: state.camera.scale_lerp_duration,
                               tick_count: Kernel.tick_count,
                               power: 3)
    state.camera.scale = state.camera.scale.lerp(state.camera.target_scale, perc)
    state.camera.target_x = player.x
    state.camera.target_y = player.y

    state.camera.x += (state.camera.target_x - state.camera.x) * 0.1
    state.camera.y += (state.camera.target_y - state.camera.y) * 0.1
  end

  def calc_preview
    return if !state.level_editor_enabled

    if inputs.keyboard.key_held.nine
      GTK.slowmo! 30
    end

    if Kernel.tick_count.zmod? 60
      entity = state.player.merge(dx: 0, created_at: Kernel.tick_count)
      entity_jump entity
      state.preview << entity

      entity = state.player.merge(dx: player.max_speed, created_at: Kernel.tick_count)
      entity_jump entity
      state.preview << entity

      entity = state.player.merge(dx: -player.max_speed, created_at: Kernel.tick_count)
      entity_jump entity
      state.preview << entity
    end

    state.preview.each do |entity|
      calc_physics entity
    end

    state.preview.reject! do |entity|
      entity.created_at.elapsed_time > 60 / state.sim_dt
    end
  end

  def calc_physics target
    if target.is_dashing
      current_progress = Easing.spline target.dashing_at,
                                       Kernel.tick_count,
                                       15.fdiv(state.sim_dt).to_i,
                                       state.dash_spline
      target.x = target.start_dash_x
      diff = target.end_dash_x - target.x
      target.x += diff * current_progress
      if target.dashing_at.elapsed_time >= 15.fdiv(state.sim_dt).to_i
        target.is_dashing = false
      end
    else
      target.x  += target.dx * state.sim_dt
    end

    collision = Geometry.find_intersect_rect target, state.tiles
    if collision
      target.is_dashing = false
      if target.dx > 0
        target.x = collision.rect.x - target.w
      elsif target.dx < 0
        target.x = collision.rect.x + collision.rect.w
      end
    end

    target.y += target.dy * state.sim_dt
    collision = Geometry.find_intersect_rect target, state.tiles
    if collision
      if target.dy > 0
        target.y = collision.rect.y - target.h
      elsif target.dy < 0
        target.y = collision.rect.y + collision.rect.h
        target.on_ground = true
        action! target, :idle
        target.on_ground_at = Kernel.tick_count
        target.started_falling_at = nil
      end
      target.dy = 0
      target.jump_at = nil
      target.started_falling_at = nil
    else
      target.on_ground = false
      target.on_ground_at = nil
      target.started_falling_at ||= Kernel.tick_count
    end
    if target.is_dashing
      target.dy = 0
    else
      target.dy = target.dy + state.gravity * state.sim_dt
    end
    drop_fast = target.dy < 0
    if drop_fast
      target.dy = target.dy + state.gravity * state.sim_dt
      target.dy = target.dy + state.gravity * state.sim_dt
    end
    target.dy = target.dy.clamp(-state.tile_size, state.tile_size)
  end

  def calc_game_over
    if player.y < -2000 || inputs.controller_one.key_down.start || player.is_dead
      if player.collected_goals.length == state.goals.length
        load_level state.current_level + 1
      end
      state.player = new_player
      state.camera.scale = 0.25
      state.camera.target_scale = 0.75
      state.camera.target_scale_changed_at = Kernel.tick_count + 30
    end
  end

  def action! target, action
    return if target.action == action
    target.action = action
    target.action_at = Kernel.tick_count
  end

  def render
    render_player
    render_tiles
    render_level_editor
    render_audio
    outputs[:scene].w = 1500
    outputs[:scene].h = 1500
    outputs.sprites << { **Camera.viewport, path: :scene }
  end

  def render_audio
    audio[:bg] ||= {
      input: "sounds/bg.ogg",
      gain: 0,
      looping: true
    }

    audio[:bg].gain += 0.01
    audio[:bg].gain = audio[:bg].gain.clamp(0, 1)

    if player.action == :jump && player.action_at == Kernel.tick_count
      jump_index = player.jumps_performed.clamp(0, 6)
      audio[:jump] = { input: "sounds/jump-#{jump_index}.ogg" }
    end
  end

  def render_level_editor
    return if !state.level_editor_enabled

    level_editor_mouse_prefab = case state.level_editor_tile_type
                                when :ground
                                  state.level_editor_mouse_rect.merge(path: "sprites/square/white.png", a: 128)
                                when :goal
                                  state.level_editor_mouse_rect.merge(path: "sprites/square/yellow.png", a: 128)
                                when :spikes
                                  state.level_editor_mouse_rect.merge(path: "sprites/square/red.png", a: 128)
                                end

    outputs[:scene].primitives << Camera.to_screen_space(state.camera, level_editor_mouse_prefab)

    outputs[:scene].sprites << state.preview.map do |t|
      player_prefab(t).merge(a: 128)
    end
  end

  def player_prefab target
    animation = target.animations[target.action]

    sprite_index = Numeric.frame_index(start_at: target.action_at,
                                       frame_count: animation.frame_count,
                                       hold_for: animation.hold_for.fdiv(state.sim_dt).to_i,
                                       repeat: animation.repeat)

    target_prefab = Camera.to_screen_space state.camera,
                                           target.merge(path: "sprites/player/#{target.action}/#{sprite_index + 1}.png",
                                                        flip_horizontally: target.facing_x < 0)

  end

  def render_player
    outputs[:scene].sprites << player_prefab(player)
  end

  def render_tiles
    outputs[:scene].sprites << state.tiles.map do |t|
      Camera.to_screen_space(state.camera, t.merge(path: 'sprites/square/white.png'))
    end

    remaining_goals = state.goals.reject do |g|
                       Geometry.find_intersect_rect g, state.player.collected_goals
                      end

    outputs[:scene].sprites << remaining_goals.map do |t|
      Camera.to_screen_space(state.camera, t.merge(path: 'sprites/square/yellow.png'))
    end

    outputs[:scene].sprites << state.spikes.map do |t|
      Camera.to_screen_space state.camera, t.merge(path: 'sprites/square/red.png')
    end
  end

  def player
    state.player ||= new_player
  end

  def entity_jump target
    can_jump = target.on_ground || (target.started_falling_at && target.started_falling_at.elapsed_time < (5 / state.sim_dt))
    return if !can_jump

    jump_power_lookup = {
      6 => 27,
      5 => 24,
      4 => 21,
      3 => 17,
      2 => 13,
      1 => 4,
      0 => 4
    }

    target.jump_power = jump_power_lookup[target.jumps_left] || 0
    target.jumps_performed += 1
    target.jumps_performed = target.jumps_performed.clamp(0, 6)
    target.jumps_left -= 1
    target.jumps_left = target.jumps_left.clamp(0, 6)

    target.dy = target.jump_power
    target.jump_at = Kernel.tick_count
    action! target, :jump
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
# GTK.reset
