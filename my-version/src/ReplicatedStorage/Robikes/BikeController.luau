--!nonstrict
--[[
	BikeController — turns keyboard / gamepad / touch into the physics input table (client only).

	Keyboard (also shown in the HUD help, key H):
	  W throttle · S brakes (front+rear) · LeftShift rear brake only · Space clutch
	  A / D steer (lean request) · Q / E shift down / up
	  Arrow Up / Down rider forward / back · Arrow Left / Right rider lean
	  R respawn · C camera · T auto-shift · Y auto-clutch · G balance assist · M anti-wheelie
	  P setup panel · H help · 1–5 choose bike
	Gamepad: RT throttle · LT front brake · LB rear brake · A clutch · left stick steer · right stick rider
	         X / Y shift down / up · Select respawn · D-pad up camera
	Touch: on-screen pads created by the HUD write into controller.touch.
]]

local UserInputService = game:GetService("UserInputService")

local BikeController = {}
BikeController.__index = BikeController

local K = Enum.KeyCode

local function approach(cur, target, upRate, downRate, dt)
	local rate = (math.abs(target) > math.abs(cur)) and upRate or downRate
	if cur < target then
		return math.min(target, cur + rate * dt)
	end
	return math.max(target, cur - rate * dt)
end

function BikeController.new()
	local self = setmetatable({}, BikeController)
	self.down = {}
	self.state = { throttle = 0, frontBrake = 0, rearBrake = 0, clutch = 0, steer = 0, riderLean = 0, riderPitch = 0 }
	self.pad = { throttle = 0, frontBrake = 0, rearBrake = 0, clutch = 0, steer = 0, leanX = 0, leanY = 0 }
	self.touch = { throttle = 0, brake = 0, steer = 0, riderPitch = 0, active = false }
	self.events = {}
	self.connections = {}

	local edgeKeys = {
		[K.Q] = "shiftDown", [K.E] = "shiftUp", [K.ButtonX] = "shiftDown", [K.ButtonY] = "shiftUp",
		[K.R] = "respawn", [K.ButtonSelect] = "respawn", [K.C] = "camera", [K.DPadUp] = "camera",
		[K.T] = "toggleAutoShift", [K.Y] = "toggleAutoClutch", [K.G] = "cycleAssist", [K.M] = "toggleAntiWheelie",
		[K.P] = "setup", [K.H] = "help",
		[K.One] = "bike1", [K.Two] = "bike2", [K.Three] = "bike3", [K.Four] = "bike4", [K.Five] = "bike5",
	}

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(io, processed)
		if processed then
			return
		end
		if io.KeyCode ~= K.Unknown then
			self.down[io.KeyCode] = true
			local ev = edgeKeys[io.KeyCode]
			if ev then
				self.events[ev] = true
			end
		end
	end))
	table.insert(self.connections, UserInputService.InputEnded:Connect(function(io)
		if io.KeyCode ~= K.Unknown then
			self.down[io.KeyCode] = false
		end
	end))
	table.insert(self.connections, UserInputService.InputChanged:Connect(function(io)
		local kc = io.KeyCode
		if kc == K.ButtonR2 then
			self.pad.throttle = io.Position.Z
		elseif kc == K.ButtonL2 then
			self.pad.frontBrake = io.Position.Z
		elseif kc == K.Thumbstick1 then
			self.pad.steer = math.abs(io.Position.X) > 0.12 and io.Position.X or 0
		elseif kc == K.Thumbstick2 then
			self.pad.leanX = math.abs(io.Position.X) > 0.15 and io.Position.X or 0
			self.pad.leanY = math.abs(io.Position.Y) > 0.15 and io.Position.Y or 0
		end
	end))
	return self
end

-- Edge events (shift, toggles, …) are consumed once.
function BikeController:consume(name)
	local v = self.events[name]
	self.events[name] = nil
	return v == true
end

function BikeController:isDown(kc)
	return self.down[kc] == true
end

-- Returns the analog input table for this frame (physics consumes shift edges separately).
function BikeController:update(dt)
	local d = self.down
	local s = self.state
	local function key(k)
		return d[k] and 1 or 0
	end

	-- keyboard targets
	local kThrottle = key(K.W)
	local kBrake = key(K.S)
	local kRear = math.max(kBrake, key(K.LeftShift))
	local kSteer = key(K.D) - key(K.A)
	local kLean = key(K.Right) - key(K.Left)
	local kPitch = key(K.Up) - key(K.Down)
	local kClutch = key(K.Space)

	-- smooth digital keys like a thumb on a stick
	s.throttle = approach(s.throttle, kThrottle, 6, 10, dt)
	s.frontBrake = approach(s.frontBrake, kBrake, 6, 12, dt)
	s.rearBrake = approach(s.rearBrake, kRear, 6, 12, dt)
	s.steer = approach(s.steer, kSteer, 3.5, 6, dt)
	s.riderLean = approach(s.riderLean, kLean, 4, 6, dt)
	s.riderPitch = approach(s.riderPitch, kPitch, 4, 6, dt)
	s.clutch = approach(s.clutch, kClutch, 12, 8, dt)

	local t = self.touch
	local p = self.pad
	return {
		throttle = math.max(s.throttle, p.throttle, t.throttle),
		frontBrake = math.max(s.frontBrake, p.frontBrake, t.brake),
		rearBrake = math.max(s.rearBrake, key(K.ButtonL1), t.brake * 0.8),
		clutch = math.max(s.clutch, key(K.ButtonA)),
		steer = math.clamp(s.steer + p.steer + t.steer, -1, 1),
		riderLean = math.clamp(s.riderLean + p.leanX, -1, 1),
		riderPitch = math.clamp(s.riderPitch + p.leanY + t.riderPitch, -1, 1),
		shiftUp = false,
		shiftDown = false,
		start = false,
	}
end

function BikeController:destroy()
	for _, c in ipairs(self.connections) do
		c:Disconnect()
	end
end

return BikeController
