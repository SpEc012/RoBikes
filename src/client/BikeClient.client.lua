--[[
	BikeClient  —  LocalScript bootstrap. Spawns one bike for the local player, runs the
	fixed-step physics, drives a chase camera + HUD. Client-authoritative (replicate CFrame
	to the server later for multiplayer).
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local here = script.Parent
local Config        = require(ReplicatedStorage:WaitForChild("RobikesShared"):WaitForChild("RobikesConfig"))
local BikePhysics   = require(here:WaitForChild("BikePhysics"))
local BikeController = require(here:WaitForChild("BikeController"))
local BikeRenderer  = require(here:WaitForChild("BikeRenderer"))

local BIKE_ID = "450xf"
local STEP = 1 / Config.STEP_HZ

-- Spawn above the baseplate (studs).
local spawnCF = CFrame.new(0, 6, 0)

local spec = Config.Bikes[BIKE_ID]
local renderer = BikeRenderer.build(spec)
renderer.model.Parent = Workspace
renderer.model:PivotTo(spawnCF)

local phys = BikePhysics.new(renderer.model, BIKE_ID, spawnCF)
local controller = BikeController.new()

-- Chase camera
local cam = Workspace.CurrentCamera
cam.CameraType = Enum.CameraType.Scriptable

-- Minimal HUD
local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
local gui = Instance.new("ScreenGui"); gui.Name = "RobikesHUD"; gui.ResetOnSpawn = false; gui.Parent = pg
local label = Instance.new("TextLabel")
label.Size = UDim2.new(0, 260, 0, 70); label.Position = UDim2.new(0, 12, 1, -82)
label.BackgroundTransparency = 0.4; label.BackgroundColor3 = Color3.new(0,0,0)
label.TextColor3 = Color3.new(1,1,1); label.Font = Enum.Font.Code; label.TextSize = 18
label.TextXAlignment = Enum.TextXAlignment.Left; label.Text = ""; label.Parent = gui

local acc = 0
local lastRPM, lastGear, lastSpeed = spec.idleRPM, 1, 0

RunService.Heartbeat:Connect(function(dtFrame)
	local controls = controller:update(dtFrame)

	-- reset
	if controller:takeReset() or phys.crashed and controller.controls.throttle > 0.9 then
		phys:respawn(spawnCF)
	end

	-- fixed-step physics
	acc = acc + math.min(dtFrame, 0.1)
	local shift = controller:takeShift()
	while acc >= STEP do
		lastRPM, lastGear, lastSpeed = phys:step(STEP, controls, shift)
		shift = 0
		acc = acc - STEP
	end

	-- render
	local cf = phys:renderCFrame()
	renderer.model:PivotTo(cf)
	local speed = lastSpeed
	local lockScale = 1 / (1 + speed * 0.12)
	local steerAngle = -controls.steer * math.rad(spec.steerLock) * lockScale
	renderer:update(cf, speed, steerAngle, controls.lean, dtFrame)

	-- chase cam
	local behind = cf.LookVector * -8 + Vector3.new(0, 3.5, 0)
	cam.CFrame = CFrame.lookAt(cf.Position + behind, cf.Position + cf.LookVector * 4)

	label.Text = string.format("GEAR %d   %4.0f rpm\nSPEED %5.1f km/h%s",
		lastGear, lastRPM, speed * Config.STUDS_PER_METRE and speed * 3.6 or 0,
		phys.crashed and "\n[CRASHED - hold W / press R]" or "")
end)
