-- wiretap — export game vitals to script-output as JSON so external tools
-- (Home Assistant, Prometheus, MQTT bridges, microcontrollers) can monitor
-- the factory.
--
-- Factorio 2.0 API facts this file relies on:
--  * helpers.write_file targets the script-output folder; for_player = 0
--    restricts the write to the server's output "if present" — in single
--    player there is no server and the write is silently skipped, so 0 is
--    only passed when game.is_multiplayer().
--  * Electric network statistics mirror GUI column positions: category
--    "input" is CONSUMPTION, "output" is PRODUCTION, "storage" is
--    accumulator charge. Flow values are normalized per tick, so
--    watts = flow * 60.
--  * Item/fluid production statistics are the other way around: "input" is
--    production, "output" is consumption.
--  * LuaLogisticNetwork.get_contents() returns an array of
--    {name=..., quality=..., count=...}.
--  * electric_network_statistics is readable on electric poles ONLY, so
--    networks are enumerated by scanning poles and deduping on
--    electric_network_id. Surfaces with a global electric network (space
--    platforms) instead expose surface.global_electric_network_statistics
--    (2.0.48+), reported as network "global".
--  * Pending chunk iterators, scan cursors and results are stored in `storage`
--    so save/load and multiplayer joins resume the same deterministic work.

local MOD_VERSION = "1.3.8"
local surface_scan = require("scan")
local logistics = require("logistics")
local power = require("power")
local force_collection = require("forces")
local normalize = require("normalize")
local SETTING_PREFIX = "wiretap-"
local ROBOT_ORDER_SAMPLE_INTERVAL_TICKS = 60 * 60

local robot_order_kind_by_name = {
  pickup = "logistic",
  deliver = "logistic",
  pickup_items = "logistic",
  deliver_items = "logistic",
  construct = "construction",
  repair = "construction",
  deconstruct = "construction",
  upgrade = "construction",
  explode_cliff = "construction",
}
local robot_order_name_by_value = {}
for name, value in pairs(defines.robot_order_type) do
  robot_order_name_by_value[value] = name
end

local function cfg(name)
  return settings.global[SETTING_PREFIX .. name].value
end

-- helpers.table_to_json serializes {} ambiguously; omit empty tables instead.
local function nonempty(t)
  if next(t) == nil then return nil end
  return t
end

-- Counter dimensions stay bounded to names. Reuse their existing leaf tables
-- without allocating an array of keys for every damage/death callback.
local function counter_leaf(root, surface, entity, damage_type)
  local by_entity = root[surface]
  if not by_entity then by_entity = {}; root[surface] = by_entity end
  local by_damage = by_entity[entity]
  if not by_damage then by_damage = {}; by_entity[entity] = by_damage end
  local by_attacker = by_damage[damage_type]
  if not by_attacker then by_attacker = {}; by_damage[damage_type] = by_attacker end
  return by_attacker
end

local function valid_name(obj, fallback)
  if not obj then return fallback end
  local ok, name = pcall(function() return obj.name end)
  if ok and name then return name end
  return fallback
end

local function attacker_name(event)
  local name = valid_name(event.force)
  if name then return name end
  local cause = event.cause
  return valid_name(cause and cause.valid and cause.force, "environment")
end

local function ensure_defense_storage()
  storage.defense = storage.defense or {}
  storage.defense.damage_received = storage.defense.damage_received or {}
  storage.defense.damage_events = storage.defense.damage_events or {}
  storage.defense.enemy_kills = storage.defense.enemy_kills or {}
  storage.defense.player_losses = storage.defense.player_losses or {}
end

local train_state_names = {}
for name, state in pairs(defines.train_state) do
  train_state_names[state] = name
end

local function new_train_sample(surface, scan)
  return {
    trains = game.train_manager.get_trains{surface = surface, force = "player"}, index = 1,
    out = {total = 0, moving = 0, waiting = 0, blocked = 0, manual = 0,
        stop_count = scan.train_stop_count, by_state = {}},
  }
end

