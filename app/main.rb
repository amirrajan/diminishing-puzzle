require 'app/camera.rb'

class Game
  attr_gtk

  def current_level_name
    state.levels[state.current_level_index] || :todo
  end

  def tick
    defaults
    input
    calc
    render
    outputs.watch "#{GTK.current_framerate} FPS"
    outputs.watch "player: #{player.action}"
    outputs.watch "sim_dt: #{current_level_name}"
  end

  def new_player
    {
      x: 320,
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
      dashes_performed: 0,
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
        },
        dash: {
          frame_count: 16,
          hold_for: 1,
          repeat: true
        },
        walk: {
          frame_count: 16,
          hold_for: 2,
          repeat: true
        },
        dance: {
          frame_count: 16,
          hold_for: 1,
          repeat: true
        },
        dead: {
          frame_count: 16,
          hold_for: 1,
          repeat: true
        },
      },
    }
  end

  def disable_level_editor!
    state.level_editor_enabled = false
  end

  def defaults
    state.gravity              ||= -1
    state.levels ||= [
      :tutorial_jump,
      :jump_in_the_right_order,
      :burn_a_jump,
      :tutorial_dash,
      :burn_a_dash,
      :jump_and_dash,
      :burn_jumps_and_dashes,
      :leap_of_faith
    ]

    state.current_level_index ||= 0

    state.particles ||= []

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
    state.current_level_index = number
    state.tiles =  load_rects "data/#{current_level_name}.txt"
    state.goals =  load_rects "data/#{current_level_name}-goals.txt"
    state.spikes = load_rects "data/#{current_level_name}-spikes.txt"
    state.lowest_tile_y = (state.tiles.map { |t| t.ordinal_y }.min || 0) * state.tile_size
    state.level_loaded_at = Kernel.tick_count
    state.instructions_alpha = 0
    state.instructions_fade_in_debounce = 60
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
    return if player.is_dead

    if state.level_completed
      player.dx *= 0.90
      action! player, :dance
      player.dy = 7 if player.on_ground
    else
      input_jump
      input_move
      input_dash
      input_kill_player
    end
  end

  def kill_player!
    return if player.is_dead
    player.is_dead = true
    player.dead_at ||= Kernel.tick_count
  end

  def input_kill_player
    if inputs.controller_one.key_down.start || inputs.keyboard.key_down.escape
      kill_player!
    end
  end

  def jump_pressed?
    inputs.keyboard.key_down.space   ||
    inputs.controller_one.key_down.a ||
    inputs.keyboard.key_down.up      ||
    inputs.keyboard.key_down.w
  end

  def input_jump
    if jump_pressed?
      state.previous_player_state = player.copy
      entity_jump player
    end

    if player.jump_at == Kernel.tick_count
      jump_index = player.jumps_performed.clamp(0, 6)
      audio[:jump] = { input: "sounds/jump-#{jump_index}.ogg" }
    end
  end

  def input_move
    if inputs.left
      if player.on_ground
        action! player, :walk
      end
      player.dx -= player.max_speed * 0.25
      player.facing_x = -1
      player.left_at ||= Kernel.tick_count
      player.right_at  = nil
    elsif inputs.right
      if player.on_ground
        action! player, :walk
      end
      player.dx += player.max_speed * 0.25
      player.facing_x =  1
      player.right_at ||= Kernel.tick_count
      player.left_at    = nil
    else
      if player.on_ground
        action! player, :idle
      end
      player.dx = 0
      player.left_at = nil
      player.right_at = nil
    end
    player.dx = player.dx.clamp(-player.max_speed, player.max_speed)
  end

  def dash_unlocked?
    state.current_level_index >= 3
  end

  def input_dash_left?
    inputs.controller_one.key_down.l1 || inputs.keyboard.key_down.j || inputs.keyboard.key_down.q
  end

  def input_dash_right?
    inputs.controller_one.key_down.r1 || inputs.keyboard.key_down.l || inputs.keyboard.key_down.e
  end

  def input_dash?
    input_dash_left? || input_dash_right?
  end

  def input_dash
    return if !dash_unlocked?
    return if player.is_dashing
    return if !input_dash?

    if input_dash_left?
      player.facing_x = -1
    elsif input_dash_right?
      player.facing_x = 1
    end

    player.is_dashing = true
    player.dashing_at = Kernel.tick_count
    player.start_dash_x = player.x
    player.end_dash_x = player.x + state.tile_size * player.dashes_left * player.facing_x

    if player.dashes_left == 0
      player.is_dashing = false
      player.dashing_at = nil
    end

    player.dashes_left -= 1
    player.dashes_left = player.dashes_left.clamp(0, 6)
    player.dashes_performed += 1
    player.dashes_performed = player.dashes_performed.clamp(0, 6)
    dash_index = player.dashes_performed.clamp(0, 6)
    audio[:dash] = { input: "sounds/dash-#{dash_index}.ogg" }
  end

  def calc
    state.sim_dt = state.sim_dt.lerp(state.target_sim_dt, 0.1)
    calc_physics player
    calc_goals
    calc_spikes
    calc_game_over
    calc_level_edit
    calc_camera
    calc_particles
    calc_level_complete
    # state.target_sim_dt = 1.0 if player.on_ground
  end

  def save_level_as name
    save_rects "data/#{name}.txt", state.tiles
    save_rects "data/#{name}-goals.txt", state.goals
    save_rects "data/#{name}-spikes.txt", state.spikes
  end

  def calc_particles
    state.particles.each do |particle|
      particle.start_at ||= Kernel.tick_count
      particle.a ||= 255
      particle.da ||= -1
      next if particle.start_at > Kernel.tick_count
      particle.a += particle.da
    end

    state.particles.reject! do |particle|
      particle.a <= 0
    end
  end

  def calc_goals
    goal = Geometry.find_intersect_rect player, state.goals
    if goal && !state.player.collected_goals.include?(goal)
      state.player.collected_goals << goal
    end

    # level completion checked if:
    # - player is not dead
    # - player is on the ground
    # - player has collected all goals
    # - level is not already completed
    level_completed = !player.is_dead &&
                      player.on_ground &&
                      player.collected_goals.length == state.goals.length &&
                      !state.level_completed

    if level_completed
      state.level_completed = true
      state.level_completed_at = Kernel.tick_count
    end
  end

  def calc_spikes
    return if state.level_completed
    spike = Geometry.find_intersect_rect player, state.spikes
    if spike
      kill_player!
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
      save_rects "data/#{current_level_name}.txt", state.tiles
      save_rects "data/#{current_level_name}-goals.txt", state.goals
      save_rects "data/#{current_level_name}-spikes.txt", state.spikes
      GTK.notify "Saved #{current_level_name}"
    end

    if inputs.keyboard.ctrl_n
      load_level state.current_level_index + 1
      state.player = new_player
      state.level_completed = false
      state.camera.scale = 0.75
      state.camera.target_scale = 0.75
    elsif inputs.keyboard.ctrl_p
      load_level state.current_level_index - 1
      state.player = new_player
      state.level_completed = false
      state.camera.scale = 0.75
      state.camera.target_scale = 0.75
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

      save_rects "data/#{current_level_name}.txt", state.tiles
      save_rects "data/#{current_level_name}-goals.txt", state.goals
      save_rects "data/#{current_level_name}-spikes.txt", state.spikes
      load_level state.current_level_index
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

    perc = Easing.smooth_start(start_at: state.camera.target_scale_changed_at,
                               duration: state.camera.scale_lerp_duration,
                               tick_count: Kernel.tick_count,
                               power: 3)

    scale_tracking_speed = if player.dy.abs > 55
                             0.99
                           else
                             0.1
                           end

    state.camera.scale = state.camera.scale.lerp(state.camera.target_scale, perc)
    state.camera.target_x = state.camera.target_x.lerp(player.x, 0.1)
    state.camera.target_y = state.camera.target_y.lerp(player.y, 0.1)

    player_tracking_speed = if player.dy.abs > 55
                              0.99
                            else
                              0.9
                            end

    state.camera.x += (state.camera.target_x - state.camera.x) * player_tracking_speed
    state.camera.y += (state.camera.target_y - state.camera.y) * player_tracking_speed

    # zoom out camera if they are past the lowest platform (preparing to death)
    if player.y + 64 < state.lowest_tile_y && state.camera.target_scale > 0.25 && !player.is_dead
      state.camera.target_scale = 0.25
      state.camera.target_scale_changed_at = Kernel.tick_count
    end
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
      if Kernel.tick_count.zmod? 2
        state.particles << { x: target.x - 32,
                             y: target.y - 32,
                             w: 128,
                             h: 128,
                             a: 200,
                             da: -10,
                             path: "sprites/player/dash/1.png" }
      end
    else
      target.x  += target.dx * state.sim_dt
    end

    collision = Geometry.find_intersect_rect target, state.tiles
    if collision
      target.dx = 0
      target.is_dashing = false
      if target.facing_x > 0
        target.x = collision.rect.x - target.w
      elsif target.facing_x < 0
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
        if target.is_dashing
        else
          target.on_ground_at = Kernel.tick_count
          target.started_falling_at = nil
        end
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

    if player.y < -4000
      kill_player!
    end

    # drop_fast = target.dy < 0
    # if drop_fast
    #   target.dy = target.dy + state.gravity * state.sim_dt
    #   target.dy = target.dy + state.gravity * state.sim_dt
    # end
    target.dy = target.dy.clamp(-state.tile_size, state.tile_size)
  end

  def calc_game_over
    return if state.level_completed
    return if !player.is_dead

    # pause at player's death location
    if player.dead_at.elapsed_time < 15
      player.dx = 0
      player.dy = 0
    end

    # launch them up and zoom out camera
    if player.dead_at.elapsed_time == 15
      player.dy = 40
      state.camera.target_scale = 0.25
      state.camera.target_scale_changed_at = Kernel.tick_count
    end


    # zoom in camera
    if player.dead_at.elapsed_time == 60
      state.camera.target_scale = 0.75
      state.camera.target_scale_changed_at = Kernel.tick_count
    end

    # zoom camera back in
    if player.dead_at.elapsed_time == 90
      state.camera.target_scale = 0.75
      state.camera.target_scale_changed_at = Kernel.tick_count
    end

    # reset player
    if player.dead_at.elapsed_time > 90
      state.player = new_player
    end
  end

  def action! target, action
    return if target.action == action
    target.action = action
    target.action_at = Kernel.tick_count
  end

  def render
    outputs.background_color = [0, 0, 0]
    render_parallax_background
    render_tiles
    render_particles
    render_player
    render_level_editor
    render_audio
    outputs[:scene].w = 1500
    outputs[:scene].h = 1500
    outputs.primitives << { **Camera.viewport, path: :scene }
    render_level_complete
    render_instructions
  end

  def render_instructions
    state.instructions_alpha ||= 0
    state.instructions_fade_in_debounce ||= 60

    if player.action == :idle && player.on_ground
      state.instructions_fade_in_debounce -= 1
    else
      state.instructions_fade_in_debounce = 60
    end

    outputs.watch "#{state.instructions_fade_in_debounce}"

    if state.instructions_fade_in_debounce <= 0
      state.instructions_alpha = state.instructions_alpha.lerp(255, 0.1)
    else
      state.instructions_alpha = state.instructions_alpha.lerp(0, 0.1)
    end


    if inputs.last_active == :controller
      if dash_unlocked?
          outputs[:scene].primitives << Camera.to_screen_space(state.camera,
                                                               { x: player.x + 32,
                                                                 y: player.y + 72,
                                                                 w: 166,
                                                                 h: 64,
                                                                 anchor_x: 0.5,
                                                                 path: "sprites/instructions-controller-dash.png",
                                                                 a: state.instructions_alpha })
      else
          outputs[:scene].primitives << Camera.to_screen_space(state.camera,
                                                               { x: player.x + 32,
                                                                 y: player.y + 72,
                                                                 w: 166,
                                                                 h: 64,
                                                                 anchor_x: 0.5,
                                                                 path: "sprites/instructions-controller-no-dash.png",
                                                                 a: state.instructions_alpha })
      end
    else
      if dash_unlocked?
          outputs[:scene].primitives << Camera.to_screen_space(state.camera,
                                                               { x: player.x + 32,
                                                                 y: player.y + 72,
                                                                 w: 166,
                                                                 h: 64,
                                                                 anchor_x: 0.5,
                                                                 path: "sprites/instructions-keyboard-dash.png",
                                                                 a: state.instructions_alpha })
      else
          outputs[:scene].primitives << Camera.to_screen_space(state.camera,
                                                               { x: player.x + 32,
                                                                 y: player.y + 72,
                                                                 w: 166,
                                                                 h: 64,
                                                                 anchor_x: 0.5,
                                                                 path: "sprites/instructions-keyboard-no-dash.png",
                                                                 a: state.instructions_alpha })
      end
    end
  end

  def calc_level_complete
    return if !state.level_completed

    if state.level_completed_at.elapsed_time == 60
      load_level state.current_level_index + 1
      state.player = new_player
      state.camera.scale = 0.25
      state.camera.target_scale = 0.75
      state.camera.target_scale_changed_at = Kernel.tick_count + 30
    elsif state.level_completed_at.elapsed_time > 90
      state.level_completed = false
      state.level_completed_at = nil
    end
  end

  def render_level_complete
    return if !state.level_completed

    if state.level_completed_at.elapsed_time < 60
      perc = Easing.smooth_start(start_at: state.level_completed_at,
                                 duration: 60,
                                 tick_count: Kernel.tick_count,
                                 power: 3)

      outputs.primitives << {
        x: (-Grid.allscreen_w + Grid.allscreen_w * perc) + Grid.allscreen_x,
        y: Grid.allscreen_y,
        w: Grid.allscreen_w,
        h: Grid.allscreen_h,
        a: 255 * state.level_completed_at.elapsed_time.fdiv(60),
        path: :solid,
        r: 0,
        g: 0,
        b: 0
      }
    else
      perc = Easing.smooth_start(start_at: state.level_completed_at + 60,
                                 duration: 30,
                                 tick_count: Kernel.tick_count,
                                 power: 3)

      outputs.primitives << {
        x: (Grid.allscreen_w * perc) + Grid.allscreen_x,
        y: Grid.allscreen_y,
        w: Grid.allscreen_w,
        h: Grid.allscreen_h,
        a: 255 * state.level_completed_at.elapsed_time.fdiv(30),
        path: :solid,
        r: 0,
        g: 0,
        b: 0
      }
    end
  end

  def render_particles
    outputs[:scene].primitives << state.particles.map do |particle|
      Camera.to_screen_space state.camera, particle
    end
  end

  # ffmpeg -i ./mygame/sounds/jump-1.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/jump-1.ogg
  # ffmpeg -i ./mygame/sounds/jump-2.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/jump-2.ogg
  # ffmpeg -i ./mygame/sounds/jump-3.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/jump-3.ogg
  # ffmpeg -i ./mygame/sounds/jump-4.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/jump-4.ogg
  # ffmpeg -i ./mygame/sounds/jump-5.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/jump-5.ogg
  # ffmpeg -i ./mygame/sounds/jump-6.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/jump-6.ogg
  # ffmpeg -i ./mygame/sounds/dash-1.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/dash-1.ogg
  # ffmpeg -i ./mygame/sounds/dash-2.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/dash-2.ogg
  # ffmpeg -i ./mygame/sounds/dash-3.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/dash-3.ogg
  # ffmpeg -i ./mygame/sounds/dash-4.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/dash-4.ogg
  # ffmpeg -i ./mygame/sounds/dash-5.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/dash-5.ogg
  # ffmpeg -i ./mygame/sounds/dash-6.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/dash-6.ogg
  def render_audio
    audio[:bg] ||= {
      input: "sounds/bg.ogg",
      gain: 0,
      looping: true
    }

    audio[:bg].gain += 0.01
    audio[:bg].gain = audio[:bg].gain.clamp(0, 1)

    if player.action == :jump && player.action_at == Kernel.tick_count
    elsif player.action == :dash && player.action_at == Kernel.tick_count
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

    outputs[:scene].primitives << state.preview.map do |t|
      player_prefab(t).merge(a: 128)
    end
  end

  def player_prefab target
    if target.is_dead
      animation = target.animations[:dead]
      animation_at = target.dead_at
      action_dir = :dead
    else
      animation = target.animations[target.action]
      animation_at = target.action_at
      action_dir = target.action
    end

    raise "No animation found in target.animations: #{pretty_format target.animations} hash for #{target.action}" if !animation

    sprite_index = Numeric.frame_index(start_at: animation_at,
                                       frame_count: animation.frame_count,
                                       hold_for: animation.hold_for.fdiv(state.sim_dt).to_i,
                                       repeat: animation.repeat)

    #  player sprite is 128x128 and centered, hence the -32
    render_rect = target.merge(w: 128, h: 128)
    render_rect.x -= 32
    render_rect.y -= 32
    if target.is_dead && target.dead_at.elapsed_time > 15
      render_rect.angle = 180 * (target.dead_at.elapsed_time - 15).fdiv(15).clamp(0, 1)
    end
    target_prefab = Camera.to_screen_space state.camera,
                                           render_rect.merge(path: "sprites/player/#{action_dir}/#{sprite_index + 1}.png",
                                                             flip_horizontally: target.facing_x < 0)

  end

  def render_player
    outputs[:scene].primitives << player_prefab(player)
  end

  def render_tiles
    outputs[:scene].primitives << state.tiles.map do |t|
      Camera.to_screen_space(state.camera,
                             t.merge(w: 128,
                                     h: 128,
                                     anchor_y: 0.25,
                                     anchor_x: 0.25,
                                     path: 'sprites/platform-tile.png'))
    end

    remaining_goals = state.goals.reject do |g|
                       Geometry.find_intersect_rect g, state.player.collected_goals
                      end

    outputs[:scene].primitives << remaining_goals.map do |t|
      Camera.to_screen_space(state.camera, t.merge(path: 'sprites/square/yellow.png'))
    end

    outputs[:scene].primitives << state.spikes.map do |t|
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
    target.on_ground = false
    action! target, :jump

  end

  def render_parallax_background
    bg_x_parallax = -state.camera.target_x / 10
    bg_y_parallax = -state.camera.target_y / 10
    sz = 1500

    outputs[:scene].primitives << {
      x: 750 - sz + (bg_x_parallax + sz).clamp_wrap(0, sz * 2),
      y: 750 - sz + (bg_y_parallax + sz).clamp_wrap(0, sz * 2),
      w: 2862,
      h: 1627,
      path: "sprites/bg.png",
      anchor_y: 0.5,
      anchor_x: 0.5
    }
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
