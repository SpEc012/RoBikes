--!nonstrict
--[[
	BikeRenderer — original bike + rider made from plain Parts, moved kinematically every frame.
	If ReplicatedStorage.RiderR15 exists, the imported R15 rider (RiderRig) replaces the plain-Parts rider, and if
	ReplicatedStorage.Bike450 exists, the imported bike mesh (BikeModel) replaces the plain-Parts bike.
	No MX Bikes meshes/textures are used. Physics is in metres; this module multiplies by
	Config.STUDS_PER_METER and nothing else in the game does.

	Design frame used below: (forward, up, side) metres, origin = ground under the rear axle at rest.
	render state (from BikePhysics:getRenderState() or the network):
	  { cf = CFrame (metres, CoM), wheels = { {ext, angle}, {ext, angle} }, steer, riderLat, riderLong,
	    crashed, riderCF (metres, ragdoll) }
]]

local Config = require(script.Parent.RobikesConfig)
local RiderRig = require(script.Parent.RiderRig)
local BikeModel = require(script.Parent.BikeModel)
local BikeModelData = require(script.Parent.BikeModelData)
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BikeRenderer = {}
BikeRenderer.__index = BikeRenderer

local S = Config.STUDS_PER_METER

local PALETTE = {
	["250x"] = Color3.fromRGB(245, 200, 30),
	["250xf"] = Color3.fromRGB(40, 110, 230),
	["350xf"] = Color3.fromRGB(40, 170, 90),
	["450xf"] = Color3.fromRGB(220, 50, 40),
	["450sm"] = Color3.fromRGB(150, 60, 200),
}
local BLACK = Color3.fromRGB(25, 25, 28)
local DARK = Color3.fromRGB(55, 55, 60)
local METAL = Color3.fromRGB(165, 168, 175)
local WHITE = Color3.fromRGB(235, 235, 235)
local GOLD = Color3.fromRGB(210, 165, 60)

local function newPart(model, name, shape, sizeM, color, material, transparency)
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape or Enum.PartType.Block
	p.Size = sizeM * S
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

-- mesh-bike colour per bike (BikeModelData.colourMaps keys), matching PALETTE
local MESH_COLOUR = {
	["250x"] = "yellow",
	["250xf"] = "blue",
	["350xf"] = "green",
	["450xf"] = "red",
	["450sm"] = "purple",
}

