--!nonstrict
--[[
	HUD — speed, gear, RPM bar with redline, lean meter, assists, crash banner, help (H), setup panel (P),
	and touch controls on mobile. Pure UI: reads telemetry, writes nothing into physics directly
	(setup changes go through the onSetup callback).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local HUD = {}
HUD.__index = HUD

local FONT = Enum.Font.GothamBold
local FONT_REG = Enum.Font.Gotham
local BG = Color3.fromRGB(16, 18, 22)
local FG = Color3.fromRGB(240, 240, 240)
local ACCENT = Color3.fromRGB(255, 140, 30)
local RED = Color3.fromRGB(230, 50, 45)

local function make(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	o.Parent = parent
	return o
end

local function corner(parent, r)
	make("UICorner", { CornerRadius = UDim.new(0, r or 8) }, parent)
end

local function label(parent, text, size, pos, textSize, font, align)
	return make("TextLabel", {
		BackgroundTransparency = 1, Text = text, Size = size, Position = pos, TextColor3 = FG,
		Font = font or FONT, TextSize = textSize or 18, TextXAlignment = align or Enum.TextXAlignment.Center,
	}, parent)
end

local HELP_TEXT = [[
ROBIKES CONTROLS
W  throttle          S  brakes          Left Shift  rear brake only
A / D  steer (lean the bike)            Space  clutch
Q / E  shift down / up                  Arrows  rider weight (fwd/back, left/right)
R  respawn    C  camera    1-5  bike    P  setup    H  this help
T  auto-shift   Y  auto-clutch   G  balance assist   M  anti-wheelie

Tips: lean forward (Up) under power to keep the front down, lean back (Down) for wheelies.
In the air: Up/Down pitch the bike, tap the rear brake to drop the nose, throttle lifts it.]]

function HUD.new(controller, callbacks)
	local self = setmetatable({}, HUD)
	self.controller = controller
	self.callbacks = callbacks or {}
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = make("ScreenGui", { Name = "RobikesHUD", ResetOnSpawn = false, IgnoreGuiInset = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, pg)
	self.gui = gui
	local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	self.touch = touch

	-- ---------------- dash (bottom-right; top-right on touch) ----------------
	local dash = make("Frame", {
		Name = "Dash", BackgroundColor3 = BG, BackgroundTransparency = 0.25, Size = UDim2.fromOffset(300, 140),
		AnchorPoint = touch and Vector2.new(1, 0) or Vector2.new(1, 1),
		Position = touch and UDim2.new(1, -12, 0, 12) or UDim2.new(1, -16, 1, -16),
	}, gui)
	corner(dash, 12)
	self.speed = label(dash, "0", UDim2.fromOffset(150, 64), UDim2.fromOffset(10, 4), 56)
	self.speed.TextXAlignment = Enum.TextXAlignment.Left
	label(dash, "km/h", UDim2.fromOffset(60, 20), UDim2.fromOffset(12, 62), 16, FONT_REG, Enum.TextXAlignment.Left)
	self.gear = label(dash, "1", UDim2.fromOffset(80, 80), UDim2.fromOffset(210, 0), 72)
	self.gear.TextColor3 = ACCENT
	local bar = make("Frame", { BackgroundColor3 = Color3.fromRGB(45, 48, 55), Size = UDim2.fromOffset(280, 16), Position = UDim2.fromOffset(10, 88), BorderSizePixel = 0 }, dash)
	corner(bar, 4)
	self.redzone = make("Frame", { BackgroundColor3 = RED, BackgroundTransparency = 0.45, BorderSizePixel = 0, Size = UDim2.fromScale(0.1, 1) }, bar)
	self.rpmFill = make("Frame", { BackgroundColor3 = ACCENT, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1) }, bar)
	corner(self.rpmFill, 4)
	self.rpmText = label(dash, "0 rpm", UDim2.fromOffset(140, 18), UDim2.fromOffset(10, 108), 15, FONT_REG, Enum.TextXAlignment.Left)
	self.lean = label(dash, "lean 0°", UDim2.fromOffset(140, 18), UDim2.fromOffset(150, 108), 15, FONT_REG, Enum.TextXAlignment.Right)

	-- lean meter arc substitute: a needle on a horizontal scale
	local leanBar = make("Frame", { BackgroundColor3 = Color3.fromRGB(45, 48, 55), BorderSizePixel = 0, Size = UDim2.fromOffset(280, 4), Position = UDim2.fromOffset(10, 130) }, dash)
	self.leanNeedle = make("Frame", { BackgroundColor3 = FG, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 10), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) }, leanBar)

	-- ---------------- top-left: bike + assists ----------------
	local info = make("Frame", { BackgroundColor3 = BG, BackgroundTransparency = 0.35, Size = UDim2.fromOffset(330, 54), Position = UDim2.fromOffset(12, 12) }, gui)
	corner(info, 10)
	self.bikeName = label(info, "", UDim2.fromOffset(310, 24), UDim2.fromOffset(10, 2), 18, FONT, Enum.TextXAlignment.Left)
	self.assists = label(info, "", UDim2.fromOffset(310, 22), UDim2.fromOffset(10, 28), 14, FONT_REG, Enum.TextXAlignment.Left)

	-- ---------------- banner ----------------
	self.banner = label(gui, "", UDim2.fromOffset(600, 50), UDim2.new(0.5, -300, 0.18, 0), 34)
	self.banner.TextStrokeTransparency = 0.4
	self.bannerUntil = 0

	-- ---------------- help ----------------
	local help = make("TextLabel", {
		BackgroundColor3 = BG, BackgroundTransparency = 0.15, Size = UDim2.fromOffset(640, 230), AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5), Text = HELP_TEXT, TextColor3 = FG, Font = Enum.Font.Code, TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Visible = not touch,
	}, gui)
	corner(help, 12)
	make("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingTop = UDim.new(0, 12) }, help)
	self.help = help
	self.helpAutoHide = os.clock() + 8

	-- ---------------- setup panel ----------------
	self:buildSetup()

	if touch then
		self:buildTouch()
	end
	return self
end

function HUD:buildSetup()
	local panel = make("Frame", { Name = "Setup", BackgroundColor3 = BG, BackgroundTransparency = 0.1, Size = UDim2.fromOffset(330, 300), Position = UDim2.fromOffset(12, 74), Visible = false }, self.gui)
	corner(panel, 10)
	label(panel, "SETUP  (P to close)", UDim2.fromOffset(310, 26), UDim2.fromOffset(10, 4), 18, FONT, Enum.TextXAlignment.Left)
	self.setupPanel = panel
	self.setupRows = {}
	local rows = {
		{ key = "FSprocketSetting", name = "Front sprocket" },
		{ key = "RSprocketSetting", name = "Rear sprocket" },
		{ key = "forkSpring", name = "Fork spring" },
		{ key = "shockSpring", name = "Shock spring" },
		{ key = "forkBump", name = "Fork compression" },
		{ key = "shockBump", name = "Shock compression" },
		{ key = "forkRebound", name = "Fork rebound" },
		{ key = "shockRebound", name = "Shock rebound" },
	}
	for i, r in ipairs(rows) do
		local y = 30 + (i - 1) * 32
		label(panel, r.name, UDim2.fromOffset(150, 28), UDim2.fromOffset(10, y), 15, FONT_REG, Enum.TextXAlignment.Left)
		local val = label(panel, "-", UDim2.fromOffset(90, 28), UDim2.fromOffset(190, y), 15, FONT)
		local minus = make("TextButton", { Text = "-", Size = UDim2.fromOffset(28, 26), Position = UDim2.fromOffset(160, y + 1), BackgroundColor3 = Color3.fromRGB(60, 62, 70), TextColor3 = FG, Font = FONT, TextSize = 18 }, panel)
		local plus = make("TextButton", { Text = "+", Size = UDim2.fromOffset(28, 26), Position = UDim2.fromOffset(284, y + 1), BackgroundColor3 = Color3.fromRGB(60, 62, 70), TextColor3 = FG, Font = FONT, TextSize = 18 }, panel)
		corner(minus, 6)
		corner(plus, 6)
		minus.Activated:Connect(function()
			if self.callbacks.onSetup then
				self.callbacks.onSetup(r.key, -1)
			end
		end)
		plus.Activated:Connect(function()
			if self.callbacks.onSetup then
				self.callbacks.onSetup(r.key, 1)
			end
		end)
		self.setupRows[r.key] = val
	end
end

function HUD:setSetupValues(values)
	for k, lbl in pairs(self.setupRows) do
		lbl.Text = values[k] and tostring(values[k]) or "-"
	end
end

function HUD:buildTouch()
	local c = self.controller.touch
	local gui = self.gui
	local function holdButton(text, pos, size, color, onDown, onUp)
		local b = make("TextButton", { Text = text, Position = pos, Size = size, BackgroundColor3 = color, BackgroundTransparency = 0.25, TextColor3 = FG, Font = FONT, TextSize = 22, AutoButtonColor = false }, gui)
		corner(b, 14)
		b.InputBegan:Connect(function(io)
			if io.UserInputType == Enum.UserInputType.Touch or io.UserInputType == Enum.UserInputType.MouseButton1 then
				onDown()
			end
		end)
		b.InputEnded:Connect(function(io)
			if io.UserInputType == Enum.UserInputType.Touch or io.UserInputType == Enum.UserInputType.MouseButton1 then
				onUp()
			end
		end)
		return b
	end
	holdButton("GAS", UDim2.new(1, -150, 1, -170), UDim2.fromOffset(130, 150), Color3.fromRGB(40, 150, 60), function() c.throttle = 1 end, function() c.throttle = 0 end)
	holdButton("BRAKE", UDim2.new(1, -290, 1, -130), UDim2.fromOffset(120, 110), RED, function() c.brake = 1 end, function() c.brake = 0 end)
	holdButton("▲", UDim2.new(1, -150, 1, -250), UDim2.fromOffset(62, 66), Color3.fromRGB(60, 62, 70), function() self.controller.events.shiftUp = true end, function() end)
	holdButton("▼", UDim2.new(1, -82, 1, -250), UDim2.fromOffset(62, 66), Color3.fromRGB(60, 62, 70), function() self.controller.events.shiftDown = true end, function() end)
	holdButton("FWD", UDim2.new(0, 20, 1, -300), UDim2.fromOffset(80, 60), Color3.fromRGB(60, 62, 70), function() c.riderPitch = 1 end, function() c.riderPitch = 0 end)
	holdButton("BACK", UDim2.new(0, 110, 1, -300), UDim2.fromOffset(80, 60), Color3.fromRGB(60, 62, 70), function() c.riderPitch = -1 end, function() c.riderPitch = 0 end)
	holdButton("RESET", UDim2.new(0, 20, 0, 80), UDim2.fromOffset(90, 44), Color3.fromRGB(60, 62, 70), function() self.controller.events.respawn = true end, function() end)
	holdButton("CAM", UDim2.new(0, 120, 0, 80), UDim2.fromOffset(70, 44), Color3.fromRGB(60, 62, 70), function() self.controller.events.camera = true end, function() end)

	-- steer pad: drag left/right
	local pad = make("Frame", { BackgroundColor3 = Color3.fromRGB(60, 62, 70), BackgroundTransparency = 0.5, Position = UDim2.new(0, 20, 1, -210), Size = UDim2.fromOffset(260, 190) }, gui)
	corner(pad, 16)
	label(pad, "◀  STEER  ▶", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), 20)
	local active, startX = nil, 0
	pad.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.Touch then
			active, startX = io, io.Position.X
		end
	end)
	UserInputService.TouchMoved:Connect(function(io)
		if active and io == active then
			c.steer = math.clamp((io.Position.X - startX) / 90, -1, 1)
		end
	end)
	UserInputService.TouchEnded:Connect(function(io)
		if active and io == active then
			active, c.steer = nil, 0
		end
	end)
