--!nonstrict
--[[
	Ruts — sparse ground-deformation grid (pure Luau, SI). [DESIGN]
	MX Bikes has track_deformation / groove maps (REPORT §7) but its law is unknown; this is our own model:
	each loaded, slipping tyre on a soft surface digs the 0.5 m cell under it a little deeper (up to 10 cm),
	scaled by the surface's compacting_factor from the tyre data.
]]

local Ruts = {}
Ruts.__index = Ruts

local CELL = 0.5 -- metres
local MAX_DEPTH = 0.10
local DIG_RATE = 1.2e-5 -- m per (N·s) before factors

function Ruts.new()
	return setmetatable({ cells = {} }, Ruts)
end

local function key(ix, iz)
	return ix * 73856093 + iz * 19349663 -- simple spatial hash
end

local function cellDepth(self, ix, iz)
	return self.cells[key(ix, iz)] or 0
end

-- Bilinear depth at world (x, z) metres
function Ruts:depth(x, z)
	local fx, fz = x / CELL, z / CELL
	local ix, iz = math.floor(fx), math.floor(fz)
	local tx, tz = fx - ix, fz - iz
	local d00 = cellDepth(self, ix, iz)
	local d10 = cellDepth(self, ix + 1, iz)
	local d01 = cellDepth(self, ix, iz + 1)
	local d11 = cellDepth(self, ix + 1, iz + 1)
	return (d00 * (1 - tx) + d10 * tx) * (1 - tz) + (d01 * (1 - tx) + d11 * tx) * tz
end

-- Gradient (d depth / dx, d depth / dz) for the rut-capture force
function Ruts:gradient(x, z)
	local h = CELL * 0.5
	return (self:depth(x + h, z) - self:depth(x - h, z)) / (2 * h), (self:depth(x, z + h) - self:depth(x, z - h)) / (2 * h)
end

function Ruts:dig(x, z, load, slip, compacting, dt)
	if compacting <= 0 or load <= 0 then
		return
	end
	local ix, iz = math.floor(x / CELL + 0.5), math.floor(z / CELL + 0.5)
	local k = key(ix, iz)
	local d = self.cells[k] or 0
	d = math.min(MAX_DEPTH, d + DIG_RATE * load * (1 + 5 * math.abs(slip)) * compacting * dt * (1 - d / MAX_DEPTH))
	self.cells[k] = d
end

function Ruts:clear()
	table.clear(self.cells)
end

Ruts.MAX_DEPTH = MAX_DEPTH
Ruts.CELL = CELL
return Ruts
