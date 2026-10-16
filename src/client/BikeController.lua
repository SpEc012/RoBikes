--[[
	BikeController  —  turns player input into a control table the physics reads each step.
	PC (keyboard) + mobile (on-screen buttons via ContextActionService).
	Returns a module with :getControls() -> table and gear-shift events.
]]

local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("RobikesShared"):WaitForChild("RobikesConfig"))

local Controller = {}
Controller.__index = Controller

function Controller.new()
	local self = setmetatable({}, Controller)
	self.controls = {
		throttle = 0, brakeFront = 0, brakeRear = 0,
		steer = 0,            -- -1..1
		lean = 0,             -- -1 (back) .. 1 (forward)
		clutch = 0,           -- 0 engaged .. 1 fully pulled
	}
	self.shiftUpQueued = false
	self.shiftDownQueued = false
	self.resetQueued = false
	self._mobile = {}
	self:_bind()
	return self
end

function Controller:_bind()
	-- Keyboard shift/reset edges
	UserInputService.InputBegan:Connect(function(input, gp)
		if gp then return end
		local k = input.KeyCode
		if k == Config.Keys.shiftUp then self.shiftUpQueued = true end
		if k == Config.Keys.shiftDown then self.shiftDownQueued = true end
		if k == Config.Keys.resetBike then self.resetQueued = true end
	end)

	-- Mobile touch buttons (only created on touch devices)
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		local function mk(name, title, pos, onDown, onUp)
			ContextActionService:BindAction(name, function(_, state)
				if state == Enum.UserInputState.Begin then onDown()
				elseif state == Enum.UserInputState.End then onUp() end
			end, true)
			ContextActionService:SetTitle(name, title)
			ContextActionService:SetPosition(name, pos)
		end
		mk("Throttle","GAS", UDim2.new(1,-100,1,-120), function() self._mobile.throttle=1 end, function() self._mobile.throttle=0 end)
		mk("Brake","BRK", UDim2.new(1,-100,1,-230), function() self._mobile.brake=1 end, function() self._mobile.brake=0 end)
		mk("Left","<", UDim2.new(0,20,1,-120), function() self._mobile.steerL=1 end, function() self._mobile.steerL=0 end)
		mk("Right",">", UDim2.new(0,150,1,-120), function() self._mobile.steerR=1 end, function() self._mobile.steerR=0 end)
		mk("ShiftUp","+", UDim2.new(0,150,1,-230), function() self.shiftUpQueued=true end, function() end)
		mk("ShiftDn","-", UDim2.new(0,20,1,-230), function() self.shiftDownQueued=true end, function() end)
	end
end

local function key(k) return UserInputService:IsKeyDown(k) and 1 or 0 end

-- Smoothly move a value toward target (so throttle/steer aren't binary).
local function approach(cur, target, rate, dt)
	local d = target - cur
	local step = rate * dt
	if math.abs(d) <= step then return target end
	return cur + (d > 0 and step or -step)
end

function Controller:update(dt)
	local c = self.controls
	local m = self._mobile

	local thrTarget  = math.max(key(Config.Keys.throttle), m.throttle or 0)
	local brkTarget  = math.max(key(Config.Keys.brakeRear), m.brake or 0)
	local frontBrake = key(Config.Keys.brakeFront)
	local steerT = (math.max(key(Config.Keys.steerRight), m.steerR or 0))
	             - (math.max(key(Config.Keys.steerLeft),  m.steerL or 0))
	local leanT  = key(Config.Keys.leanFwd) - key(Config.Keys.leanBack)

	c.throttle   = approach(c.throttle, thrTarget, 4, dt)
	c.brakeRear  = approach(c.brakeRear, brkTarget, 6, dt)
	c.brakeFront = approach(c.brakeFront, frontBrake, 6, dt)
	c.steer      = approach(c.steer, steerT, 6, dt)
	c.lean       = approach(c.lean, leanT, 3, dt)
	c.clutch     = key(Config.Keys.clutch)
	return c
end

-- Consume a queued shift (returns -1, 0, +1).
function Controller:takeShift()
	if self.shiftUpQueued then self.shiftUpQueued = false; return 1 end
	if self.shiftDownQueued then self.shiftDownQueued = false; return -1 end
	return 0
end

function Controller:takeReset()
	if self.resetQueued then self.resetQueued = false; return true end
	return false
end

return Controller