end

function HUD:toggleHelp()
	self.help.Visible = not self.help.Visible
	self.helpAutoHide = math.huge
end

function HUD:toggleSetup()
	self.setupPanel.Visible = not self.setupPanel.Visible
end

function HUD:message(text, seconds)
	self.banner.Text = text
	self.bannerUntil = os.clock() + (seconds or 2)
end

function HUD:update(t, bike, assists)
	self.speed.Text = string.format("%d", math.floor(math.abs(t.speedometer or 0) * 3.6 + 0.5))
	self.gear.Text = (t.gear == 0) and "N" or tostring(t.gear)
	local maxR = bike.engine.limiterRPM * 1.08
	local frac = math.clamp((t.rpm or 0) / maxR, 0, 1)
	self.rpmFill.Size = UDim2.fromScale(frac, 1)
	local redStart = math.clamp(bike.engine.shiftRPM / maxR, 0, 1)
	self.redzone.Position = UDim2.fromScale(redStart, 0)
	self.redzone.Size = UDim2.fromScale(1 - redStart, 1)
	self.rpmFill.BackgroundColor3 = ((t.rpm or 0) >= bike.engine.shiftRPM) and RED or ACCENT
	self.rpmText.Text = string.format("%d rpm%s", math.floor((t.rpm or 0) / 10) * 10, t.running and "" or "  (stalled)")
	local roll = t.roll or 0
	self.lean.Text = string.format("lean %d° %s", math.floor(math.abs(roll) + 0.5), roll > 1 and "R" or (roll < -1 and "L" or ""))
	self.leanNeedle.Position = UDim2.fromScale(0.5 + math.clamp(roll / 120, -0.5, 0.5), 0.5)
	self.bikeName.Text = bike.name
	self.assists.Text = string.format("auto-shift %s · auto-clutch %s · balance %d%% · anti-wheelie %s",
		assists.autoShift and "ON" or "off", assists.autoClutch and "ON" or "off",
		math.floor((assists.balanceAssist or 0) * 100 + 0.5), assists.antiWheelie and "ON" or "off")
	if t.crashed then
		self.banner.Text = "CRASHED — respawning"
		self.banner.TextColor3 = RED
	elseif os.clock() > self.bannerUntil then
		self.banner.Text = ""
		self.banner.TextColor3 = FG
	end
	if os.clock() > self.helpAutoHide then
		self.help.Visible = false
		self.helpAutoHide = math.huge
	end
end

return HUD
