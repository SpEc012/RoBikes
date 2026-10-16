--[[
	TerrainDeform  —  dynamic ruts + groove grid, the MX Bikes signature feature.
	A sparse grid over the world (X,Z) holding per-cell rutDepth (m) and groove (0..1).
	Tyres dig ruts on soft ground (sinkage/compacting), push berms to the sides (bulldozing),
	and wear a hardened "groove" along the racing line. Feed the result back into the
	suspension raycast (ground sits lower in a rut; rut walls steer the wheel) and grip.

	Replicate cell deltas to all clients for multiplayer (mirrors CC_SyncTerrainDeformationData).
]]

local TerrainDeform = {}
TerrainDeform.__index = TerrainDeform

local CELL = 0.25           -- metres per cell
local MAX_RUT = 0.18        -- m, deepest a rut gets
local BERM = 0.35           -- fraction of dug depth pushed into lateral neighbours

local function key(ix, iz) return ix * 100003 + iz end

function TerrainDeform.new()
	return setmetatable({ cells = {}, dirty = {} }, TerrainDeform)
end

function TerrainDeform:_cell(ix, iz)
	local k = key(ix, iz)
	local c = self.cells[k]
	if not c then c = { rut = 0, groove = 0 }; self.cells[k] = c end
	return c, k
end

-- worldX/Z in metres. load N, slip 0..1, soft 0..1 (surface softness), dt s.
function TerrainDeform:deform(worldX, worldZ, lateralX, lateralZ, load, slip, soft, dt)
	if soft <= 0 or load <= 0 then return end
	local ix, iz = math.floor(worldX / CELL), math.floor(worldZ / CELL)
	local c, k = self:_cell(ix, iz)

	-- Sinkage/compacting: dig proportional to load * slip * softness.
	local dig = math.clamp(load / 3000 * (0.3 + slip) * soft * dt * 1.2, 0, 0.02)
	c.rut = math.min(MAX_RUT, c.rut + dig)
	c.groove = math.min(1, c.groove + dt * 0.05)   -- wear/harden the line
	self.dirty[k] = true

	-- Bulldozing: push berms into the two lateral neighbours.
	local nlx = math.floor((worldX + lateralX * CELL) / CELL)
	local nlz = math.floor((worldZ + lateralZ * CELL) / CELL)
	local prx = math.floor((worldX - lateralX * CELL) / CELL)
	local prz = math.floor((worldZ - lateralZ * CELL) / CELL)
	local n1, k1 = self:_cell(nlx, nlz); n1.rut = math.max(-MAX_RUT, n1.rut - dig * BERM); self.dirty[k1] = true
	local n2, k2 = self:_cell(prx, prz); n2.rut = math.max(-MAX_RUT, n2.rut - dig * BERM); self.dirty[k2] = true
end

-- Returns rutDepth (m, +down) and groove (0..1) at a world point.
function TerrainDeform:sample(worldX, worldZ)
	local ix, iz = math.floor(worldX / CELL), math.floor(worldZ / CELL)
	local c = self.cells[key(ix, iz)]
	if not c then return 0, 0 end
	return c.rut, c.groove
end

-- Lateral "rut centering": gradient of rut depth across the wheel's lateral axis.
-- Returns a signed value; multiply by a gain and apply along lateral to pull the wheel
-- toward the deeper rut (this is the feel of a rut steering you).
function TerrainDeform:rutGradient(worldX, worldZ, lateralX, lateralZ)
	local rL = select(1, self:sample(worldX + lateralX * CELL, worldZ + lateralZ * CELL))
	local rR = select(1, self:sample(worldX - lateralX * CELL, worldZ - lateralZ * CELL))
	return (rR - rL)   -- >0 => deeper on the -lateral side; push that way
end

-- Collect and clear changed cells for network replication.
function TerrainDeform:takeDirty()
	local out = {}
	for k in pairs(self.dirty) do
		local c = self.cells[k]
		out[#out + 1] = { k = k, rut = c.rut, groove = c.groove }
	end
	self.dirty = {}
	return out
end

-- Apply replicated deltas (on remote clients).
function TerrainDeform:applyDirty(list)
	for _, e in ipairs(list) do
		self.cells[e.k] = { rut = e.rut, groove = e.groove }
	end
end

return TerrainDeform
