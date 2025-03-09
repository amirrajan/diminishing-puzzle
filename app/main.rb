class Game
  attr_gtk

  def current_level_name
    # used by level editor to figure out which data file to save/load
    state.levels[state.current_level_index] || :todo
  end

  # helper method to move rect within the camera
  def to_screen_space target
    Camera.to_screen_space camera, target
  end

  def burn_id!
    # id generator, id is used to
    # offset lava animation start points
    state.id ||= 1
    r = state.id
    state.id += 1
    r
  end

  # entry point of game
  def tick
    defaults
    input
    calc
    render
  end

  # dictionary state for new_player
  def new_player
    {
      x: 320, y: 64, w: 50, h: 50,
      dx: 0, dy: 0,
      facing_x: 1,
      on_ground: false,
      max_speed: 10,
      jump_power: 29, jumps_left: 6, jumps_performed: 0,
      jump_at: 0,
      collected_goals: [],
      dashes_performed: 0, dashes_left: 5, is_dashing: false,
      dashing_at: 0, start_dash_x: 0, end_dash_x: 0,
      is_dead: false,
      started_falling_at: nil,
      on_ground_at: 0,
      action: :idle,
      action_at: 0,
      animations: {
        idle: { frame_count: 16, hold_for: 4, repeat: true },
        jump: { frame_count: 2, hold_for: 4, repeat: true },
        dash: { frame_count: 16, hold_for: 1, repeat: true },
        walk: { frame_count: 16, hold_for: 2, repeat: true },
        dance: { frame_count: 16, hold_for: 4, repeat: true },
        dead: { frame_count: 16, hold_for: 1, repeat: true },
        fall: { frame_count: 2, hold_for: 4, repeat: true },
      },
    }
  end

  def defaults
    state.gravity ||= -1
    state.deaths ||= 0
    state.time_taken ||= 0

    # max audio settings for music and sfx
    state.max_music_volume ||= 0.5
    state.max_sfx_volume ||= 0.9

    # list of levels that correlates to the data files
    state.levels ||= [
      :tutorial_jump,
      :jump_in_the_right_order,
      :burn_a_jump,
      :tutorial_dash,
      :burn_a_dash,
      :jump_and_dash,
      :burn_jumps_and_dashes,
      :leap_of_faith,
      :spam_dash,
      :hill_climb,
    ]

    state.current_level_index ||= 0

    # particle queue used to dash effects
    state.particles ||= []

    # simulation/physics DT (bullet time option)
    state.target_sim_dt ||= 1.0

    # future player moves are stored here
    state.level_editor_previews ||= []

    # spline that controls dash acceleration
    state.dash_spline ||= [
      [0, 0.66, 1.0, 1.0]
    ]

    # tile size for all level tiles
    state.tile_size ||= 64

    # initialization of camera
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

    # collection of player states used for undo functionality in the level editor
    state.previous_player_states ||= []

    # on start, init the player and level editor (if in dev mode)
    if Kernel.tick_count == 0
      state.player = new_player
      # level editor is enabled be default in dev mode
      state.level_editor_enabled = !GTK.production?
      # load level 0 on game start
      load_level 0
    end
  end

  def load_level number
    # current_level_index is used to determine level name
    state.current_level_index = number

    state.tiles =  load_rects "data/#{current_level_name}.txt"
    state.goals =  load_rects "data/#{current_level_name}-goals.txt"
    state.spikes = load_rects "data/#{current_level_name}-spikes.txt"

    # after loading level, store the lowest_tile_y which is used for fall death
    state.lowest_tile_y = (state.tiles.map { |t| t.ordinal_y }.min || 0) * state.tile_size
  end

  # parces csv file and generates rects based on the values parsed
  def load_rects file_path
    contents = GTK.read_file(file_path) || ""
    contents.each_line.map do |l|
      ordinal_x, ordinal_y = l.split(",").map(&:to_i)
      r = { ordinal_x: ordinal_x, ordinal_y: ordinal_y }

      r.merge(id: burn_id!,
              x: r.ordinal_x * state.tile_size,
              y: r.ordinal_y * state.tile_size,
              w: state.tile_size,
              h: state.tile_size)
    end
  end

  # saves rects to a file as a CSV
  def save_rects file_path, rects
    contents = rects.map do |t|
      "#{t[:ordinal_x]},#{t[:ordinal_y]}"
    end.join("\n")
    GTK.write_file file_path, contents
  end

  # top level player input
  def input
    # disable controls if the player is dead, if the game is complete, or if the level is complete
    return if player.is_dead
    return if state.game_completed
    return if state.level_completed

    # process inputs for player
    input_jump
    input_move
    input_dash
    input_kill_player
  end

  def kill_target! target
    return if target.is_dead
    target.is_dead = true
    target.dead_at ||= Kernel.tick_count
  end

  def input_kill_player
    if inputs.controller_one.key_down.start || inputs.keyboard.key_down.escape
      kill_target! player
    end
  end

  def jump_pressed?
    inputs.keyboard.key_down.space   ||
    inputs.controller_one.key_down.a ||
    inputs.keyboard.key_down.up      ||
    inputs.keyboard.key_down.w
  end

  def input_jump
    return if !jump_pressed?
    # store current jump value before jump is attempted
    # this is used to determine if audio should be played
    jumps_performed_before_decrement = player.jumps_performed

    # store the current player state before attempting jump
    # this controls the undo behavior in the level editor
    state.previous_player_states << player.copy

    # apply jump changes to target. level editor uses this same function to simulate
    # future jumps of the player
    entity_jump player

    # if the jump actually occured, then play a sound
    if player.jump_at == Kernel.tick_count && player.jumps_performed != jumps_performed_before_decrement
      jump_index = player.jumps_performed.clamp(0, 6)
      audio[:jump] = { input: "sounds/jump-#{jump_index}.ogg", gain: state.max_sfx_volume }
    end
  end

  def input_move
    # state.wasd_used is used to determine which instruction should be shown
    # if they use wasd, then input instructions for dash show "j" and "l"
    # if they use arrow keys, then input instructions for dash show "q" and "e"
    if inputs.keyboard.key_down.w || inputs.keyboard.key_down.a || inputs.keyboard.key_down.s || inputs.keyboard.key_down.d
      state.wasd_used = true
    elsif inputs.keyboard.key_down.up_arrow || inputs.keyboard.key_down.left_arrow || inputs.keyboard.key_down.down_arrow || inputs.keyboard.key_down.right_arrow
      state.wasd_used = false
    end

    # if left/right is held via wasd, arrow keys, or controller, then set the player to walking state
    # and update the direction the player is facing
    if inputs.left
      if player.on_ground
        action! player, :walk
      end
      player.dx -= player.max_speed * 0.25
      player.facing_x = -1
    elsif inputs.right
      if player.on_ground
        action! player, :walk
      end
      player.dx += player.max_speed * 0.25
      player.facing_x =  1
    else
      # if neither is held, set the player state to idle and set dx to zero
      if player.on_ground
        action! player, :idle
      end
      player.dx = 0
    end

    # clamp the player's dx to the max speed
    player.dx = player.dx.clamp(-player.max_speed, player.max_speed)
  end

  # dash is unlocked on :tutorial_dash level (which is the 4th index)
  def dash_unlocked?
    state.current_level_index >= 3
  end

  # dash left is triggered via l1 on controller or j/q on keyboard
  def input_dash_left?
    inputs.controller_one.l1 || inputs.keyboard.j || inputs.keyboard.q
  end

  # dash right is triggered via r1 on controller or l/e on keyboard
  def input_dash_right?
    inputs.controller_one.r1 || inputs.keyboard.l || inputs.keyboard.e
  end

  # dash is triggered if dash left or dash right is pressed
  def input_dash?
    input_dash_left? || input_dash_right?
  end

  # dash state applied to the target entity given a target and direction
  def entity_dash target, direction
    if direction == :left
      target.facing_x = -1
    elsif direction == :right
      target.facing_x = 1
    end

    # when dash is performed, store the current player location
    # and compute the player's end dash location based on the number of dashes left
    # multiplied by the player's facing direction and tile size
    target.is_dashing = true
    target.dashing_at = Kernel.tick_count
    target.start_dash_x = target.x
    target.end_dash_x = target.x + state.tile_size * target.dashes_left * target.facing_x

    if target.dashes_left == 0
      target.is_dashing = false
      target.dashing_at = nil
    end

    target.dashes_left -= 1
    target.dashes_left = target.dashes_left.clamp(0, 6)
    target.dashes_performed += 1
    target.dashes_performed = target.dashes_performed.clamp(0, 6)
  end

  # dash input handler
  def input_dash
    # dash is allowed if it's unlocked,
    # the player is not currently dashing,
    # the player is not in the middle of a dash,
    # and the dash input is pressed
    return if !dash_unlocked?
    return if player.is_dashing
    return if player.dashing_at && player.dashing_at.elapsed_time < 15
    return if !input_dash?

    # capture the number of dashes performed before decrementing
    # used to play audio
    dashes_performed_before_decrement = player.dashes_performed

    # store the current player state before attempting dash
    state.previous_player_states << player.copy

    # perform dash based off of direction
    if input_dash_left?
      entity_dash player, :left
    elsif input_dash_right?
      entity_dash player, :right
    end

    # play audio if a dash was performed
    if dashes_performed_before_decrement != player.dashes_performed
      audio[:dash] = { input: "sounds/dash-#{player.dashes_performed}.ogg", gain: state.max_sfx_volume }
    end
  end

  def calc
    # increment the time taken if the game is not completed (shown at the "game completed" screen)
    state.time_taken += 1 if !state.game_completed

    # calculate the physics for the player
    calc_physics player

    # determine collection of goals
    calc_goals

    # check if player has touched a spike
    calc_spikes player

    # check for game over
    calc_game_over

    # level editor logic
    calc_level_edit

    # camera movement logic
    calc_camera

    # world view logic when player is idle
    calc_world_view

    # particles processing
    calc_particles

    # determine if level is complete
    calc_level_complete

    # calculation of whispy lighting effects (different variant of particles)
    calc_whisps

    # play audio if player is dead on the current tick
    if player.is_dead && player.dead_at == Kernel.tick_count
      audio[:dead] = { input: "sounds/dead.ogg", gain: state.max_sfx_volume}
    end
  end

  # calculation of lighting effects
  def calc_whisps
    # 20 lighting points are created and then moved in a parallax fashion
    state.whisps ||= 20.map do
      d = rand + 1
      w = {
        a: 255,
        x: 1500 * rand,
        y: 1500 * rand,
        w: 640, h: 640,
        dx: d,
        dy: d,
        path: "sprites/mask.png",
        r: 0, g: 255, b: 255
      }
      w.target_x = w.x
      w.target_y = w.y
      w
    end

    # hand wavey math for parallax lighting
    state.whisps.each do |w|
      w.target_x = w.target_x - (w.dx + player.dx)
      w.target_y = w.target_y - (w.dy + player.dy)
      perc = 0.1
      w.x = w.x * (1 - perc) + w.target_x * perc
      w.y = w.y * (1 - perc) + w.target_y * perc
      w.a += 10
      if w.x + w.w < 0
        w.target_x = 1500 * rand
        w.target_y = 1500 * rand
        w.x = w.target_x
        w.y = w.target_y
        w.a = 0
      end
      if w.y + w.h < 0
        w.target_x = 1500 * rand
        w.target_y = 1500 * rand
        w.x = w.target_x
        w.y = w.target_y
        w.a = 0
      end
    end
  end

  # helper method to save a temporary level construction as an official level
  def save_level_as name
    save_rects "data/#{name}.txt", state.tiles
    save_rects "data/#{name}-goals.txt", state.goals
    save_rects "data/#{name}-spikes.txt", state.spikes
  end

  # for all particles in the particle queue, fade them out by "delta alpha" (.da property)
  # if the particle is completely faded out, remove it from the queue
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

  # check if goal has been collected
  def calc_goals
    return if state.level_completed

    # get goal that intersects with player
    goal = Geometry.find_intersect_rect player, state.goals

    # if there is a goal and the player hasn't already collected it yet, then add it to the player's collection
    # and play a sound
    if goal && !player.collected_goals.include?(goal)
      player.collected_goals << goal
      audio[:goal] = { input: "sounds/goal.ogg", gain: state.max_sfx_volume}
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

    # mark the tick that the level was completed at for level transition animation
    if level_completed && !state.level_completed
      state.level_completed = true
      state.level_completed_at = Kernel.tick_count
      audio[:complete] = { input: "sounds/complete.ogg", gain: state.max_sfx_volume}
    end
  end

  def calc_spikes target
    return if state.level_completed
    return if target.is_dead

    # check if player intersects with a spike, if so, then kill_target giving it the player
    spike = Geometry.find_intersect_rect target, state.spikes
    if spike
      target.dx = 0
      target.is_dashing = false
      kill_target! target
    end
  end

  # camera logic for zooming out a bit more if the player is sitting idle for 5 seconds
  def calc_world_view
    state.world_view_debounce ||= 300

    if player.action == :idle && player.on_ground
      state.world_view_debounce -= 1
    else
      if state.world_view_debounce == 0
        state.camera.target_scale = 0.75
        state.camera.target_scale_changed_at = Kernel.tick_count
      end
      state.world_view_debounce = 180
    end

    state.world_view_debounce = state.world_view_debounce.clamp(0, 300)

    if state.world_view_debounce == 0 && state.camera.target_scale > 0.50
      state.camera.target_scale = 0.50
      state.camera.target_scale_changed_at = Kernel.tick_count
    end
  end

  # general camera calculation, target_* properties are used to lerp the camera
  def calc_camera
    return if !camera.target_scale_changed_at

    # smooth start easing function for camera scale changes,
    # and x, y position changes
    perc = Easing.smooth_start(start_at: camera.target_scale_changed_at,
                               duration: camera.scale_lerp_duration,
                               tick_count: Kernel.tick_count,
                               power: 3)

    # tracking speed of the camera is increased when the player is falling
    # very fast
    scale_tracking_speed = if player.dy.abs > 55
                             0.99
                           else
                             0.1
                           end

    # lerp for the camera scale based off of the target scale
    camera.scale = camera.scale.lerp(camera.target_scale, perc)

    # recompute the camera's target location based off of where the player is currently located
    camera.target_x = camera.target_x.lerp(player.x, 0.1)
    camera.target_y = camera.target_y.lerp(player.y, 0.1)

    player_tracking_speed = if player.dy.abs > 55
                              0.99
                            else
                              0.9
                            end

    # lerp for the camera x and y based off of the target x and y
    camera.x += (camera.target_x - camera.x) * player_tracking_speed
    camera.y += (camera.target_y - camera.y) * player_tracking_speed

    # zoom out camera if they are past the lowest platform (preparing to death)
    if player.y + state.tile_size < state.lowest_tile_y && camera.target_scale > 0.25 && !player.is_dead
      camera.target_scale = 0.25
      camera.target_scale_changed_at = Kernel.tick_count
    end
  end

  # each entity within state.level_editor_previews is simulated
  # this is useful for creating new levels with the level editor
  def calc_level_editor_previews
    return if !state.level_editor_enabled

    # every second, do a simulation of the player's future moves
    if Kernel.tick_count.zmod? 60
      # jump straight up preview
      entity = player.merge(dx: 0, created_at: Kernel.tick_count)
      entity_jump entity
      state.level_editor_previews << entity

      # jump left and right preview
      entity = player.merge(dx: player.max_speed, created_at: Kernel.tick_count)
      entity_jump entity
      state.level_editor_previews << entity

      entity = player.merge(dx: -player.max_speed, created_at: Kernel.tick_count)
      entity_jump entity
      state.level_editor_previews << entity

      # dash left and right preview
      entity = player.merge(dx: 0, created_at: Kernel.tick_count)
      entity_dash entity, :left
      state.level_editor_previews << entity

      entity = player.merge(dx: 0, created_at: Kernel.tick_count)
      entity_dash entity, :right
      state.level_editor_previews << entity
    end

    # physics calculation of each preview item
    state.level_editor_previews.each do |entity|
      calc_physics entity
      calc_spikes entity
    end

    # remove previews that are older than 1 second
    state.level_editor_previews.reject! do |entity|
      entity.created_at.elapsed_time > 60
    end
  end

  # physics calculation, hold on to your butts
  def calc_physics target
    # if the player is dashing, then ignore all gravity and dx changes
    # and apply player's location based on the dash spline
    if target.is_dashing
      current_progress = Easing.spline target.dashing_at,
                                       Kernel.tick_count,
                                       15,
                                       state.dash_spline
      target.x = target.start_dash_x
      diff = target.end_dash_x - target.x
      target.x += diff * current_progress

      # dashing ends after 15 frames
      if target.dashing_at.elapsed_time >= 15
        target.is_dashing = false
      end

      # every other frame during the dash movement, add a particle effect
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
      # if dashing isn't happening then update the player's x location based off of dx
      target.x  += target.dx
    end

    # check for AABB collision in the x direction
    collision = Geometry.find_intersect_rect target, state.tiles

    # apply AABB collision if the player isn't dead
    if collision && !target.is_dead
      # if the player hits a wall, then kill their dx and dash
      # move the player to the edge of the wall
      target.dx = 0
      target.is_dashing = false
      if target.facing_x > 0
        target.x = collision.rect.x - target.w
      elsif target.facing_x < 0
        target.x = collision.rect.x + collision.rect.w
      end
    end

    # set the player's y location based off of dy
    target.y += target.dy

    # check for AABB collision in the y direction
    collision = Geometry.find_intersect_rect target, state.tiles
    if collision && !target.is_dead
      # if the player hits a ceiling or floor, then kill their dy
      # move the player to the edge of the ceiling or floor
      if target.dy > 0
        target.y = collision.rect.y - target.h
      elsif target.dy < 0
        # a dy less than 0 means that the player hit a floor
        target.y = collision.rect.y + collision.rect.h

        # reset their jump and set on_ground = true
        target.jump_at = nil
        target.on_ground = true
        if target.is_dashing
          # no op during dash
        else
          # set the frame that the player hit the ground
          # set started_falling_at to nil (this frame value is used to determine coyote time)
          target.on_ground_at = Kernel.tick_count
          target.started_falling_at = nil
        end
      end

      # set the player's dy to 0 if they hit a wall or ceiling
      target.dy = 0
    else
      # if there was no collision in the y direction, then the player is falling
      target.on_ground = false
      target.on_ground_at = nil
      target.started_falling_at ||= Kernel.tick_count

      # transition to the falling animation if they aren't dancing
      if target.dy < 0 && target.action != :dance
        action! target, :fall
      end
    end

    # ignore gravity if the player is dashing
    if target.is_dashing
      target.dy = 0
    else
      target.dy = target.dy + state.gravity
    end

    # if the player is way way way off the screen, then kill them
    if target.y < -3000
      kill_target! target
    end

    # if the player is dead, then double the fall rate so that level restart
    # happens faster
    if target.is_dead
      target.dy = target.dy + state.gravity
    end

    # if they aren't dead, but are way pased the lowest tile on the screen,
    # then make them fall faster so that the level can be restarted more quickly
    if state.lowest_tile_y && target.y < state.lowest_tile_y - 128 && !target.is_dead
      target.dy = target.dy + state.gravity * 4
    else
      # set the max dy to the size of a tile so that we never clip through
      target.dy = target.dy.clamp(-state.tile_size, state.tile_size)
    end
  end

  # if the player is dead then perform the zooming and player
  # animations before level restart
  def calc_game_over
    return if state.level_completed
    return if !player.is_dead

    if player.dead_at == Kernel.tick_count
      state.deaths += 1
    end

    # pause at player's death location
    if player.dead_at.elapsed_time < 15
      player.dx = 0
      player.dy = 0
    end

    # launch them up and zoom out camera
    if player.dead_at.elapsed_time == 15
      player.dy = 60
      camera.target_scale = 0.25
      camera.target_scale_changed_at = Kernel.tick_count
    end

    # zoom in camera after a second
    if player.dead_at.elapsed_time == 60
      camera.target_scale = 0.75
      camera.target_scale_changed_at = Kernel.tick_count
    end

    # reset player after 90 frames
    if player.dead_at.elapsed_time > 90
      state.player = new_player
    end
  end

  # set the animation state for the target entity and capture
  # when it occured (only if they aren't already in that state)
  def action! target, action
    return if target.action == action
    target.action = action
    target.action_at = Kernel.tick_count
  end

  # renders the game
  def render
    # background is back
    outputs.background_color = [0, 0, 0]

    # render the scen within the camera
    render_scene

    # render where the lights should be
    render_lights

    # created the lighted scene using the camera viewport and lights
    # using blendmode 0 and blendmode 2 his how the textures are merged
    outputs[:lighted_scene].background_color = [0, 0, 0, 0]
    outputs[:lighted_scene].w = 1500
    outputs[:lighted_scene].h = 1500
    outputs[:lighted_scene].primitives << { x: 0, y: 0, w: 1500, h: 1500, path: :lights, blendmode_enum: 0 }
    outputs[:lighted_scene].primitives << { x: 0, y: 0, w: 1500, h: 1500, path: :scene, blendmode_enum: 2 }

    # debug info for lighting location (be sure to set background color to white so you can see the light locations)
    # outputs.primitives << { **Camera.viewport, path: :lights }
    outputs.primitives << { **Camera.viewport, path: :lighted_scene }

    # if the level is completed, render the swiping transition
    render_level_complete

    # render onscreen instructions when in idle
    render_instructions

    # render jump and dash meters
    render_meters

    # render final score screen
    render_game_completed
  end

  # final score screen is 4 labels with time, deaths, and a message to restart
  def render_game_completed
    return if !state.game_completed

    outputs.primitives << {
      x: 640, y: 360,
      text: "You Won!",
      r: 255, g: 255, b: 255,
      anchor_x: 0.5,
      anchor_y: -1.0,
      size_px: 30
    }

    outputs.primitives << {
      x: 640, y: 360,
      text: "Deaths: #{state.deaths}",
      r: 255, g: 255, b: 255,
      anchor_x: 0.5,
      anchor_y: 0.0,
      size_px: 30
    }

    outputs.primitives << {
      x: 640, y: 360,
      text: "Time: #{state.time_taken.fdiv(60).to_sf} seconds",
      r: 255, g: 255, b: 255,
      anchor_x: 0.5,
      anchor_y: 1.0,
      size_px: 30
    }

    if inputs.last_active == :controller
      outputs.primitives << {
        x: 640, y: 360,
        text: "Press START to Go Again",
        anchor_x: 0.5,
        anchor_y: 3.0,
        r: 255, g: 255, b: 255,
        size_px: 30
      }
    else
      outputs.primitives << {
        x: 640, y: 360,
        text: "Press ENTER to Go Again",
        anchor_x: 0.5,
        anchor_y: 3.0,
        r: 255, g: 255, b: 255,
        size_px: 30
      }
    end

    # if the player presses start or enter, then reset the game
    if inputs.controller_one.key_down.start || inputs.keyboard.key_down.enter
      GTK.reset_next_tick
    end
  end

  # logic to render the jump and dash meters
  def render_meters
    return if state.game_completed

    # row offset for the UI component
    row_offset = 6

    # compute the number of jumps left and jumps performed
    jumps_left = player.jumps_left - 1
    jumps_performed = 5 - jumps_left

    # render the tiles using the Layout api so that it's aligned
    # to a grid/safe area
    outputs.primitives << jumps_performed.map do |i|
      Layout.rect(row: row_offset + i, col: 0, w: 1, h: 1)
            .merge(path: "sprites/meters/jump-empty.png")
    end

    outputs.primitives << jumps_left.map do |i|
      Layout.rect(row: row_offset + jumps_performed + i, col: 0, w: 1, h: 1)
            .merge(path: "sprites/meters/jump-full.png")
    end

    # compute the number of dashes left and dashes performed
    dashes_left = player.dashes_left
    dashes_performed = 5 - dashes_left

    # only show this meter if dash has been unlocked
    if dash_unlocked?
      outputs.primitives << dashes_left.map do |i|
        Layout.rect(row: row_offset + 5, col: i + 1, w: 1, h: 1)
              .merge(path: "sprites/meters/dash-full.png")
      end

      outputs.primitives << dashes_performed.map do |i|
        Layout.rect(row: row_offset + 5, col: 4 - i + 1, w: 1, h: 1)
              .merge(path: "sprites/meters/dash-empty.png")
      end
    end

    outputs.primitives << Layout.rect(row: row_offset + 5, col: 0, w: 1, h: 1)
                                .merge(path: "sprites/meters/gray-box.png")

  end

  # rendering for the camera viewport
  def render_scene
    outputs[:scene].background_color = [0, 0, 0, 0]
    outputs[:scene].w = 1500
    outputs[:scene].h = 1500
    render_parallax_background
    render_tiles
    render_particles
    render_player
    render_level_editor
    render_audio
  end

  # helper method for placing the lighting texture
  def light_prefab rect
    Camera.to_screen_space(camera,
                           rect.merge(x: rect.x + 32,
                                      y: rect.y + 32,
                                      w: 512,
                                      h: 512,
                                      anchor_x: 0.5,
                                      anchor_y: 0.5,
                                      path: "sprites/mask.png"))
  end

  def render_lights
    outputs[:lights].background_color = [0, 0, 0, 0]
    outputs[:lights].w = 1500
    outputs[:lights].h = 1500

    # bloom lighting at the current player location
    outputs[:lights].primitives << Camera.to_screen_space(camera,
                                                          x: player.x + 32,
                                                          y: player.y + 32,
                                                          w: 1000,
                                                          h: 1000,
                                                          anchor_x: 0.5,
                                                          anchor_y: 0.5,
                                                          path: "sprites/mask.png",
                                                          anchor_y: 0.5)

    # headlights lighting based off the the current player
    # location and which way they are facing
    if player.facing_x > 0
      outputs[:lights].primitives << Camera.to_screen_space(camera,
                                                            x: player.x + 32 + 28,
                                                            y: player.y,
                                                            w: 408 * 5,
                                                            h: 216 * 5,
                                                            path: "sprites/headlights.png", anchor_y: 0.5, r: 0, g: 0, b: 0)
    else
      outputs[:lights].primitives << Camera.to_screen_space(camera,
                                                            x: player.x + 32 - 28 - 408 * 5,
                                                            y: player.y,
                                                            w: 408 * 5,
                                                            h: 216 * 5,
                                                            flip_horizontally: true,
                                                            path: "sprites/headlights.png", anchor_y: 0.5, r: 0, g: 0, b: 0)
    end

    # add lighting around spikes
    outputs[:lights].primitives << state.spikes.map do |t|
      light_prefab(t)
    end

    # add lighting around goals
    outputs[:lights].primitives << state.goals.map do |t|
      light_prefab(t)
    end

    # add lights for "whispy" particles
    outputs[:lights].primitives << state.whisps.map do |w|
      w.merge(x: w.x, y: w.y, w: 640, h: 640, r: 0, g: 0, b: 0, path: "sprites/mask.png", a: 200)
    end
  end

  # render instructions after one second of idle
  def render_instructions
    state.instructions_alpha ||= 0
    state.instructions_fade_in_debounce ||= 60

    if player.action == :idle && player.on_ground
      state.instructions_fade_in_debounce -= 1
    else
      state.instructions_fade_in_debounce = 60
    end

    if state.instructions_fade_in_debounce <= 0
      state.instructions_alpha = state.instructions_alpha.lerp(255, 0.1)
    else
      state.instructions_alpha = state.instructions_alpha.lerp(0, 0.1)
    end

    instructions_rect = { x: player.x + 32,
                          y: player.y + 72,
                          w: 320,
                          h: 64,
                          anchor_x: 0.5,
                          a: state.instructions_alpha }

    if inputs.last_active == :controller
      if dash_unlocked?
          outputs[:scene].primitives << to_screen_space(instructions_rect.merge(path: "sprites/controller-dash.png"))
      else
          outputs[:scene].primitives << to_screen_space(instructions_rect.merge(path: "sprites/controller-no-dash.png"))
      end
    else
      if dash_unlocked?
        if state.wasd_used
          outputs[:scene].primitives << to_screen_space(instructions_rect.merge(path: "sprites/keyboard-wasd-dash.png"))
        else
          outputs[:scene].primitives << to_screen_space(instructions_rect.merge(path: "sprites/keyboard-arrow-dash.png"))
        end
      else
        if state.wasd_used
          outputs[:scene].primitives << to_screen_space(instructions_rect.merge(path: "sprites/keyboard-wasd-no-dash.png"))
        else
          outputs[:scene].primitives << to_screen_space(instructions_rect.merge(path: "sprites/keyboard-arrow-no-dash.png"))
        end
      end
    end
  end

  # animation calcuation for when the player completes a level
  def calc_level_complete
    return if !state.level_completed

    # set the player's dx to 0 if the level is complete
    player.dx *= 0.90

    # transition to player dancing
    action! player, :dance

    # if the player completed to the last level, then set the game to completed
    if state.current_level_index == state.levels.length
      state.game_completed = true
      state.game_completed_at ||= Kernel.tick_count
    elsif state.level_completed_at.elapsed_time == 60 * 2
      # after 120 frames, load the next level and reset the camera scale
      load_level state.current_level_index + 1
      state.player = new_player
      camera.scale = 0.25
      camera.target_scale = 0.75
      camera.target_scale_changed_at = Kernel.tick_count + 30
    elsif state.level_completed_at.elapsed_time > 90 * 2
      # after 180 frames, reset the level completed state
      state.level_completed = false
      state.level_completed_at = nil
    end
  end

  def render_level_complete
    return if !state.level_completed

    # if the level is completed, animate the screen swip transition
    if state.level_completed_at.elapsed_time < 60 * 2
      # swiping in occurs over 120 frames
      perc = Easing.smooth_start(start_at: state.level_completed_at,
                                 duration: 60 * 2,
                                 tick_count: Kernel.tick_count,
                                 power: 3)

      outputs.primitives << {
        x: (-Grid.allscreen_w + Grid.allscreen_w * perc) + Grid.allscreen_x,
        y: Grid.allscreen_y,
        w: Grid.allscreen_w,
        h: Grid.allscreen_h,
        a: 255 * state.level_completed_at.elapsed_time.fdiv(60 * 2),
        path: :solid,
        r: 0,
        g: 0,
        b: 0
      }
    else
      # if the game is completed, then don't swipe out
      if state.game_completed
        outputs.primitives << {
          x: Grid.allscreen_x,
          y: Grid.allscreen_y,
          w: Grid.allscreen_w,
          h: Grid.allscreen_h,
          a: 255,
          path: :solid,
          r: 0,
          g: 0,
          b: 0
        }
      else
        # swiping out occurs over 60 frames after the swiping in is complete
        perc = Easing.smooth_start(start_at: state.level_completed_at + 60 * 2,
                                   duration: 30 * 2,
                                   tick_count: Kernel.tick_count,
                                   power: 3)

        outputs.primitives << {
          x: (Grid.allscreen_w * perc) + Grid.allscreen_x,
          y: Grid.allscreen_y,
          w: Grid.allscreen_w,
          h: Grid.allscreen_h,
          a: 255 * state.level_completed_at.elapsed_time.fdiv(30 * 2),
          path: :solid,
          r: 0,
          g: 0,
          b: 0
        }
      end
    end
  end

  # particle rendering within the camera
  def render_particles
    outputs[:scene].primitives << state.particles.map do |particle|
      Camera.to_screen_space camera, particle
    end
  end

  # ffmpeg -i ./mygame/sounds/bg.wav -ac 2 -b:a 160k -ar 44100 -acodec libvorbis ./mygame/sounds/bg.ogg
  def render_audio
    # "render" of audio. fade in back ground music, and play footstep sounds
    audio[:bg] ||= {
      input: "sounds/bg.ogg",
      gain: 0,
      looping: true
    }

    audio[:bg].gain += 0.01
    audio[:bg].gain = audio[:bg].gain.clamp(0, state.max_music_volume)

    if player.action == :walk
      if player.action_at.elapsed_time.zmod? 8
        index = player.action_at.elapsed_time.idiv(8) % 6
        audio[:foot] = { input: "sounds/foot-#{index}.ogg", gain: state.max_sfx_volume }
      end
    end
  end

  # level editor rendering
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

    outputs[:scene].primitives << Camera.to_screen_space(camera, level_editor_mouse_prefab)

    outputs[:scene].primitives << state.level_editor_previews.map do |t|
      player_prefab(t).merge(a: 128)
    end
  end

  def player_prefab target
    # controls what sprite is returned for the player based on what animation state the player is in
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

    # animation information is located within the animations hash
    sprite_index = Numeric.frame_index(start_at: animation_at,
                                       frame_count: animation.frame_count,
                                       hold_for: animation.hold_for,
                                       repeat: animation.repeat)

    #  player sprite is 128x128 and centered, hence the -32
    render_rect = target.merge(w: 128, h: 128)
    render_rect.x -= 32
    render_rect.y -= 32
    if target.is_dead && target.dead_at.elapsed_time > 15
      render_rect.angle = 180 * (target.dead_at.elapsed_time - 15).fdiv(15).clamp(0, 1)
    end

    # return the render rect for the player based on the current animation, and frame index
    to_screen_space render_rect.merge(path: "sprites/player/#{action_dir}/#{sprite_index + 1}.png",
                                      flip_horizontally: target.facing_x < 0)
  end

  def render_player
    outputs[:scene].primitives << player_prefab(player)
  end

  def render_tiles
    # render ground/walls within the scene
    tiles = Camera.find_all_intersect_viewport camera, state.tiles
    outputs[:scene].primitives << tiles.map do |t|
      to_screen_space(t.merge(w: 128,
                              h: 128,
                              anchor_y: 0.25,
                              anchor_x: 0.25,
                              path: 'sprites/platform-tile.png'))
    end

    # get all goals that the player hasn't collected and render them
    goals = Camera.find_all_intersect_viewport camera, state.goals
    remaining_goals = goals.reject do |g|
                        Geometry.find_intersect_rect g, player.collected_goals
                      end

    outputs[:scene].primitives << remaining_goals.map do |t|
      # animation of the goals are based off of the id (this is so their animations aren't synchronized)
      start_at    = t.id % 5 * -13
      frame_count = 16
      hold_for    = 4
      frame_index = Numeric.frame_index(start_at: start_at,
                                        frame_count: frame_count,
                                        hold_for: hold_for,
                                        repeat: true)

      to_screen_space(t.merge(w: 128,
                              h: 128,
                              anchor_y: 0.25,
                              anchor_x: 0.25,
                              path: "sprites/goal-tile/#{frame_index + 1}.png"))
    end

    spikes = Camera.find_all_intersect_viewport camera, state.spikes
    outputs[:scene].primitives << spikes.map_with_index do |t, i|
      # animation of the spikes are based off of the id (this is so their animations aren't synchronized)
      start_at    = t.id % 5 * -13
      frame_count = 16
      hold_for    = 8
      frame_index = Numeric.frame_index(start_at: start_at,
                                        frame_count: frame_count,
                                        hold_for: hold_for,
                                        repeat: true)

      to_screen_space(t.merge(w: 128,
                              h: 128,
                              anchor_y: 0.25,
                              anchor_x: 0.25,
                              path: "sprites/lava-tile/#{frame_index + 1}.png"))
    end
  end

  def player
    state.player ||= new_player
  end

  def camera
    state.camera
  end

  # apply jump state changes to target
  def entity_jump target
    # coyote time allows the player to still jump after they have leaved the ground
    # 5 frame grace period
    has_coyote_time = target.started_falling_at && target.started_falling_at.elapsed_time < 5
    can_jump = target.on_ground || (player.action == :fall && has_coyote_time)

    return if !can_jump

    # power of dy based off of the number of jumps left
    jump_power_lookup = {
      6 => 27,
      5 => 24,
      4 => 21,
      3 => 17,
      2 => 13,
      1 => 0,
      0 => 0
    }

    # update jumps left and jumps performed
    # also capture the time the jump occurred so that the correct jump animation frame is rendered
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

  # parallax background/skybox rendering
  def render_parallax_background
    # hand wavey parallax math
    bg_x_parallax = -camera.target_x / 10
    bg_y_parallax = -camera.target_y / 10
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

  # HUD method to enable/disable level editor
  def disable_level_editor!
    state.level_editor_enabled = false
  end

  def enable_level_editor!
    state.level_editor_enabled = true
  end

  # level editor mouse overlay
  def mouse_tile_rect
    ordinal_x = inputs.mouse.x.idiv(state.tile_size)
    ordinal_y = inputs.mouse.y.idiv(state.tile_size)
    { x: ordinal_x * state.tile_size,
      y: ordinal_y * state.tile_size,
      w: state.tile_size,
      h: state.tile_size,
      ordinal_x: ordinal_x,
      ordinal_y: ordinal_y }
  end

  def calc_level_edit
    return if !state.level_editor_enabled

    # calc future player positions by applying
    # physics to each target within state.level_editor_previews
    calc_level_editor_previews

    # ctrl_s forces a save of the current level
    if inputs.keyboard.ctrl_s
      save_rects "data/#{current_level_name}.txt", state.tiles
      save_rects "data/#{current_level_name}-goals.txt", state.goals
      save_rects "data/#{current_level_name}-spikes.txt", state.spikes
      GTK.notify "Saved #{current_level_name}"
    end

    # ctrl_n takes you to the next level, ctrl_p takes you to the previous level
    if inputs.keyboard.ctrl_n
      load_level state.current_level_index + 1
      state.player = new_player
      state.level_completed = false
      camera.scale = 0.75
      camera.target_scale = 0.75
    elsif inputs.keyboard.ctrl_p
      load_level state.current_level_index - 1
      state.player = new_player
      state.level_completed = false
      camera.scale = 0.75
      camera.target_scale = 0.75
    end

    # tab used to change the tile type
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

    # get the current tile location within the world given the mouse position
    world_mouse = Camera.to_world_space camera, inputs.mouse
    ifloor_x = world_mouse.x.ifloor(state.tile_size)
    ifloor_y = world_mouse.y.ifloor(state.tile_size)

    state.level_editor_mouse_rect =  { x: ifloor_x,
                                       y: ifloor_y,
                                       w: state.tile_size,
                                       h: state.tile_size }

    target_rects = case state.level_editor_tile_type
                   when :ground
                     state.tiles
                   when :goal
                     state.goals
                   when :spikes
                     state.spikes
                   end

    # if the mouse is clicked, then add or delete the tile from the target_rects
    # and save the level data
    if inputs.mouse.click
      rect = state.level_editor_mouse_rect
      collision = Geometry.find_intersect_rect rect, target_rects
      if collision
        target_rects.delete collision
      else
        target_rects << { ordinal_x: rect.x.idiv(state.tile_size), ordinal_y: rect.y.idiv(state.tile_size) }
      end

      save_rects "data/#{current_level_name}.txt", state.tiles
      save_rects "data/#{current_level_name}-goals.txt", state.goals
      save_rects "data/#{current_level_name}-spikes.txt", state.spikes
      load_level state.current_level_index
    end

    # if select or u is pressed, then undo the last player jump/dash state
    if inputs.controller_one.key_down.select || inputs.keyboard.key_down.u
      state.player = state.previous_player_states.pop_back if state.previous_player_states.length > 0
    end

    # zoom controls for camera
    if inputs.keyboard.key_down.equal_sign || inputs.keyboard.key_down.plus
      camera.target_scale /= 0.75
      if camera.target_scale_changed_at && camera.target_scale_changed_at.elapsed_time >= camera.scale_lerp_duration
        camera.target_scale_changed_at = Kernel.tick_count
      end
    elsif inputs.keyboard.key_down.minus
      camera.target_scale *= 0.75
      if camera.target_scale_changed_at && camera.target_scale_changed_at.elapsed_time >= camera.scale_lerp_duration
        camera.target_scale_changed_at = Kernel.tick_count
      end
      if camera.target_scale < 0.10
        camera.target_scale = 0.10
      end
    elsif inputs.keyboard.zero
      camera.target_scale = 0.75
      camera.target_scale_changed_at = Kernel.tick_count
    end
  end
