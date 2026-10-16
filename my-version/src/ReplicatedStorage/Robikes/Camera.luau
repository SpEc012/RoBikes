--!nonstrict
--[[
	Camera — spring-smoothed chase camera + helmet camera (client only). Toggle with C / D-pad up.
	Works in studs (it only reads rendered CFrames).
]]

local Config = require(script.Parent.RobikesConfig)

local Camera = {}
Camera.__index = Camera

local S = Config.STUDS_PER_METER
local MODES = { "chase", "far", "helmet" }

function Camera.new()
	local self = setmetatable({}, Camera)
	self.cam = workspace.CurrentCamera
	self.cam.CameraType = Enum.CameraType.Scriptable
	self.modeIndex = 1
	self.pos = nil
	self.vel = Vector3.zero
	self.look = nil
	self.heading = nil
	return self
end

function Camera:cycle()
	self.modeIndex = self.modeIndex % #MODES + 1
	self.pos = nil
end

function Camera:mode()
	return MODES[self.modeIndex]
end

-- bikeCF: rendered bike CFrame (studs). helmetCF: rider head CFrame (studs). dt: frame time.
function Camera:update(dt, bikeCF, helmetCF, speed)
	local cam = self.cam
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end
	local mode = MODES[self.modeIndex]
	if mode == "helmet" then
		-- follow the head, keep half of the bike's roll so the horizon stays readable
		local look = helmetCF.LookVector
		local up = Vector3.yAxis:Lerp(helmetCF.UpVector, 0.5).Unit
		cam.CFrame = CFrame.lookAt(helmetCF.Position, helmetCF.Position + look * 10, up)
		cam.FieldOfView = 85
		return
	end

	-- chase: heading follows the bike's flat forward direction with a little lag
	local fwd = bikeCF.LookVector
	local flat = Vector3.new(fwd.X, 0, fwd.Z)
	if flat.Magnitude < 1e-3 then
		flat = self.heading or Vector3.new(0, 0, -1)
	end
	flat = flat.Unit
	self.heading = self.heading and self.heading:Lerp(flat, math.clamp(dt * 4, 0, 1)).Unit or flat

	local dist = (mode == "far") and 7.5 or 4.6
	local height = (mode == "far") and 2.6 or 1.7
	local target = bikeCF.Position + Vector3.new(0, 0.6 * S, 0)
	local desired = target - self.heading * (dist * S) + Vector3.new(0, height * S, 0)

	-- critically damped spring toward the desired point
	if not self.pos then
		self.pos = desired
		self.vel = Vector3.zero
	end
	local omega = 6
	local x = self.pos - desired
	local accel = -omega * omega * x - 2 * omega * self.vel
	self.vel += accel * dt
	self.pos += self.vel * dt

	local lookAt = target + self.heading * (1.5 * S)
	cam.CFrame = CFrame.lookAt(self.pos, lookAt)
	cam.FieldOfView = 70 + math.clamp((speed or 0) * 0.35, 0, 12) -- slight speed FOV kick
end

return Camera
