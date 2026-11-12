-- Deterministic cooperative collection: cursors and LuaObjects are saveable.
-- Native statistics reads still run synchronously; flow API calls are capped
-- at 64 per step, and the other phases visit at most 128 records per step.
local power = {}
local MAX_RECORDS = 128
local MAX_FLOWS = 64
local PRECISION = defines.flow_precision_index.five_seconds

function power.new(surface, options, scan)
  local job = {
    surface = surface, options = options, scan = scan, phase = "discover",
    reps = {}, networks = {}, seen_names = {}, names = {}, capacity_count = 0,
    totals = {
      production_watts = 0, consumption_watts = 0, network_count = 0,
      accumulator_charge_joules = 0, accumulator_capacity_joules = 0,
    },
  }
  job.is_global = surface.has_global_electric_network
  if job.is_global then
    local stats = surface.global_electric_network_statistics
    if stats then
      job.reps.global = {stats = stats, network = surface.global_electric_network}
    end
  end
  return job
end

local function remember_name(job, name)
  if job.options.breakdown and not job.seen_names[name] then
    job.seen_names[name] = true
    if prototypes.entity[name] then job.names[#job.names + 1] = name end
  end
end

local function finish_network(job)
  local net, rep, key = job.current, job.reps[job.network_key], job.network_key
  if net.production_by_entity and not next(net.production_by_entity) then net.production_by_entity = nil end
  if net.consumption_by_entity and not next(net.consumption_by_entity) then net.consumption_by_entity = nil end
  if rep.network and rep.network.valid then
    local ok, production, consumption = pcall(function()
      local flow = rep.network.parent_network.flow_last_tick
      return flow.maximum_production, flow.maximum_consumption
    end)
    if ok and type(production) == "number" and type(consumption) == "number" then
      net.maximum_production_watts, net.maximum_consumption_watts = production * 60, consumption * 60
      job.totals.maximum_production_watts = (job.totals.maximum_production_watts or 0) + production * 60
      job.totals.maximum_consumption_watts = (job.totals.maximum_consumption_watts or 0) + consumption * 60
      job.capacity_count = job.capacity_count + 1
    end
  end
  job.networks[key] = net
  job.totals.production_watts = job.totals.production_watts + net.production_watts
  job.totals.consumption_watts = job.totals.consumption_watts + net.consumption_watts
  job.current, job.counts, job.flow_key = nil, nil, nil
end

function power.step(job)
  if job.phase == "discover" then
    if job.is_global then job.phase = "networks"; return false end
    for _ = 1, MAX_RECORDS do
      local key, pole = next(job.scan.poles, job.pole_key)
      if not key then job.phase = "networks"; return false end
      job.pole_key = key
      if pole.valid then
        local id = pole.electric_network_id
        if id and not job.reps[tostring(id)] then
          job.reps[tostring(id)] = {stats = pole.electric_network_statistics, network = pole.electric_network}
        end
      end
    end
    return false
  elseif job.phase == "networks" then
    if not job.current then
      local key, rep = next(job.reps, job.network_key)
      if not key then job.phase = "accumulators"; return false end
      job.network_key = key
      if not (rep.stats and rep.stats.valid) then return false end
      job.current = {
        production_watts = 0, consumption_watts = 0,
        accumulator_charge_joules = 0, accumulator_capacity_joules = 0,
      }
      if job.options.breakdown then
        job.current.production_by_entity, job.current.consumption_by_entity = {}, {}
      end
      job.category = "output"
      job.counts = rep.stats.output_counts
    end
    local stats = job.reps[job.network_key].stats
    if not stats.valid then
      job.current, job.counts, job.flow_key = nil, nil, nil
      return false
    end
    for _ = 1, MAX_FLOWS do
      local name = next(job.counts, job.flow_key)
      if not name then
        if job.category == "output" then
          job.category, job.flow_key, job.counts = "input", nil, stats.input_counts
        else
          finish_network(job)
          return false
        end
      else
        job.flow_key = name
        local watts = stats.get_flow_count{name = name, category = job.category, precision_index = PRECISION} * 60
        local production = job.category == "output"
        local key = production and "production_watts" or "consumption_watts"
        job.current[key] = job.current[key] + watts
        if job.options.breakdown then
          job.current[production and "production_by_entity" or "consumption_by_entity"][name] = watts
        end
        remember_name(job, name)
      end
    end
    return false
  elseif job.phase == "accumulators" then
    for _ = 1, MAX_RECORDS do
      local key, acc
      if job.options.accumulators then key, acc = next(job.scan.accumulators, job.accumulator_key) end
      if not key then job.phase = "cleanup"; return false end
      job.accumulator_key = key
      job.totals.accumulator_charge_joules = job.totals.accumulator_charge_joules + acc.charge
      job.totals.accumulator_capacity_joules = job.totals.accumulator_capacity_joules + acc.capacity
      if acc.id then
        local id = job.is_global and job.networks.global and "global" or tostring(acc.id)
        local net = job.networks[id]
        if not net then
          net = {production_watts = 0, consumption_watts = 0, accumulator_charge_joules = 0, accumulator_capacity_joules = 0}
          job.networks[id] = net
        end
        net.accumulator_charge_joules = net.accumulator_charge_joules + acc.charge
        net.accumulator_capacity_joules = net.accumulator_capacity_joules + acc.capacity
      end
    end
    return false
  elseif job.phase == "cleanup" then
    for _ = 1, MAX_RECORDS do
      local key, net = next(job.networks, job.cleanup_key)
      if not key then
        job.phase, job.empty_index = "prune", 1
        return false
      end
      job.cleanup_key = key
      local empty = net.production_watts == 0 and net.consumption_watts == 0
          and (net.maximum_production_watts or 0) == 0 and (net.maximum_consumption_watts or 0) == 0
          and net.accumulator_capacity_joules == 0
      if empty then
        -- Keep keys until traversal completes; deleting a cursor key while
        -- using next() can break a saved continuation after load/rehashing.
        job.empty_keys = job.empty_keys or {}
        job.empty_keys[#job.empty_keys + 1] = key
      else
        job.totals.network_count = job.totals.network_count + 1
      end
    end
    return false
  elseif job.phase == "prune" then
    for _ = 1, MAX_RECORDS do
      local key = job.empty_keys and job.empty_keys[job.empty_index]
      if not key then
        if job.capacity_count == 0 then
          job.totals.maximum_production_watts, job.totals.maximum_consumption_watts = nil, nil
        end
        job.out = {totals = job.totals, networks = next(job.networks) and job.networks or nil}
        return true
      end
      job.networks[key] = nil
      job.empty_index = job.empty_index + 1
    end
    return false
  end
end

return power