-- colour (optional): a BikeModelData.colourMaps key for the mesh bike; defaults to the bike's own colour
function BikeRenderer.new(bikeSpec, parent, name, colour)
	local self = setmetatable({}, BikeRenderer)
	self.spec = bikeSpec
	local model = Instance.new("Model")
	model.Name = name or ("RobikesBike_" .. bikeSpec.id)
	self.model = model
	self.items = {} -- { part, kind, local CFrame (studs), extra }
	local com = bikeSpec.com
	local rake = bikeSpec.rake
	local team = PALETTE[bikeSpec.id] or Color3.fromRGB(230, 120, 30)
	self.team = team

	-- design (forward, up, side) metres -> body-frame studs relative to the CoM
	local function B(f, u, s)
		return Vector3.new((s or 0), u - com[2], -(f - com[1])) * S
	end
	self.B = B

	local function add(kind, part, cf, extra)
		table.insert(self.items, { part = part, kind = kind, cf = cf, extra = extra })
		return part
	end
	local function block(name_, kind, sizeM, color, cf, material)
		return add(kind, newPart(model, name_, Enum.PartType.Block, sizeM, color, material), cf)
	end
	local function seg(a, b, thick, color, kind, name_, cyl, material)
		-- a, b: studs; returns part aligned from a to b
		local len = (b - a).Magnitude
		local cf = CFrame.lookAt((a + b) / 2, b)
		local p
		if cyl then
			p = newPart(model, name_, Enum.PartType.Cylinder, Vector3.new(len / S, thick, thick), color, material)
			cf = cf * CFrame.Angles(0, math.rad(90), 0)
		else
			p = newPart(model, name_, Enum.PartType.Block, Vector3.new(thick, thick, len / S), color, material)
		end
		return add(kind, p, cf)
	end

	-- ---------- static chassis ----------
	block("Engine", "body", Vector3.new(0.26, 0.32, 0.36), METAL, CFrame.new(B(0.62, 0.42)), Enum.Material.Metal)
	block("Head", "body", Vector3.new(0.22, 0.18, 0.22), METAL, CFrame.new(B(0.72, 0.64)) * CFrame.Angles(math.rad(-15), 0, 0), Enum.Material.Metal)
	for _, side in ipairs({ -0.07, 0.07 }) do
		seg(B(1.13, 0.94, side), B(0.48, 0.42, side), 0.045, DARK, "body", "FrameRail")
		seg(B(0.48, 0.80, side), B(0.02, 0.86, side), 0.03, DARK, "body", "Subframe")
		seg(B(1.10, 0.86, side), B(0.70, 0.22, side), 0.035, DARK, "body", "Downtube")
	end
	block("Tank", "body", Vector3.new(0.34, 0.20, 0.40), team, CFrame.new(B(0.86, 0.88)) * CFrame.Angles(math.rad(-6), 0, 0))
	for _, side in ipairs({ -0.17, 0.17 }) do
		block("Shroud", "body", Vector3.new(0.03, 0.26, 0.36), team, CFrame.new(B(0.95, 0.80, side)) * CFrame.Angles(math.rad(-12), 0, 0))
		block("SidePlate", "body", Vector3.new(0.03, 0.20, 0.28), WHITE, CFrame.new(B(0.22, 0.82, side * 0.85)))
		block("Peg", "body", Vector3.new(0.10, 0.025, 0.05), METAL, CFrame.new(B(0.56, 0.35, side * 1.2)), Enum.Material.Metal)
	end
	block("Seat", "body", Vector3.new(0.24, 0.08, 0.80), BLACK, CFrame.new(B(0.56, 0.95)) * CFrame.Angles(math.rad(2), 0, 0), Enum.Material.Fabric)
	block("RearFender", "body", Vector3.new(0.22, 0.03, 0.55), team, CFrame.new(B(-0.12, 0.93)) * CFrame.Angles(math.rad(12), 0, 0))
	seg(B(0.62, 0.55, 0.17), B(-0.08, 0.86, 0.16), 0.10, METAL, "body", "Muffler", true, Enum.Material.Metal)
	seg(B(0.78, 0.62, 0.10), B(0.62, 0.55, 0.17), 0.05, METAL, "body", "Header", true, Enum.Material.Metal)

	-- ---------- steering assembly (rotates about the rake axis) ----------
	self.head = B(1.149, 0.979) -- steering head on the rake axis (see header comment)
	self.forkDown = Vector3.new(0, -math.cos(rake), -math.sin(rake)) -- body dir along the fork (down, forward)
	self.forkL0 = 0.803 * S -- head -> axle distance at full extension
	block("TopClamp", "steer", Vector3.new(0.24, 0.04, 0.10), METAL, CFrame.new(self.head + Vector3.new(0, 0.02 * S, 0)), Enum.Material.Metal)
	block("Handlebar", "steer", Vector3.new(0.80, 0.03, 0.03), BLACK, CFrame.new(B(1.10, 1.08)), Enum.Material.Metal)
	for _, side in ipairs({ -0.36, 0.36 }) do
		block("Grip", "steer", Vector3.new(0.12, 0.04, 0.04), BLACK, CFrame.new(B(1.10, 1.08, side)), Enum.Material.Fabric)
	end
	block("NumberPlate", "steer", Vector3.new(0.26, 0.22, 0.02), WHITE, CFrame.new(B(1.22, 0.92)) * CFrame.Angles(math.rad(-26), 0, 0))
	block("FrontFender", "steer", Vector3.new(0.16, 0.03, 0.50), team, CFrame.new(B(1.40, 0.78)) * CFrame.Angles(math.rad(8), 0, 0))
	for _, side in ipairs({ -0.085, 0.085 }) do
		-- upper tubes hang from the head; lower legs follow the axle (dynamic)
		local top = self.head + Vector3.new(side * S, 0, 0)
		seg(top, top + self.forkDown * (0.42 * S), 0.05, GOLD, "steer", "ForkUpper", true, Enum.Material.Metal)
		add("forkLower", newPart(model, "ForkLower", Enum.PartType.Cylinder, Vector3.new(0.40, 0.06, 0.06), BLACK, Enum.Material.Metal), CFrame.new(), side * S)
	end

	-- ---------- swingarm + shock (dynamic, follow the rear axle) ----------
	self.pivot = B(0.48, 0.42)
	for _, side in ipairs({ -0.09, 0.09 }) do
		add("swingarm", newPart(model, "Swingarm", Enum.PartType.Block, Vector3.new(0.04, 0.07, 0.6), METAL, Enum.Material.Metal), CFrame.new(), side * S)
	end
	self.shockTop = B(0.45, 0.80)
	add("shock", newPart(model, "Shock", Enum.PartType.Cylinder, Vector3.new(0.3, 0.07, 0.07), GOLD, Enum.Material.Metal), CFrame.new())

	-- ---------- wheels ----------
	self.wheelParts = {}
	for i, wd in ipairs(bikeSpec.wheels) do
		local d = wd.radius * 2
		local parts = {
			{ newPart(model, "Tyre", Enum.PartType.Cylinder, Vector3.new(0.09, d, d), BLACK, Enum.Material.Rubber), CFrame.new() },
			{ newPart(model, "Rim", Enum.PartType.Cylinder, Vector3.new(0.095, d * 0.76, d * 0.76), METAL, Enum.Material.Metal), CFrame.new() },
			{ newPart(model, "Hub", Enum.PartType.Cylinder, Vector3.new(0.14, 0.09, 0.09), DARK, Enum.Material.Metal), CFrame.new() },
			{ newPart(model, "Spoke", Enum.PartType.Block, Vector3.new(0.02, d * 0.74, 0.02), METAL, Enum.Material.Metal), CFrame.new() },
			{ newPart(model, "Spoke", Enum.PartType.Block, Vector3.new(0.02, 0.02, d * 0.74), METAL, Enum.Material.Metal), CFrame.new() },
			{ newPart(model, "Disc", Enum.PartType.Cylinder, Vector3.new(0.01, d * 0.4, d * 0.4), METAL, Enum.Material.Metal), CFrame.new(-0.07 * S, 0, 0) },
		}
		-- hub-side tyre inner (makes the tyre read as a tyre, not a disc)
		parts[2][1].Transparency = 0
		self.wheelParts[i] = parts
	end

	-- ---------- imported bike mesh (ReplicatedStorage.Bike450) replaces the parts above ----------
	local bikeTemplate = ReplicatedStorage:FindFirstChild("Bike450")
	if bikeTemplate then
		self.mesh = BikeModel.new(bikeTemplate, model, S, com, colour or MESH_COLOUR[bikeSpec.id])
	end
	if self.mesh then
		for _, it in ipairs(self.items) do
			it.part:Destroy()
		end
		table.clear(self.items)
		for _, wp in ipairs(self.wheelParts) do
			for _, pair in ipairs(wp) do
				pair[1]:Destroy()
			end
		end
		table.clear(self.wheelParts)
	end

	-- ---------- rider (kinematic; tumbles as a unit when crashed) ----------
	local jersey = team
	local pants = Color3.fromRGB(40, 40, 48)
	self.seat = B(0.56, 0.98)
	self.riderItems = {}
	-- imported R15 rider (ReplicatedStorage.RiderR15) if present, else the plain-Parts rider below
	local riderTemplate = ReplicatedStorage:FindFirstChild("RiderR15")
	if riderTemplate then
		self.rig = RiderRig.new(riderTemplate, model, 1.8 * S)
	end
	if self.rig then
		local L, R = -1, 1
		self.rigTargets = {
			hips = B(0.58, 1.10), hipLean = math.rad(20), torsoLean = math.rad(42), headUp = math.rad(30),
			elbowL = B(0.95, 1.20, 0.45 * L), elbowR = B(0.95, 1.20, 0.45 * R),
			kneeL = B(0.95, 0.85, 0.30 * L), kneeR = B(0.95, 0.85, 0.30 * R),
		}
		self.rigGrips = { B(1.02, 1.08, 0.33 * L), B(1.02, 1.08, 0.33 * R) } -- wrists, just inboard of the grips
		if self.mesh then
			-- sit on and hold the mesh's own seat and bars
			local g = BikeModelData.grip
			self.rigTargets.hips = B(0.58, BikeModelData.seatTop + 0.11)
			self.rigGrips = { B(g[1] - 0.03, g[2] - 0.02, (g[3] - 0.07) * L), B(g[1] - 0.03, g[2] - 0.02, (g[3] - 0.07) * R) }
		end
		self.rigPegs = { B(0.56, 0.43, 0.22 * L), B(0.56, 0.43, 0.22 * R) } -- ankles, above the pegs
	end
	local rider = self.rig == nil
	local function rpart(name_, shape, sizeM, color, cf, material)
		if not rider then
			return nil
		end
		local p = newPart(model, name_, shape, sizeM, color, material)
		table.insert(self.riderItems, { part = p, cf = cf })
		return p
	end
	local function rseg(a, b, thick, color, name_)
		local len = (b - a).Magnitude
		rpart(name_, Enum.PartType.Block, Vector3.new(thick, thick, len / S), color, CFrame.lookAt((a + b) / 2, b))
	end
	rpart("Hips", Enum.PartType.Block, Vector3.new(0.32, 0.18, 0.26), pants, CFrame.new(B(0.52, 1.05)))
	rpart("Torso", Enum.PartType.Block, Vector3.new(0.38, 0.52, 0.22), jersey, CFrame.new(B(0.68, 1.33)) * CFrame.Angles(math.rad(-32), 0, 0), Enum.Material.Fabric)
	rpart("Helmet", Enum.PartType.Ball, Vector3.new(0.30, 0.30, 0.30), WHITE, CFrame.new(B(0.88, 1.66)))
	rpart("Visor", Enum.PartType.Block, Vector3.new(0.20, 0.06, 0.10), team, CFrame.new(B(0.99, 1.71)) * CFrame.Angles(math.rad(-20), 0, 0))
	rpart("Goggles", Enum.PartType.Block, Vector3.new(0.18, 0.06, 0.04), DARK, CFrame.new(B(1.02, 1.64)))
	for _, s in ipairs({ -1, 1 }) do
		local shoulder, elbow, grip = B(0.84, 1.52, 0.20 * s), B(0.97, 1.30, 0.30 * s), B(1.08, 1.10, 0.35 * s)
		rseg(shoulder, elbow, 0.10, jersey, "UpperArm")
		rseg(elbow, grip, 0.09, jersey, "Forearm")
		local hip, knee, ankle = B(0.52, 1.02, 0.13 * s), B(0.80, 0.84, 0.21 * s), B(0.60, 0.42, 0.21 * s)
		rseg(hip, knee, 0.15, pants, "Thigh")
		rseg(knee, ankle, 0.13, WHITE, "Shin")
		rpart("Boot", Enum.PartType.Block, Vector3.new(0.12, 0.10, 0.28), WHITE, CFrame.new(B(0.62, 0.38, 0.21 * s)))
	end

	self.bulkParts = {}
	self.bulkCFs = {}
	model.Parent = parent
	return self
