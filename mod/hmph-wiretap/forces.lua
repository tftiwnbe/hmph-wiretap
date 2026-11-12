-- Research and production are sampled across ticks, reusing item-statistic
-- copies for science and production instead of fetching the same totals twice.
local forces = {}
local MAX_RECORDS = 128
local PRECISION_1M = defines.flow_precision_index.one_minute
local PRECISION_10M = defines.flow_precision_index.ten_minutes

local function nonempty(t) return next(t) and t or nil end

-- Prototype names change only with mod configuration. Build this index once
-- on init/configuration change, not for every force on every snapshot.
function forces.technology_names()
  local names = {}
  for name in pairs(prototypes.technology) do names[#names + 1] = name end
  return names
end

function forces.new(options, surface_indices, technologies)
  local list = {}
  for _, force in pairs(game.forces) do list[#list + 1] = force end
  return {
    options = options, surface_indices = surface_indices, technologies = technologies,
    forces = list, force_index = 1, phase = "force", out = {},
  }
end

local function next_surface(job)
  job.surface, job.stats, job.inputs, job.outputs, job.packs, job.pack_key = nil, nil, nil, nil, nil, nil
  job.surface_index = job.surface_index + 1
  job.phase = "surface"
end

local function next_force(job, publish)
  if publish then
    local entry = job.entry
    if entry.production then entry.production = nonempty(entry.production) end
    if entry.science_packs then entry.science_packs = nonempty(entry.science_packs) end
    job.out[job.force.name] = entry
  end
  job.force, job.entry, job.surface, job.stats = nil, nil, nil, nil
  job.inputs, job.outputs, job.packs, job.queue = nil, nil, nil, nil
  job.key, job.pack_key = nil, nil
  job.force_index = job.force_index + 1
  job.phase = "force"
end

function forces.step(job)
  if job.force and not job.force.valid then next_force(job, false); return false end
  if job.phase == "force" then
    local force = job.forces[job.force_index]
    if not force then return true end
    if not force.valid then job.force_index = job.force_index + 1; return false end
    job.force, job.surface_index = force, 1
    if force.name == "player" or #force.players > 0 then
      local research = {technologies_researched = 0, technologies_total = 0}
      local current, previous = force.current_research, force.previous_research
      if current then research.current, research.progress, research.current_level = current.name, force.research_progress, current.level end
      if previous then research.previous = previous.name end
      job.entry = {research = research, rockets_launched = force.rockets_launched, items_launched = nonempty(force.items_launched)}
      if job.options.science then job.entry.science_packs = {} end
      if job.options.production then job.entry.production = {} end
      job.technology_index, job.phase = 1, "technologies"
    elseif force.name == "enemy" then
      job.entry, job.phase = {evolution = {}, evolution_components = {}}, "surface"
    else
      next_force(job, false)
    end
    return false
  elseif job.phase == "technologies" then
    local research = job.entry.research
    local technologies = job.force.technologies
    for _ = 1, MAX_RECORDS do
      local name = job.technologies[job.technology_index]
      if not name then
        job.queue, job.queue_index, job.phase = job.force.research_queue or {}, 1, "queue"
        research.queue = {}
        return false
      end
      job.technology_index = job.technology_index + 1
      local technology = technologies[name]
      if technology and technology.valid then
        research.technologies_total = research.technologies_total + 1
        if technology.researched then research.technologies_researched = research.technologies_researched + 1 end
      end
    end
    return false
  elseif job.phase == "queue" then
    for _ = 1, MAX_RECORDS do
      local technology = job.queue[job.queue_index]
      if not technology then
        job.entry.research.queue = nonempty(job.entry.research.queue)
        job.phase = "surface"
        return false
      end
      job.queue_index = job.queue_index + 1
      if technology.valid then
        local queue = job.entry.research.queue
        queue[#queue + 1] = technology.name
      end
    end
    return false
  elseif job.phase == "surface" then
    local index = job.surface_indices[job.surface_index]
    if not index then next_force(job, true); return false end
    local surface = game.surfaces[index]
    if not (surface and surface.valid) then job.surface_index = job.surface_index + 1; return false end
    if job.entry.evolution then
      job.entry.evolution[surface.name] = job.force.get_evolution_factor(surface)
      job.entry.evolution_components[surface.name] = {
        time = job.force.get_evolution_factor_by_time(surface),
        pollution = job.force.get_evolution_factor_by_pollution(surface),
        spawner_kills = job.force.get_evolution_factor_by_killing_spawners(surface),
      }
      job.surface_index = job.surface_index + 1
      return false
    end
    if not (job.options.science or job.options.production) then job.surface_index = job.surface_index + 1; return false end
    job.surface = surface
    job.stats = job.force.get_item_production_statistics(surface)
    job.inputs, job.outputs = job.stats.input_counts, job.stats.output_counts
    if job.options.production then
      local fstats = job.force.get_fluid_production_statistics(surface)
      local production = {
        items_produced_total = nonempty(job.inputs), items_consumed_total = nonempty(job.outputs),
        fluids_produced_total = nonempty(fstats.input_counts), fluids_consumed_total = nonempty(fstats.output_counts),
      }
      if next(production) then job.entry.production[surface.name] = production end
    end
    if job.options.science then
      job.packs, job.key, job.phase = {}, nil, "science_inputs"
    else
      next_surface(job)
    end
    return false
  end

  -- A surface or its statistics may disappear while science work is pending.
  if not (job.surface.valid and job.stats.valid) then next_surface(job); return false end
  if job.phase == "science_inputs" or job.phase == "science_outputs" then
    local input = job.phase == "science_inputs"
    local counts = input and job.inputs or job.outputs
    for _ = 1, MAX_RECORDS do
      local name, total = next(counts, job.key)
      if not name then
        job.key = nil
        job.phase = input and "science_outputs" or "science_rates"
        return false
      end
      job.key = name
      if name:find("science%-pack") then
        local pack = job.packs[name] or {produced_total = 0, consumed_total = 0}
        pack[input and "produced_total" or "consumed_total"] = total
        job.packs[name] = pack
      end
    end
    return false
  elseif job.phase == "science_rates" then
    -- Four native flow calls per pack, capped at 64 calls per tick.
    for _ = 1, 16 do
      local name, pack = next(job.packs, job.pack_key)
      if not name then
        job.entry.science_packs[job.surface.name] = nonempty(job.packs)
        next_surface(job)
        return false
      end
      job.pack_key = name
      pack.produced_per_minute = job.stats.get_flow_count{name = name, category = "input", precision_index = PRECISION_1M}
      pack.consumed_per_minute = job.stats.get_flow_count{name = name, category = "output", precision_index = PRECISION_1M}
      pack.produced_per_minute_10m = job.stats.get_flow_count{name = name, category = "input", precision_index = PRECISION_10M}
      pack.consumed_per_minute_10m = job.stats.get_flow_count{name = name, category = "output", precision_index = PRECISION_10M}
    end
    return false
  end
end

return forces