local function step_train_sample(sample)
  local out = sample.out
  for _ = 1, 128 do
    local train = sample.trains[sample.index]
    if not train then out.by_state = nonempty(out.by_state); return true end
    sample.index = sample.index + 1
    if train.valid then
      out.total = out.total + 1
      local state = train_state_names[train.state] or "other"
      out.by_state[state] = (out.by_state[state] or 0) + 1
      if math.abs(train.speed) > 0 then out.moving = out.moving + 1 end
      if train.manual_mode then out.manual = out.manual + 1 end
      if state == "wait_signal" or state == "wait_station" or state == "destination_full" then
        out.waiting = out.waiting + 1
      elseif state == "no_path" then
        out.blocked = out.blocked + 1
      end
    end
  end
  return false
end

local function collect_defenses(scan)
  local out = scan.defense
  out.entity_counts = nonempty(out.entity_counts)
  out.ammo_by_item = nonempty(out.ammo_by_item)
  return out
end

-- Copy cumulative counters before rounding/publishing. Published snapshots must
-- not alias live storage that damage/death events continue to mutate.
local function copy_counters(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, child in pairs(value) do out[key] = copy_counters(child) end
  return out
end

-- Robot queues are also sampled in bounded batches, never all in one tick.
local function new_robot_sample(surface)
  local sample = {tasks = {}, task_index = 1, by_force = {}}
  for _, force in pairs(game.forces) do
    local nets = force.logistic_networks[surface.name]
    if nets and #nets > 0 then
      local counts = {logistic = {}, construction = {}}
      for name, kind in pairs(robot_order_kind_by_name) do counts[kind][name] = 0 end
      sample.by_force[force.name] = counts
      for _, net in pairs(nets) do
        sample.tasks[#sample.tasks + 1] = {network = net, counts = counts}
      end
    end
  end
  return sample
end

local function step_robot_sample(sample)
  local visited, networks = 0, 0
  while visited < 256 and networks < 16 do
    local task = sample.tasks[sample.task_index]
    if not task then return true end
    if not task.network.valid then
      sample.task_index = sample.task_index + 1
      sample.robots, sample.robot_index, sample.kind = nil, nil, nil
      networks = networks + 1
    else
      if not sample.robots then
        sample.kind = sample.kind or "logistic"
        sample.robots = sample.kind == "logistic" and task.network.logistic_robots
            or task.network.construction_robots
        sample.robot_index = 1
      end
      local robot = sample.robots[sample.robot_index]
      if robot then
        sample.robot_index = sample.robot_index + 1
        visited = visited + 1
        if robot.valid then
          local ok, queue = pcall(function() return robot.robot_order_queue end)
          local order = ok and queue and queue[1]
          local name = order and robot_order_name_by_value[order.type]
          if name and robot_order_kind_by_name[name] == sample.kind then
            local counts = task.counts[sample.kind]
            counts[name] = counts[name] + 1
          end
        end
      else
        sample.robots, sample.robot_index = nil, nil
        if sample.kind == "logistic" then
          sample.kind = "construction"
        else
          sample.kind = nil
          sample.task_index = sample.task_index + 1
          networks = networks + 1
        end
      end
    end
  end
  return false
end

-- --------------------------------------------------------------------------
-- Snapshot assembly and export.
-- --------------------------------------------------------------------------

-- Collection state belongs in storage: peers joining midway and save/load must
-- resume exactly the same work. Never choose work by elapsed real time or skip
-- collection on a client; either would make multiplayer storage diverge.
local function begin_collection()
  if storage.collection then return end
  local surfaces = {}
  for _, surface in pairs(game.surfaces) do surfaces[#surfaces + 1] = surface.index end
  local last_sample = storage.robot_order_sample_tick
  storage.collection = {
    started_tick = game.tick, surface_indices = surfaces, surface_index = 1,
    surfaces = {}, phase = "surface",
    options = {
      power = cfg("power"), breakdown = cfg("power-breakdown"),
      accumulators = cfg("accumulators"), pollution = cfg("pollution"),
      trains = cfg("trains"), defense = cfg("defense"),
      logistics = cfg("logistics"), quality = cfg("quality-breakdown"),
      production = cfg("production"), science = cfg("science"),
    },
    sample_robots = cfg("logistics") and (not last_sample or game.tick < last_sample
        or game.tick - last_sample >= ROBOT_ORDER_SAMPLE_INTERVAL_TICKS),
    robot_order_counts = {},
  }
  storage.next_collection_tick = game.tick + (storage.interval_ticks or 600)
end

local function build_snapshot()
  if not storage.latest_snapshot then
    error("[wiretap] first snapshot is still being collected; retry shortly")
  end
  return storage.latest_snapshot
end

local function do_export()
  if not storage.latest_json then
    begin_collection()
    return false
  end
  local json = storage.latest_json
  -- for_player only controls output. All peers run the same deterministic
  -- collection, including in single player where for_player must be nil.
  local target = (cfg("server-only") and game.is_multiplayer()) and 0 or nil
  local mode = cfg("mode")
  if mode == "snapshot" or mode == "both" then
    helpers.write_file(cfg("filename"), json, false, target)
  end
  if mode == "journal" or mode == "both" then
    helpers.write_file(cfg("journal-filename"), json .. "\n", true, target)
  end
  return true
end

local function finish_collection(job)
  if job.sample_robots then
    storage.robot_order_counts = job.robot_order_counts
    storage.robot_order_sample_tick = game.tick
  end
  local players = {}
  for _, player in pairs(game.connected_players) do players[#players + 1] = player.name end
  local snapshot = {
    meta = {
      mod_version = MOD_VERSION, tick = game.tick, ticks_played = game.ticks_played,
      game_time_seconds = math.floor(game.tick / 60), player_count = #game.connected_players,
      players_online = nonempty(players), interval_seconds = cfg("interval-seconds"),
      collection_started_tick = job.started_tick,
      collection_duration_ticks = game.tick - job.started_tick,
      robot_order_sample_interval_seconds = ROBOT_ORDER_SAMPLE_INTERVAL_TICKS / 60,
      robot_order_sample_age_seconds = storage.robot_order_sample_tick
          and math.floor((game.tick - storage.robot_order_sample_tick) / 60) or nil,
    },
    surfaces = job.surfaces,
    forces = nonempty(job.forces.out),
  }
  job.snapshot = snapshot
  local decimals = cfg("decimals")
  if decimals and decimals >= 0 and decimals <= 12 then
    job.normalization = normalize.new(snapshot, decimals)
    job.phase = "normalize"
  else
    job.phase = "serialize"
  end
end

local function step_collection()
  local job = storage.collection
  if not job then
    if game.tick >= (storage.next_collection_tick or 0) then begin_collection() end
    return
  end
  local options = job.options
  -- Global phases are handled before surface-specific cursors are read.
  if job.phase == "forces" then
    job.forces = job.forces or force_collection.new(options, job.surface_indices, storage.technology_names)
    if force_collection.step(job.forces) then finish_collection(job) end
    return
  elseif job.phase == "normalize" then
    if normalize.step(job.normalization) then
      job.normalization = nil
      job.phase = "serialize"
    end
    return
  elseif job.phase == "serialize" then
    -- Sampling ends before publication. Keep metadata consistent with the final
    -- sample window, and separate native JSON conversion from file writes.
    job.snapshot.meta.tick = game.tick
    job.snapshot.meta.ticks_played = game.ticks_played
    job.snapshot.meta.game_time_seconds = math.floor(game.tick / 60)
    job.snapshot.meta.collection_duration_ticks = game.tick - job.started_tick
    job.snapshot.meta.robot_order_sample_age_seconds = storage.robot_order_sample_tick
        and math.floor((game.tick - storage.robot_order_sample_tick) / 60) or nil
    job.json = helpers.table_to_json(job.snapshot)
    job.phase = "publish"
    return
  elseif job.phase == "publish" then
    storage.latest_snapshot, storage.latest_json = job.snapshot, job.json
    storage.collection = nil
    do_export()
    return
  end
  if job.phase == "surface" then
    local index = job.surface_indices[job.surface_index]
    if not index then job.phase = "forces"; return end
    local surface = game.surfaces[index]
    if surface and surface.valid then
      job.scan = surface_scan.new(surface, options)
      job.current = {index = surface.index, is_platform = surface.platform ~= nil}
      job.phase = "scan"
    else
      job.surface_index = job.surface_index + 1
    end
    return
  end
  local scan = job.scan
  if not scan.surface.valid then
    job.surfaces[scan.name] = nil
    job.scan, job.current, job.robot_sample, job.logistics, job.power, job.train_sample = nil, nil, nil, nil, nil, nil
    job.surface_index = job.surface_index + 1
    job.phase = "surface"
    return
  end
  local surface, current = scan.surface, job.current
  if job.phase == "scan" then
    if surface_scan.step(scan) then job.phase = "power" end
  elseif job.phase == "power" then
    local names = {}
    if options.power then
      job.power = job.power or power.new(surface, options, scan)
      if not power.step(job.power) then return end
      current.power, names = job.power.out, job.power.names
    end
    surface_scan.count_power_entities(scan, names)
    job.phase = "counts"
  elseif job.phase == "counts" then
    if #scan.names == 0 or surface_scan.step(scan) then
      if current.power then current.power.count_by_entity = nonempty(scan.entity_counts) end
      job.phase = "robots"
    end
  elseif job.phase == "robots" then
    if job.sample_robots then
      job.robot_sample = job.robot_sample or new_robot_sample(surface)
      if not step_robot_sample(job.robot_sample) then return end
    end
    job.phase = "logistics"
  elseif job.phase == "logistics" then
    if options.logistics then
      local orders = job.sample_robots and job.robot_sample.by_force
          or (storage.robot_order_counts or {})[surface.name] or {}
      job.logistics = job.logistics or logistics.new(surface, options.quality, orders)
      if not logistics.step(job.logistics) then return end
      current.logistics = nonempty(job.logistics.out)
    end
    job.phase = "trains"
  elseif job.phase == "trains" then
    if options.trains then
      job.train_sample = job.train_sample or new_train_sample(surface, scan)
      if not step_train_sample(job.train_sample) then return end
      current.trains = job.train_sample.out
    end
    job.phase = "details"
  elseif job.phase == "details" then
    if options.pollution then
      current.pollution = scan.pollution
      local pstats = surface.pollution_statistics
      current.pollution_produced_total = nonempty(pstats.input_counts)
      current.pollution_absorbed_total = nonempty(pstats.output_counts)
      current.pollution_absorbing_nest_count = scan.absorbing_nests
    end
    if options.defense then
      current.defense = collect_defenses(scan)
      for _, key in ipairs({"damage_received", "damage_events", "enemy_kills", "player_losses"}) do
        local counters = (storage.defense or {})[key]
        current.defense[key] = counters and counters[surface.name]
            and nonempty(copy_counters(counters[surface.name])) or nil
      end
    end
    -- Read the current name: a surface may have been renamed while scanning.
    if job.sample_robots then job.robot_order_counts[surface.name] = job.robot_sample.by_force end
    job.surfaces[surface.name] = current
    job.scan, job.current, job.robot_sample, job.logistics, job.power, job.train_sample = nil, nil, nil, nil, nil, nil
    job.surface_index = job.surface_index + 1
    job.phase = "surface"
  end
end

local function on_tick()
  local ok, err = pcall(step_collection)
  if not ok then
    storage.collection = nil
    storage.next_collection_tick = game.tick + (storage.interval_ticks or 600)
    log("[wiretap] collection failed: " .. tostring(err))
  end
end

-- --------------------------------------------------------------------------
-- Defense telemetry: event counters are cumulative for the current save.
-- Only player-force structures are damage-tracked; deaths are split into
-- player losses and enemy kills.
-- --------------------------------------------------------------------------

script.on_event(defines.events.on_entity_damaged, function(event)
  if not storage.defense_enabled then return end
  local entity = event.entity
  if not (entity and entity.valid and entity.force and entity.force.name == "player") then return end
  local surface = entity.surface.name
  local entity_name = entity.name or "unknown"
  local damage_type = valid_name(event.damage_type, "unknown")
  local attacker_force = attacker_name(event)
  local received = counter_leaf(storage.defense.damage_received, surface, entity_name, damage_type)
  local events = counter_leaf(storage.defense.damage_events, surface, entity_name, damage_type)
  received[attacker_force] = (received[attacker_force] or 0) + (event.final_damage_amount or 0)
  -- Immune structures still receive hit events. Keep those counts (and zero
  -- damage series) rather than changing telemetry to suppress fire callbacks.
  events[attacker_force] = (events[attacker_force] or 0) + 1
end, {
  {filter = "turret"},
  {filter = "wall-connectable"},
  {filter = "type", type = "roboport"},
  {filter = "type", type = "electric-pole"},
  {filter = "type", type = "radar"},
  {filter = "type", type = "container"},
  {filter = "type", type = "logistic-container"},
  {filter = "type", type = "mining-drill"},
  {filter = "type", type = "generator"},
  {filter = "type", type = "boiler"},
  {filter = "type", type = "lab"},
  {filter = "type", type = "assembling-machine"},
  {filter = "type", type = "furnace"},
})

script.on_event(defines.events.on_entity_died, function(event)
  if not storage.defense_enabled then return end
  local entity = event.entity
  if not (entity and entity.valid and entity.force) then return end
  local force_name = entity.force.name
  local surface = entity.surface.name
  local entity_name = entity.name or "unknown"
  local damage_type = valid_name(event.damage_type, "unknown")
  local attacker_force = attacker_name(event)
  if force_name == "enemy" then
    local kills = counter_leaf(storage.defense.enemy_kills, surface, entity_name, damage_type)
    kills[attacker_force] = (kills[attacker_force] or 0) + 1
  elseif force_name == "player" then
    local losses = counter_leaf(storage.defense.player_losses, surface, entity_name, damage_type)
    losses[attacker_force] = (losses[attacker_force] or 0) + 1
  end
end, {{filter = "force", force = "player"}, {filter = "force", force = "enemy"}})

-- --------------------------------------------------------------------------
-- Timer wiring. The on_tick handler is unconditional on every peer; only
-- serializable work is kept between ticks, so on_load needs no mutations.
-- --------------------------------------------------------------------------

local function refresh_interval()
  storage.interval_ticks = math.max(1, cfg("interval-seconds")) * 60
  storage.defense_enabled = cfg("defense")
  storage.collection = nil
  storage.next_collection_tick = game.tick + 1
end

script.on_event(defines.events.on_tick, on_tick)

script.on_init(function()
  storage.technology_names = force_collection.technology_names()
  ensure_defense_storage()
  refresh_interval()
end)

script.on_configuration_changed(function()
  storage.technology_names = force_collection.technology_names()
  ensure_defense_storage()
  -- Published snapshots from an earlier schema/settings must not be reused.
  storage.latest_snapshot, storage.latest_json = nil, nil
  storage.robot_order_sample_tick = nil
  refresh_interval()
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting and event.setting:sub(1, #SETTING_PREFIX) == SETTING_PREFIX then
    storage.latest_snapshot, storage.latest_json = nil, nil
    refresh_interval()
  end
end)

-- --------------------------------------------------------------------------
-- Live access: remote interface (for other mods / RCON) and a command.
--   RCON:  /wiretap        -> prints the JSON snapshot to the caller
--          /wiretap write  -> writes the latest completed snapshot
-- --------------------------------------------------------------------------

remote.add_interface("wiretap", {
  stats = build_snapshot,
  stats_json = function()
    build_snapshot()
    return storage.latest_json
  end,
  write_now = do_export,
  version = function() return MOD_VERSION end,
})

commands.add_command(
  "wiretap",
  "Print the latest completed stats; '/wiretap write' exports that snapshot.",
  function(cmd)
    local function reply(text)
      if cmd.player_index then
        local player = game.players[cmd.player_index]
        if player then player.print(text) end
      else
        -- player_index is nil for both RCON and the server's stdin console,
        -- and rcon.print only reaches an RCON caller. Echo short messages to
        -- stdout too so console invocations aren't silent; the full JSON dump
        -- stays RCON-only to avoid spamming the server log on every poll.
        rcon.print(text)
        if #text <= 512 then print(text) end
      end
    end
    local ok, err = pcall(function()
      if cmd.parameter == "write" then
        if not do_export() then
          reply("[wiretap] first snapshot is being collected; export will follow automatically")
          return
        end
        local mode = cfg("mode")
        local written = {}
        if mode == "snapshot" or mode == "both" then
          written[#written + 1] = "script-output/" .. cfg("filename")
        end
        if mode == "journal" or mode == "both" then
          written[#written + 1] = "script-output/" .. cfg("journal-filename")
        end
        reply("[wiretap] wrote " .. table.concat(written, " and "))
      else
        build_snapshot()
        reply(storage.latest_json)
      end
    end)
    if not ok then
      reply("[wiretap] error: " .. tostring(err))
    end
  end)