end

function BikeRenderer:destroy()
	self.model:Destroy()
end

-- state: see header. Moves every part in one BulkMoveTo call.
function BikeRenderer:update(state)
	local spec = self.spec
	local bodyCF = CFrame.new(state.cf.Position * S) * state.cf.Rotation
	local parts, cfs = self.bulkParts, self.bulkCFs
	table.clear(parts)
	table.clear(cfs)
	local function put(p, cf)
		table.insert(parts, p)
		table.insert(cfs, cf)
	end

	-- steering frame: rotate about the rake axis through the head (right = negative about the up-axis)
	local axisUp = -self.forkDown
	local steerCF = CFrame.new(self.head) * CFrame.fromAxisAngle(axisUp, -(state.steer or 0)) * CFrame.new(-self.head)
	if self.mesh then
		steerCF = self.mesh:steerCF(state.steer)
		self.mesh:update(bodyCF, state, spec, put)
	end

	-- wheel centres (body frame, studs)
	local wf, wr = state.wheels[1], state.wheels[2]
	local frontSpec, rearSpec = spec.wheels[1], spec.wheels[2]
	-- front: slide along the fork by the physics' vertical compression / cos(rake)
	local frontComp = frontSpec.travel - wf.ext
	local u = (frontComp / math.cos(spec.rake)) * S
	local axleF = self.head + self.forkDown * (self.forkL0 - u)
	local axleR = rearSpec.mount * S - Vector3.new(0, wr.ext * S, 0)

	for _, it in ipairs(self.items) do
		local k = it.kind
		if k == "body" then
			put(it.part, bodyCF * it.cf)
		elseif k == "steer" then
			put(it.part, bodyCF * steerCF * it.cf)
		elseif k == "forkLower" then
			local side = Vector3.new(it.extra, 0, 0)
			local a = axleF + side
			local b = axleF + side - self.forkDown * (0.40 * S)
			put(it.part, bodyCF * steerCF * CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0))
		elseif k == "swingarm" then
			local side = Vector3.new(it.extra, 0, 0)
			local a, b = self.pivot + side, axleR + side
			local len = (b - a).Magnitude
			it.part.Size = Vector3.new(it.part.Size.X, it.part.Size.Y, len)
			put(it.part, bodyCF * CFrame.lookAt((a + b) / 2, b))
		elseif k == "shock" then
			local lower = self.pivot:Lerp(axleR, 0.3) + Vector3.new(0, 0.05 * S, 0)
			local len = (lower - self.shockTop).Magnitude
			it.part.Size = Vector3.new(len, it.part.Size.Y, it.part.Size.Z)
			put(it.part, bodyCF * CFrame.lookAt((self.shockTop + lower) / 2, lower) * CFrame.Angles(0, math.rad(90), 0))
		end
	end

	-- wheels: forward rolling = negative rotation about the body X axis
	for i, wp in ipairs(self.wheelParts) do
		local w = state.wheels[i]
		local base
		if i == 1 then
			base = bodyCF * steerCF * CFrame.new(axleF)
		else
			base = bodyCF * CFrame.new(axleR)
		end
		local spin = CFrame.Angles(-(w.angle or 0), 0, 0)
		for _, pair in ipairs(wp) do
			put(pair[1], base * spin * pair[2])
		end
	end

	-- rider
	local riderBase
	if state.crashed and state.riderCF then
		-- tumble as a unit around the hips
		local rcf = CFrame.new(state.riderCF.Position * S) * state.riderCF.Rotation
		riderBase = rcf * CFrame.new(-self.seat)
	else
		local lat, long = (state.riderLat or 0) * S, (state.riderLong or 0) * S
		local leanAngle = -(state.riderLat or 0) * 1.6 -- lean the body into the shift
		local pitchAngle = -(state.riderLong or 0) * 1.2
		-- air pose: stand on the pegs in the air; in a whip the bike is thrown out from under the rider, so
		-- the body twists back toward the path and hangs off the high side (smoothed, so it reads as effort)
		local k = math.clamp((state.dt or 1 / 60) * 10, 0, 1)
		self.airVis = (self.airVis or 0) + ((state.airborne and 1 or 0) - (self.airVis or 0)) * k
		self.whipVis = (self.whipVis or 0) + ((state.whip or 0) - (self.whipVis or 0)) * k
		local wv, av = self.whipVis, self.airVis
		local stand = av * 0.10 * S
		riderBase = bodyCF
			* CFrame.new(self.seat + Vector3.new(lat * 0.6 + wv * 0.10 * S, stand, -long * 0.6))
			* CFrame.Angles(pitchAngle - av * 0.15, wv * 0.55, leanAngle + wv * 0.45)
			* CFrame.new(-self.seat)
	end
	for _, it in ipairs(self.riderItems) do
		put(it.part, riderBase * it.cf)
	end
	if self.rig then
		-- hands on the (steered) grips, boots on the pegs, expressed in rider space so they hold through the lean
		local t = self.rigTargets
		-- in a whip the knee on the low side drives the bike down and out (rider space, studs)
		self.kneeBase = self.kneeBase or { t.kneeL, t.kneeR }
		local wv = (not state.crashed) and (self.whipVis or 0) or 0
		t.kneeL = self.kneeBase[1] + Vector3.new(math.min(wv, 0) * 0.18 * S, -math.abs(wv) * 0.05 * S, 0)
		t.kneeR = self.kneeBase[2] + Vector3.new(math.max(wv, 0) * 0.18 * S, -math.abs(wv) * 0.05 * S, 0)
		local toRider = riderBase:Inverse() * bodyCF
		t.gripL, t.gripR = toRider * (steerCF * self.rigGrips[1]), toRider * (steerCF * self.rigGrips[2])
		t.ankleL, t.ankleR = toRider * self.rigPegs[1], toRider * self.rigPegs[2]
		self.rig:pose(riderBase, t, put)
	end

	workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)

	-- dev aid: with workspace attribute RobikesDebug = true, the local bike publishes live physics telemetry as
	-- attributes on its model, so Studio tools (which can't see the client's script state) can read a real ride
	local sim = state.sim
	if sim and workspace:GetAttribute("RobikesDebug") then
		local m, t = self.model, sim.telemetry
		m:SetAttribute("speed", t.speed)
		m:SetAttribute("roll", t.roll)
		m:SetAttribute("targetRoll", math.deg(sim.targetRoll or 0))
		m:SetAttribute("steerDeg", math.deg(sim.steer or 0))
		m:SetAttribute("pitch", t.pitch)
		m:SetAttribute("gear", t.gear)
		m:SetAttribute("contacts", t.contacts)
		m:SetAttribute("crashed", t.crashed)
		m:SetAttribute("crashReason", sim.crashReason or "")
		m:SetAttribute("slipF", sim.wheels[1].alpha and math.deg(sim.wheels[1].alpha) or 0)
		m:SetAttribute("slipR", sim.wheels[2].alpha and math.deg(sim.wheels[2].alpha) or 0)
		m:SetAttribute("kappaR", sim.wheels[2].kappa or 0)
		m:SetAttribute("surface", sim.wheels[2].surface or "")
		m:SetAttribute("aid", sim.assists.balanceAssist or -1)
		m:SetAttribute("tc", sim.tcScale or 1)
		m:SetAttribute("time", sim.time)
	end
end

-- Helmet-cam position (studs) for the camera module
function BikeRenderer:helmetCFrame(state)
	local bodyCF = CFrame.new(state.cf.Position * S) * state.cf.Rotation
	return bodyCF * CFrame.new(self.B(0.92, 1.70) + Vector3.new((state.riderLat or 0) * S * 0.6, 0, 0))
end

return BikeRenderer
