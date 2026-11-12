-- Bounded float rounding with plain-table continuation frames. Keep cursor
-- keys intact until traversal ends so next() resumes after save/load safely.
local normalize = {}

function normalize.new(snapshot, decimals)
  return {stack = {{value = snapshot}}, multiplier = 10 ^ decimals}
end

function normalize.step(job)
  for _ = 1, 256 do
    local frame = job.stack[#job.stack]
    if not frame then return true end
    local key, value = next(frame.value, frame.key)
    if key == nil then
      job.stack[#job.stack] = nil
    else
      frame.key = key
      if type(value) == "table" then
        job.stack[#job.stack + 1] = {value = value}
      elseif type(value) == "number" and value % 1 ~= 0 then
        frame.value[key] = math.floor(value * job.multiplier + 0.5) / job.multiplier
      end
    end
  end
  return false
end

return normalize
