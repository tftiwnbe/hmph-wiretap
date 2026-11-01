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
--  * on_load may only read `storage`, so the export interval is mirrored
--    into storage for timer re-registration on load.

local MOD_VERSION = "1.3.4"
local SETTING_PREFIX = "wiretap-"
local PRECISION = defines.flow_precision_index.five_seconds
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

-- Bounded aggregate helpers for combat telemetry. These maps contain entity,
-- damage-type, force, and surface names only (never positions or unit numbers).
local function nested_add(root, keys, amount)
  local node = root
  for i = 1, #keys - 1 do
    local key = keys[i]
    node[key] = node[key] or {}
    node = node[key]
  end
  local key = keys[#keys]
  node[key] = (node[key] or 0) + amount
end

local function valid_name(obj, fallback)
  if not obj then return fallback end
  local ok, name = pcall(function() return obj.name end)
  if ok and name then return name end
  return fallback
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

local function collect_trains(surface)
  local trains = game.train_manager.get_trains{surface = surface, force = "player"}
  local out = {
    total = #trains,
    moving = 0,
    waiting = 0,
    blocked = 0,
    manual = 0,
    stop_count = surface.count_entities_filtered{type = "train-stop", force = "player"},
    by_state = {},
  }
  for _, train in pairs(trains) do
    local state = train_state_names[train.state] or "other"
    out.by_state[state] = (out.by_state[state] or 0) + 1
    if math.abs(train.speed) > 0 then out.moving = out.moving + 1 end
    if train.manual_mode then out.manual = out.manual + 1 end
    if state == "wait_signal" or state == "wait_station" then
      out.waiting = out.waiting + 1
    elseif state == "no_path" or state == "destination_full" then
      out.blocked = out.blocked + 1
    end
  end
  out.by_state = nonempty(out.by_state)
  return out
end

local function collect_defenses(surface)
  local types = {"ammo-turret", "electric-turret", "fluid-turret", "artillery-turret", "wall", "gate"}
  local entities = surface.find_entities_filtered{type = types, force = "player"}
  local out = {entity_counts = {}, ammo_by_item = {}, loaded_turret_count = 0, empty_turret_count = 0}
  for _, entity in pairs(entities) do
    local kind = entity.type or "unknown"
    out.entity_counts[entity.name] = (out.entity_counts[entity.name] or 0) + 1
    if kind == "ammo-turret" then
      local inventory = entity.get_inventory(defines.inventory.turret_ammo)
      local loaded = inventory and not inventory.is_empty()
      if loaded then
        out.loaded_turret_count = out.loaded_turret_count + 1
        for _, item in pairs(inventory.get_contents()) do
          out.ammo_by_item[item.name] = (out.ammo_by_item[item.name] or 0) + item.count
        end
      else
        out.empty_turret_count = out.empty_turret_count + 1
      end
    end
  end
  out.entity_counts = nonempty(out.entity_counts)
  out.ammo_by_item = nonempty(out.ammo_by_item)
  return out
end

-- Full float64 precision is dashboard noise and inflates the payload
-- (table_to_json prints shortest-roundtrip, so rounded values serialize
-- short); round fractional numbers in place before serialization.
local function round_floats(t, mult)
  for k, v in pairs(t) do
    local tv = type(v)
    if tv == "table" then
      round_floats(v, mult)
    elseif tv == "number" and v % 1 ~= 0 then
      t[k] = math.floor(v * mult + 0.5) / mult
    end
  end
end

-- --------------------------------------------------------------------------
-- Power: one entry per electric network, plus per-surface totals.
-- --------------------------------------------------------------------------

local function collect_power(surface, include_breakdown, include_accumulators)
  -- Surfaces with a global electric network (space platforms) expose
  -- statistics on the surface itself (2.0.48+), not on any entity —
  -- electric_network_statistics is readable on electric poles only. The
  -- surface reads are pcall-guarded so older 2.0.x runtimes degrade to the
  -- charge-only accumulator entries. On global-network surfaces pole
  -- enumeration is skipped: any pole there joins the same global network
  -- and would double-count.
  local reps = {} -- network key (string) -> statistics object
  local network_refs = {} -- network key (string) -> electric sub-network
  local ok_g, has_global = pcall(function() return surface.has_global_electric_network end)
  local is_global = ok_g and has_global or false
  if is_global then
    local ok_s, gstats = pcall(function() return surface.global_electric_network_statistics end)
    if ok_s and gstats then reps["global"] = gstats end
    local ok_n, network = pcall(function() return surface.global_electric_network end)
    if ok_n and network then network_refs["global"] = network end
  else
    for _, pole in pairs(surface.find_entities_filtered{type = "electric-pole"}) do
      local id = pole.electric_network_id
      if id and not reps[tostring(id)] then
        local key = tostring(id)
        reps[key] = pole.electric_network_statistics
        local ok_n, network = pcall(function() return pole.electric_network end)
        if ok_n and network then network_refs[key] = network end
      end
    end
  end

  local accumulators
  if include_accumulators then
    accumulators = surface.find_entities_filtered{type = "accumulator"}
  end

  local totals = {
    production_watts = 0,
    consumption_watts = 0,
    accumulator_charge_joules = 0,
    accumulator_capacity_joules = 0,
    network_count = 0,
  }
  local capacity_network_count = 0
  local networks = {}
  local seen_names = include_breakdown and {} or nil

  for key, stats in pairs(reps) do
    local production, consumption = 0, 0
    local prod_by, cons_by = {}, {}
    for name in pairs(stats.output_counts) do
      local watts = stats.get_flow_count{
        name = name, category = "output", precision_index = PRECISION,
      } * 60
      production = production + watts
      if include_breakdown then prod_by[name] = watts; seen_names[name] = true end
    end
    for name in pairs(stats.input_counts) do
      local watts = stats.get_flow_count{
        name = name, category = "input", precision_index = PRECISION,
      } * 60
      consumption = consumption + watts
      if include_breakdown then cons_by[name] = watts; seen_names[name] = true end
    end

    local net = {
      production_watts = production,
      consumption_watts = consumption,
      accumulator_charge_joules = 0,
      accumulator_capacity_joules = 0,
    }
    local network = network_refs[key]
    if network then
      -- flow_last_tick is exposed by the parent electric network. Its
      -- maximum_production/maximum_consumption values are per-tick energy,
      -- like the flow statistics above, so convert to watts with * 60.
      local ok_capacity, maximum_production, maximum_consumption = pcall(function()
        local flow = network.parent_network.flow_last_tick
        return flow.maximum_production, flow.maximum_consumption
      end)
      if ok_capacity and type(maximum_production) == "number"
          and type(maximum_consumption) == "number" then
        maximum_production = maximum_production * 60
        maximum_consumption = maximum_consumption * 60
        net.maximum_production_watts = maximum_production
        net.maximum_consumption_watts = maximum_consumption
        totals.maximum_production_watts =
          (totals.maximum_production_watts or 0) + maximum_production
        totals.maximum_consumption_watts =
          (totals.maximum_consumption_watts or 0) + maximum_consumption
        capacity_network_count = capacity_network_count + 1
      end
    end
    if include_breakdown then
      net.production_by_entity = nonempty(prod_by)
      net.consumption_by_entity = nonempty(cons_by)
    end
    networks[key] = net

    totals.production_watts = totals.production_watts + production
    totals.consumption_watts = totals.consumption_watts + consumption
  end

  if capacity_network_count == 0 then
    totals.maximum_production_watts = nil
    totals.maximum_consumption_watts = nil
  end

  if include_accumulators then
    for _, acc in pairs(accumulators) do
      local charge = acc.energy
      local capacity = acc.electric_buffer_size or 0
      totals.accumulator_charge_joules = totals.accumulator_charge_joules + charge
      totals.accumulator_capacity_joules = totals.accumulator_capacity_joules + capacity
      local id = acc.electric_network_id
      if id then
        -- On a global-network surface all accumulators belong to the one
        -- global network; elsewhere, networks reachable only through
        -- accumulators (no readable flow statistics) still get an entry,
        -- so totals and networks agree.
        local key = (is_global and networks["global"]) and "global" or tostring(id)
        local net = networks[key]
        if not net then
          net = {
            production_watts = 0,
            consumption_watts = 0,
            accumulator_charge_joules = 0,
            accumulator_capacity_joules = 0,
          }
          networks[key] = net
        end
        net.accumulator_charge_joules = net.accumulator_charge_joules + charge
        net.accumulator_capacity_joules = net.accumulator_capacity_joules + capacity
      end
    end
  end

  -- Drop dead networks (isolated poles): nothing flowing, nothing stored.
  for key, net in pairs(networks) do
    if net.production_watts == 0 and net.consumption_watts == 0
        and (net.maximum_production_watts or 0) == 0
        and (net.maximum_consumption_watts or 0) == 0
        and net.accumulator_capacity_joules == 0 then
      networks[key] = nil
    end
  end
  for _ in pairs(networks) do
    totals.network_count = totals.network_count + 1
  end

  local out = {totals = totals, networks = nonempty(networks)}

  -- Entity counts for the types seen in the power breakdown, so
  -- watts-per-type can be turned into utilization per machine.
  if seen_names and next(seen_names) ~= nil then
    local counts = {}
    for name in pairs(seen_names) do
      local ok, n = pcall(function()
        return surface.count_entities_filtered{name = name}
      end)
      if ok and n and n > 0 then counts[name] = n end
    end
    out.count_by_entity = nonempty(counts)
  end

  return out
end

-- --------------------------------------------------------------------------
-- Logistics: aggregated item and robot counts per force, per surface.
-- --------------------------------------------------------------------------

local function collect_logistics(surface, quality_breakdown)
  local out = {}
  local cached_orders_by_force = (storage.robot_order_counts or {})[surface.name] or {}
  for _, force in pairs(game.forces) do
    local nets = force.logistic_networks[surface.name]
    if nets and #nets > 0 then
      local items, by_quality = {}, {}
      local robots = {
        logistic_total = 0,
        logistic_available = 0,
        construction_total = 0,
        construction_available = 0,
        waiting_for_charge = 0,
      }
      for _, net in pairs(nets) do
        for _, entry in pairs(net.get_contents()) do
          items[entry.name] = (items[entry.name] or 0) + entry.count
          if quality_breakdown then
            local key = entry.name .. ":" .. (entry.quality or "normal")
            by_quality[key] = (by_quality[key] or 0) + entry.count
          end
        end
        robots.logistic_total = robots.logistic_total + net.all_logistic_robots
        robots.logistic_available = robots.logistic_available + net.available_logistic_robots
        robots.construction_total = robots.construction_total + net.all_construction_robots
        robots.construction_available = robots.construction_available + net.available_construction_robots
        for _, cell in pairs(net.cells) do
          robots.waiting_for_charge = robots.waiting_for_charge + cell.to_charge_robot_count
        end
      end
      local entry = {
        network_count = #nets,
        robots = robots,
        robot_orders = cached_orders_by_force[force.name] or {},
        items = nonempty(items),
      }
      if quality_breakdown then
        entry.items_by_quality = nonempty(by_quality)
      end
      out[force.name] = entry
    end
  end
  return nonempty(out)
end

local function count_robot_orders(robots, kind, counts)
  for _, robot in pairs(robots) do
    if robot.valid then
      local ok, queue = pcall(function() return robot.robot_order_queue end)
      local order = ok and queue and queue[1]
      local name = order and robot_order_name_by_value[order.type]
      if name and robot_order_kind_by_name[name] == kind then
        counts[kind][name] = counts[kind][name] + 1
      end
    end
  end
end

local function sample_robot_orders()
  local by_surface = {}
  for _, surface in pairs(game.surfaces) do
    local by_force = {}
    for _, force in pairs(game.forces) do
      local nets = force.logistic_networks[surface.name]
      if nets and #nets > 0 then
        local counts = {logistic = {}, construction = {}}
        for name, kind in pairs(robot_order_kind_by_name) do
          counts[kind][name] = 0
        end
        for _, net in pairs(nets) do
          count_robot_orders(net.logistic_robots, "logistic", counts)
          count_robot_orders(net.construction_robots, "construction", counts)
        end
        by_force[force.name] = counts
      end
    end
    if next(by_force) then by_surface[surface.name] = by_force end
  end
  storage.robot_order_counts = by_surface
  storage.robot_order_sample_tick = game.tick
end

local function refresh_robot_order_counts()
  local last_sample = storage.robot_order_sample_tick
  if not last_sample or game.tick < last_sample
      or game.tick - last_sample >= ROBOT_ORDER_SAMPLE_INTERVAL_TICKS then
    sample_robot_orders()
  end
end

-- --------------------------------------------------------------------------
-- Science: per-pack production/consumption rates and totals, per surface.
-- Science packs are recognized by the "*science-pack*" naming convention
-- (all vanilla and Space Age packs follow it, as do most mods).
-- --------------------------------------------------------------------------

local PRECISION_1M = defines.flow_precision_index.one_minute
local PRECISION_10M = defines.flow_precision_index.ten_minutes

local function collect_science_packs(force)
  local by_surface = {}
  for _, surface in pairs(game.surfaces) do
    local istats = force.get_item_production_statistics(surface)
    local packs = {}
    -- Item stats: "input" is production, "output" is consumption; flows are
    -- normalized per minute, so get_flow_count is already items/minute.
    for name, total in pairs(istats.input_counts) do
      if name:find("science%-pack") then
        packs[name] = {produced_total = total}
      end
    end
    for name, total in pairs(istats.output_counts) do
      if name:find("science%-pack") then
        packs[name] = packs[name] or {}
        packs[name].consumed_total = total
      end
    end
    for name, pack in pairs(packs) do
      -- A pack only consumed (imported) or only produced on this surface
      -- would otherwise omit one of the totals; emit 0 so the schema is
      -- uniform for consumers.
      pack.produced_total = pack.produced_total or 0
      pack.consumed_total = pack.consumed_total or 0
      pack.produced_per_minute = istats.get_flow_count{
        name = name, category = "input", precision_index = PRECISION_1M,
      }
      pack.consumed_per_minute = istats.get_flow_count{
        name = name, category = "output", precision_index = PRECISION_1M,
      }
      pack.produced_per_minute_10m = istats.get_flow_count{
        name = name, category = "input", precision_index = PRECISION_10M,
      }
      pack.consumed_per_minute_10m = istats.get_flow_count{
        name = name, category = "output", precision_index = PRECISION_10M,
      }
    end
    if next(packs) ~= nil then
      by_surface[surface.name] = packs
    end
  end
  return nonempty(by_surface)
end

-- --------------------------------------------------------------------------
-- Forces: research, rockets, production totals; evolution for the enemy.
-- --------------------------------------------------------------------------

local function collect_forces(include_production, include_science)
  local out = {}
  for _, force in pairs(game.forces) do
    if force.name == "player" or #force.players > 0 then
      local entry = {
        rockets_launched = force.rockets_launched,
        items_launched = nonempty(force.items_launched),
      }
      local research = {}
      local current = force.current_research
      if current then
        research.current = current.name
        research.progress = force.research_progress
        research.current_level = current.level
      end
      local previous = force.previous_research
      if previous then
        research.previous = previous.name
      end
      local queue = {}
      for _, tech in pairs(force.research_queue) do
        queue[#queue + 1] = tech.name
      end
      research.queue = nonempty(queue)
      local researched, total = 0, 0
      for _, tech in pairs(force.technologies) do
        total = total + 1
        if tech.researched then researched = researched + 1 end
      end
      research.technologies_researched = researched
      research.technologies_total = total
      entry.research = research
      if include_science then
        entry.science_packs = collect_science_packs(force)
      end
      if include_production then
        local production = {}
        for _, surface in pairs(game.surfaces) do
          local istats = force.get_item_production_statistics(surface)
          local fstats = force.get_fluid_production_statistics(surface)
          local p = {
            items_produced_total = nonempty(istats.input_counts),
            items_consumed_total = nonempty(istats.output_counts),
            fluids_produced_total = nonempty(fstats.input_counts),
            fluids_consumed_total = nonempty(fstats.output_counts),
          }
          if next(p) ~= nil then production[surface.name] = p end
        end
        entry.production = nonempty(production)
      end
      out[force.name] = entry
    elseif force.name == "enemy" then
      local evolution = {}
      local components = {}
      for _, surface in pairs(game.surfaces) do
        evolution[surface.name] = force.get_evolution_factor(surface)
        components[surface.name] = {
          time = force.get_evolution_factor_by_time(surface),
          pollution = force.get_evolution_factor_by_pollution(surface),
          spawner_kills = force.get_evolution_factor_by_killing_spawners(surface),
        }
      end
      out[force.name] = {evolution = evolution, evolution_components = components}
    end
  end
  return nonempty(out)
end

-- --------------------------------------------------------------------------
-- Snapshot assembly and export.
-- --------------------------------------------------------------------------

local function build_snapshot()
  local include_logistics = cfg("logistics")
  local quality_breakdown = cfg("quality-breakdown")
  local include_power = cfg("power")
  local power_breakdown = cfg("power-breakdown")
  local include_accumulators = cfg("accumulators")
  local include_production = cfg("production")
  local include_science = cfg("science")
  local include_pollution = cfg("pollution")
  local include_trains = cfg("trains")

  local players = {}
  for _, player in pairs(game.connected_players) do
    players[#players + 1] = player.name
  end

  if include_logistics then refresh_robot_order_counts() end

  local surfaces = {}
  for _, surface in pairs(game.surfaces) do
    local s = {
      index = surface.index,
      is_platform = surface.platform ~= nil,
    }
    if include_pollution then
      s.pollution = surface.get_total_pollution()
      local pstats = surface.pollution_statistics
      s.pollution_produced_total = nonempty(pstats.input_counts)
      s.pollution_absorbed_total = nonempty(pstats.output_counts)
      local absorbing_nests = 0
      for _, nest in pairs(surface.find_entities_filtered{type = "unit-spawner", force = "enemy"}) do
        if nest.absorbed_pollution > 0 then
          absorbing_nests = absorbing_nests + 1
        end
      end
      s.pollution_absorbing_nest_count = absorbing_nests
    end
    if include_power then
      s.power = collect_power(surface, power_breakdown, include_accumulators)
    end
    if include_logistics then
      s.logistics = collect_logistics(surface, quality_breakdown)
    end
    if include_trains then
      s.trains = collect_trains(surface)
    end
    if cfg("defense") then
      s.defense = collect_defenses(surface)
      local defense = storage.defense or {}
      local key = surface.name
      s.defense.damage_received = nonempty(defense.damage_received and defense.damage_received[key] or {})
      s.defense.damage_events = nonempty(defense.damage_events and defense.damage_events[key] or {})
      s.defense.enemy_kills = nonempty(defense.enemy_kills and defense.enemy_kills[key] or {})
      s.defense.player_losses = nonempty(defense.player_losses and defense.player_losses[key] or {})
    end
    surfaces[surface.name] = s
  end

  local snapshot = {
    meta = {
      mod_version = MOD_VERSION,
      tick = game.tick,
      ticks_played = game.ticks_played,
      game_time_seconds = math.floor(game.tick / 60),
      player_count = #game.connected_players,
      players_online = nonempty(players),
      interval_seconds = cfg("interval-seconds"),
      robot_order_sample_interval_seconds = ROBOT_ORDER_SAMPLE_INTERVAL_TICKS / 60,
      robot_order_sample_age_seconds = storage.robot_order_sample_tick
          and math.floor((game.tick - storage.robot_order_sample_tick) / 60) or nil,
    },
    surfaces = surfaces,
    forces = collect_forces(include_production, include_science),
  }

  local decimals = cfg("decimals")
  if decimals and decimals >= 0 and decimals <= 12 then
    round_floats(snapshot, 10 ^ decimals)
  end
  return snapshot
end

local function do_export()
  local ok, err = pcall(function()
    local json = helpers.table_to_json(build_snapshot())
    -- for_player = 0 restricts the write to the server's output "if present";
    -- in single player there is no server, so the write is silently skipped.
    -- Only honor the setting in actual multiplayer.
    local target = (cfg("server-only") and game.is_multiplayer()) and 0 or nil
    local mode = cfg("mode")
    if mode == "snapshot" or mode == "both" then
      helpers.write_file(cfg("filename"), json, false, target)
    end
    if mode == "journal" or mode == "both" then
      helpers.write_file(cfg("journal-filename"), json .. "\n", true, target)
    end
  end)
  if not ok then
    log("[wiretap] export failed: " .. tostring(err))
  end
end

-- --------------------------------------------------------------------------
-- Defense telemetry: event counters are cumulative for the current save.
-- Only player-force structures are damage-tracked; deaths are split into
-- player losses and enemy kills.
-- --------------------------------------------------------------------------

script.on_event(defines.events.on_entity_damaged, function(event)
  if not cfg("defense") then return end
  local entity = event.entity
  if not (entity and entity.valid and entity.force and entity.force.name == "player") then return end
  ensure_defense_storage()
  local surface = entity.surface.name
  local entity_name = entity.name or "unknown"
  local damage_type = valid_name(event.damage_type, "unknown")
  local attacker_force = valid_name(event.force, valid_name(event.cause and event.cause.force, "environment"))
  local keys = {surface, entity_name, damage_type, attacker_force}
  nested_add(storage.defense.damage_received, keys, event.final_damage_amount or 0)
  nested_add(storage.defense.damage_events, keys, 1)
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
  if not cfg("defense") then return end
  local entity = event.entity
  if not (entity and entity.valid and entity.force) then return end
  ensure_defense_storage()
  local force_name = entity.force.name
  local surface = entity.surface.name
  local entity_name = entity.name or "unknown"
  local damage_type = valid_name(event.damage_type, "unknown")
  local attacker_force = valid_name(event.force, valid_name(event.cause and event.cause.force, "environment"))
  if force_name == "enemy" then
    nested_add(storage.defense.enemy_kills, {surface, entity_name, damage_type, attacker_force}, 1)
  elseif force_name == "player" then
    nested_add(storage.defense.player_losses, {surface, entity_name, damage_type, attacker_force}, 1)
  end
end, {{filter = "force", force = "player"}, {filter = "force", force = "enemy"}})

-- --------------------------------------------------------------------------
-- Timer wiring. on_load may only read `storage`, so the interval is
-- mirrored there whenever it can be read from settings (game context).
-- --------------------------------------------------------------------------

local function refresh_interval()
  storage.interval_ticks = math.max(1, cfg("interval-seconds")) * 60
end

local function register_timer()
  script.on_nth_tick(nil)
  script.on_nth_tick(storage.interval_ticks or 600, do_export)
end

script.on_init(function()
  ensure_defense_storage()
  refresh_interval()
  register_timer()
end)

script.on_load(register_timer)

script.on_configuration_changed(function()
  ensure_defense_storage()
  refresh_interval()
  register_timer()
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting and event.setting:sub(1, #SETTING_PREFIX) == SETTING_PREFIX then
    refresh_interval()
    register_timer()
  end
end)

-- --------------------------------------------------------------------------
-- Live access: remote interface (for other mods / RCON) and a command.
--   RCON:  /wiretap        -> prints the JSON snapshot to the caller
--          /wiretap write  -> forces a file export now
-- --------------------------------------------------------------------------

remote.add_interface("wiretap", {
  stats = build_snapshot,
  stats_json = function() return helpers.table_to_json(build_snapshot()) end,
  write_now = do_export,
  version = function() return MOD_VERSION end,
})

commands.add_command(
  "wiretap",
  "Print current stats as JSON; '/wiretap write' forces a file export.",
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
        do_export()
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
        reply(helpers.table_to_json(build_snapshot()))
      end
    end)
    if not ok then
      reply("[wiretap] error: " .. tostring(err))
    end
  end)
