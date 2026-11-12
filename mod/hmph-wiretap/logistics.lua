-- Saveable, incremental logistics aggregation. Native network reads are still
-- synchronous; Lua visits at most 256 item/cell records and starts at most four
-- networks per step. These are work limits, not a wall-clock time budget.
local logistics = {}
local MAX_RECORDS = 256
local MAX_NETWORKS = 4

local function nonempty(t)
  return next(t) and t or nil
end

function logistics.new(surface, quality_breakdown, robot_orders)
  local forces = {}
  for _, force in pairs(game.forces) do forces[#forces + 1] = force end
  return {
    surface = surface, forces = forces, force_index = 1, out = {},
    quality_breakdown = quality_breakdown, robot_orders = robot_orders,
  }
end

local function start_force(job, force)
  job.force = force
  job.networks = force.logistic_networks[job.surface.name] or {}
  job.network_index = 1
  job.entry = {
    network_count = 0, items = {}, items_by_quality = {},
    robots = {
      logistic_total = 0, logistic_available = 0,
      construction_total = 0, construction_available = 0, waiting_for_charge = 0,
    },
  }
end

local function finish_force(job)
  local entry = job.entry
  if job.force.valid and entry.network_count > 0 then
    entry.items = nonempty(entry.items)
    entry.items_by_quality = job.quality_breakdown and nonempty(entry.items_by_quality) or nil
    entry.robot_orders = job.robot_orders[job.force.name] or {}
    job.out[job.force.name] = entry
  end
  job.force, job.networks, job.entry = nil, nil, nil
  job.items, job.cells, job.item_index, job.cell_index = nil, nil, nil, nil
  job.force_index = job.force_index + 1
end

function logistics.step(job)
  local records, networks = 0, 0
  while records < MAX_RECORDS and networks < MAX_NETWORKS do
    if not job.force then
      local force = job.forces[job.force_index]
      if not force then return true end
      if force.valid then
        start_force(job, force)
      else
        job.force_index = job.force_index + 1
      end
      -- Bound transitions through forces with empty/invalid networks as well.
      networks = networks + 1
    elseif not job.force.valid then
      finish_force(job)
      networks = networks + 1
    elseif job.items then
      local item = job.items[job.item_index]
      if item then
        job.item_index = job.item_index + 1
        records = records + 1
        local items = job.entry.items
        items[item.name] = (items[item.name] or 0) + item.count
        if job.quality_breakdown then
          local key = item.name .. ":" .. (item.quality or "normal")
          local qualities = job.entry.items_by_quality
          qualities[key] = (qualities[key] or 0) + item.count
        end
      else
        job.items, job.item_index = nil, nil
      end
    elseif job.cells then
      local cell = job.cells[job.cell_index]
      if cell then
        job.cell_index = job.cell_index + 1
        records = records + 1
        -- Roboports can disappear while a saved batch is in progress.
        if cell.valid then
          local robots = job.entry.robots
          robots.waiting_for_charge = robots.waiting_for_charge + cell.to_charge_robot_count
        end
      else
        job.cells, job.cell_index = nil, nil
      end
    else
      local net = job.networks[job.network_index]
      if not net then
        finish_force(job)
        networks = networks + 1
      else
        job.network_index = job.network_index + 1
        networks = networks + 1
        if net.valid then
          -- Capture each native list once; subsequent ticks consume its cursor.
          job.items, job.item_index = net.get_contents(), 1
          job.cells, job.cell_index = net.cells, 1
          local robots = job.entry.robots
          robots.logistic_total = robots.logistic_total + net.all_logistic_robots
          robots.logistic_available = robots.logistic_available + net.available_logistic_robots
          robots.construction_total = robots.construction_total + net.all_construction_robots
          robots.construction_available = robots.construction_available + net.available_construction_robots
          job.entry.network_count = job.entry.network_count + 1
        end
      end
    end
  end
  return false
end

return logistics
