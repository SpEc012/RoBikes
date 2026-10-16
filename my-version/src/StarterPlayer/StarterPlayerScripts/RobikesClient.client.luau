--!nonstrict
--[[
	RobikesClient — runs the local player's bike (client-authoritative physics), renders it, drives the
	camera and HUD, and replicates its state; also draws other players' bikes from replicated states.

	Loop: RenderStepped-time accumulator → fixed 1/240 s physics steps → render → camera → HUD → network.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Robikes = ReplicatedStorage:WaitForChild("Robikes")
local Config = require(Robikes:WaitForChild("RobikesConfig"))
local BikePhysics = require(Robikes:WaitForChild("BikePhysics"))
local BikeController = require(Robikes:WaitForChild("BikeController"))
local BikeRenderer = require(Robikes:WaitForChild("BikeRenderer"))
local Camera = require(Robikes:WaitForChild("Camera"))
local HUD = require(Robikes:WaitForChild("HUD"))

local S = Config.STUDS_PER_METER
local DT = 1 / Config.PHYSICS_HZ
local player = Players.LocalPlayer

-- ---------------------------------------------------------------- world
local bikesFolder = workspace:FindFirstChild("RobikesBikes")
if not bikesFolder then
	bikesFolder = Instance.new("Folder")
	bikesFolder.Name = "RobikesBikes"
	bikesFolder.Parent = workspace
end

local track = workspace:WaitForChild("RobikesTrack", 15)
local startPart = track and track:FindFirstChild("Start")
local spawnCF = startPart and (CFrame.new(startPart.Position / S) * startPart.CFrame.Rotation) or CFrame.new(0, 0, 0)

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { bikesFolder }
rayParams.IgnoreWater = true

-- physics world query (metres in, metres out)
local function ground(origin, dir, len)
	local res = workspace:Raycast(origin * S, dir * (len * S), rayParams)
	if not res then
		return nil
	end
	return res.Distance / S, res.Normal, Config.surfaceFromMaterial(res.Material.Name)
end

-- ---------------------------------------------------------------- local bike
local bikeId = Config.DEFAULT_BIKE
local setup = Config.setupDefaults(bikeId)
spawnCF = BikePhysics.snapToGround(spawnCF, ground) -- terrain is voxel-quantised: find the real surface
local sim = BikePhysics.new(bikeId, spawnCF, { setup = setup })
_G.RobikesDebug = { sim = function() return sim end } -- dev aid: lets tools read the live sim state
local renderer = BikeRenderer.new(sim.bike, bikesFolder, "LocalBike_" .. player.UserId)
local controller = BikeController.new()
local cam = Camera.new()
local hud

local function applySetup(key, delta)
	local _, limits = Config.setupDefaults(bikeId)
	local lim = limits[key]
	if not lim then
		return
	end
	setup[key] = math.clamp((setup[key] or 0) + delta, lim[1], lim[2])
	sim:applySetup(setup)
	hud:setSetupValues(Config.describeSetup(bikeId, setup))
end

hud = HUD.new(controller, { onSetup = applySetup })
hud:setSetupValues(Config.describeSetup(bikeId, setup))
hud:message("ROBIKES — press H for controls", 4)

local function switchBike(id)
	if id == bikeId then
		return
	end
	bikeId = id
	setup = Config.setupDefaults(bikeId)
	sim:setBike(bikeId, setup)
	renderer:destroy()
	renderer = BikeRenderer.new(sim.bike, bikesFolder, "LocalBike_" .. player.UserId)
	hud:setSetupValues(Config.describeSetup(bikeId, setup))
	hud:message(sim.bike.name, 2)
end

-- ---------------------------------------------------------------- network
local net = Robikes:WaitForChild("Net", 10)
local stateEvent = net and net:WaitForChild("BikeState", 10)
local leftEvent = net and net:WaitForChild("BikeLeft", 10)
local remotes = {} -- userId -> { renderer, prev, target, t }
local sendTimer = 0

if stateEvent then
	stateEvent.OnClientEvent:Connect(function(userId, packet)
		if userId == player.UserId or type(packet) ~= "table" then
			return
		end
		local r = remotes[userId]
		if not r or r.bikeId ~= packet.bikeId then
			if r then
				r.renderer:destroy()
			end
			local spec = Config.buildBike(packet.bikeId or Config.DEFAULT_BIKE)
			r = { renderer = BikeRenderer.new(spec, bikesFolder, "RemoteBike_" .. userId), bikeId = packet.bikeId }
			remotes[userId] = r
		end
		r.prev = r.target or packet
		r.target = packet
		r.t = 0
	end)
end
if leftEvent then
	leftEvent.OnClientEvent:Connect(function(userId)
		local r = remotes[userId]
		if r then
			r.renderer:destroy()
			remotes[userId] = nil
		end
	end)
end

local function packState(rs)
	return {
		bikeId = rs.bikeId, cf = rs.cf, steer = rs.steer, riderLat = rs.riderLat, riderLong = rs.riderLong,
		crashed = rs.crashed, riderCF = rs.riderCF,
		w = { rs.wheels[1].ext, rs.wheels[1].angle, rs.wheels[2].ext, rs.wheels[2].angle },
	}
end

local function unpackState(p, alphaPrev, a)
	local function lerpN(x, y)
		return x + (y - x) * a
	end
	local prev = alphaPrev
	return {
		cf = prev.cf:Lerp(p.cf, a),
		steer = lerpN(prev.steer or 0, p.steer or 0),
		riderLat = lerpN(prev.riderLat or 0, p.riderLat or 0),
		riderLong = lerpN(prev.riderLong or 0, p.riderLong or 0),
		crashed = p.crashed,
		riderCF = p.riderCF,
		wheels = { { ext = p.w[1], angle = p.w[2] }, { ext = p.w[3], angle = p.w[4] } },
	}
end

-- ---------------------------------------------------------------- main loop
local acc = 0
local renderState = { wheels = { {}, {} } }
local assistLevels = { 0, 0.3, 0.6, 1.0 }

RunService:BindToRenderStep("Robikes", Enum.RenderPriority.Camera.Value - 1, function(frameDt)
	frameDt = math.min(frameDt, 0.1)

	-- edge events
	local c = controller
	if c:consume("respawn") then
		sim:respawn(ground)
	end
	if c:consume("camera") then
		cam:cycle()
	end
	if c:consume("help") then
		hud:toggleHelp()
	end
	if c:consume("setup") then
		hud:toggleSetup()
	end
	if c:consume("toggleAutoShift") then
		sim.assists.autoShift = not sim.assists.autoShift
	end
	if c:consume("toggleAutoClutch") then
		sim.assists.autoClutch = not sim.assists.autoClutch
	end
	if c:consume("toggleAntiWheelie") then
		sim.assists.antiWheelie = not sim.assists.antiWheelie
	end
	if c:consume("cycleAssist") then
		local cur = sim.assists.balanceAssist
		local nextLevel = assistLevels[1]
		for i, lv in ipairs(assistLevels) do
			if math.abs(lv - cur) < 0.01 then
				nextLevel = assistLevels[i % #assistLevels + 1]
			end
		end
		sim.assists.balanceAssist = nextLevel
	end
	for i, id in ipairs(Config.BIKE_ORDER) do
		if c:consume("bike" .. i) then
			switchBike(id)
		end
	end

	-- physics: fixed steps
	local input = c:update(frameDt)
	local up, down = c:consume("shiftUp"), c:consume("shiftDown")
	acc += frameDt
	local steps = 0
	while acc >= DT and steps < Config.MAX_SUBSTEPS do
		input.shiftUp = up and steps == 0
		input.shiftDown = down and steps == 0
		sim:step(DT, input, ground)
		acc -= DT
		steps += 1
	end
	if steps >= Config.MAX_SUBSTEPS then
		acc = 0
	end

	-- render, camera, HUD
	local rs = sim:getRenderState(renderState)
	renderer:update(rs)
	local bikeCF = CFrame.new(rs.cf.Position * S) * rs.cf.Rotation
	cam:update(frameDt, bikeCF, renderer:helmetCFrame(rs), sim.telemetry.speed)
	hud:update(sim.telemetry, sim.bike, sim.assists)

	-- remote bikes: interpolate between the last two packets (~15 Hz)
	for _, r in pairs(remotes) do
		if r.target then
			r.t = math.min(1, (r.t or 0) + frameDt * 15)
			r.renderer:update(unpackState(r.target, r.prev or r.target, r.t))
		end
	end

	-- replicate ~15 Hz
	sendTimer += frameDt
	if stateEvent and sendTimer >= 1 / 15 then
		sendTimer = 0
		stateEvent:FireServer(packState(rs))
	end
end)