end

# camera view port calculations
class Camera
  SCREEN_WIDTH = 1280
  SCREEN_HEIGHT = 720
  WORLD_SIZE = 1500
  WORLD_SIZE_HALF = WORLD_SIZE / 2
  OFFSET_X = (SCREEN_WIDTH - WORLD_SIZE) / 2
  OFFSET_Y = (SCREEN_HEIGHT - WORLD_SIZE) / 2

  class << self
    def to_world_space camera, rect
      x = (rect.x - WORLD_SIZE_HALF + camera.x * camera.scale - OFFSET_X) / camera.scale
      y = (rect.y - WORLD_SIZE_HALF + camera.y * camera.scale - OFFSET_Y) / camera.scale
      w = rect.w / camera.scale
      h = rect.h / camera.scale
      rect.merge x: x, y: y, w: w, h: h
    end

    def to_screen_space camera, rect
      return nil if !rect

      x = rect.x * camera.scale - camera.x * camera.scale + WORLD_SIZE_HALF
      y = rect.y * camera.scale - camera.y * camera.scale + WORLD_SIZE_HALF
      w = rect.w * camera.scale
      h = rect.h * camera.scale
      rect.merge x: x, y: y, w: w, h: h
    end

    def viewport
      {
        x: OFFSET_X,
        y: OFFSET_Y,
        w: 1500,
        h: 1500
      }
    end

    def viewport_world camera
      to_world_space camera, viewport
    end

    def find_all_intersect_viewport camera, os
      Geometry.find_all_intersect_rect viewport_world(camera), os
    end
  end
end

def boot args
  args.state = {}
end

def tick args
  if (!args.inputs.keyboard.has_focus && args.gtk.production && Kernel.tick_count != 0)
    args.outputs.background_color = [0, 0, 0]
    args.outputs.labels << { x: 640,
                             y: 360,
                             text: "Game Paused (click to resume).",
                             alignment_enum: 1,
                             r: 255, g: 255, b: 255 }
  else
    $game ||= Game.new
    $game.args = args
    $game.tick
  end
end

def reset args
  $game = nil
end

# GTK.reset_and_replay "replay.txt", speed: 3
# GTK.reset
