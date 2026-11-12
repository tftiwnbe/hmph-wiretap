-- Incremental, saveable surface scan. Only LuaObjects and plain data are kept
-- in the job: no coroutine, function, local-only cursor, or wall-clock budget.
-- Each step queries at most 32 chunks and visits at most 256 matching entities.
local scan = {}
local MAX_CHUNKS = 32
local MAX_ENTITIES = 256
local defense_types = {
  ["ammo-turret"] = true, ["electric-turret"] = true,
  ["fluid-turret"] = true, ["artillery-turret"] = true,
  wall = true, gate = true,
}

local function add(t, key, value)
  t[key] = (t[key] or 0) + value
end

function scan.new(surface, options)
  local types = {}
  if options.power then types[#types + 1] = "electric-pole" end
  if options.power and options.accumulators then types[#types + 1] = "accumulator" end
  if options.pollution then types[#types + 1] = "unit-spawner" end
  if options.trains then types[#types + 1] = "train-stop" end
  if options.defense then
    for kind in pairs(defense_types) do types[#types + 1] = kind end
  end
  return {
    surface = surface, name = surface.name, options = options,
    chunks = surface.get_chunks(), types = types, phase = "entities",
    poles = {}, accumulators = {}, entity_counts = {}, train_stop_count = 0,
    pollution = 0, absorbing_nests = 0,
    defense = {entity_counts = {}, ammo_by_item = {}, loaded_turret_count = 0, empty_turret_count = 0},
  }
end

local function visit(job, entity)
  local kind = entity.type
  if job.options.power and kind == "electric-pole" then
    local id = entity.electric_network_id
    if id then job.poles[tostring(id)] = entity end
  elseif job.options.power and job.options.accumulators and kind == "accumulator" then
    local id = entity.electric_network_id
    local key = id and tostring(id) or "disconnected"
    local acc = job.accumulators[key]
    if not acc then
      acc = {id = id, charge = 0, capacity = 0}
      job.accumulators[key] = acc
    end
    acc.charge = acc.charge + entity.energy
    acc.capacity = acc.capacity + (entity.electric_buffer_size or 0)
  elseif job.options.pollution and kind == "unit-spawner" and entity.force.name == "enemy" then
    if entity.absorbed_pollution > 0 then job.absorbing_nests = job.absorbing_nests + 1 end
  elseif job.options.trains and kind == "train-stop" and entity.force.name == "player" then
    job.train_stop_count = job.train_stop_count + 1
  end
  if job.options.defense and defense_types[kind] and entity.force.name == "player" then
    local out = job.defense
    add(out.entity_counts, entity.name, 1)
    if kind == "ammo-turret" then
      local inventory = entity.get_inventory(defines.inventory.turret_ammo)
      if inventory and not inventory.is_empty() then
        out.loaded_turret_count = out.loaded_turret_count + 1
        for _, item in pairs(inventory.get_contents()) do add(out.ammo_by_item, item.name, item.count) end
      else
        out.empty_turret_count = out.empty_turret_count + 1
      end
    end
  end
end

-- The second pass counts all power-breakdown names together in each chunk,
-- rather than performing a whole-surface search separately for every name.
function scan.count_power_entities(job, names)
  job.names = names
  job.chunks = job.surface.get_chunks()
  job.phase = "counts"
  job.entities, job.chunk, job.entity_index = nil, nil, nil
end

function scan.step(job)
  if not job.surface.valid or not job.chunks.valid then return true end
  if job.phase == "entities" and #job.types == 0 and not job.options.pollution then return true end
  local chunks, entities = 0, 0
  while chunks < MAX_CHUNKS and entities < MAX_ENTITIES do
    if job.entities then
      local entity = job.entities[job.entity_index]
      if entity then
        job.entity_index = job.entity_index + 1
        entities = entities + 1
        if entity.valid then
          -- Area queries intersect bounding boxes; assign an entity to the
          -- chunk containing its center so boundary-spanning walls/poles count once.
          local pos = entity.position
          if math.floor(pos.x / 32) == job.chunk.x and math.floor(pos.y / 32) == job.chunk.y then
            if job.phase == "counts" then
              add(job.entity_counts, entity.name, 1)
            else
              visit(job, entity)
            end
          end
        end
      else
        job.entities, job.chunk, job.entity_index = nil, nil, nil
      end
    else
      local chunk = job.chunks()
      if not chunk then return true end
      chunks = chunks + 1
      if job.phase == "entities" and job.options.pollution then
        job.pollution = job.pollution + job.surface.get_pollution({x = chunk.x * 32, y = chunk.y * 32})
      end
      local filter = {area = chunk.area}
      local query = false
      if job.phase == "counts" then
        filter.name = job.names
        query = #job.names > 0
      else
        filter.type = job.types
        query = #job.types > 0
      end
      if query then
        job.entities = job.surface.find_entities_filtered(filter)
        job.chunk, job.entity_index = chunk, 1
      end
    end
  end
  return false
end

return scan
