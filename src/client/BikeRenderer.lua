--[[
	BikeRenderer  —  builds a placeholder bike (so the project runs with no art) and
	positions wheels / rider each frame. Swap the parts for real meshes later.
	All sizes in studs (= metres * STUDS_PER_METRE).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RobikesShared"):WaitForChild("RobikesConfig"))
local S = Config.STUDS_PER_METRE

local BikeRenderer = {}
BikeRenderer.__index = BikeRenderer

local function part(parent, size, color, shape)
	local p = Instance.new("Part")
	p.Size = size
	p.Color = color
	p.Anchored = true
	p.CanCollide = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then p.Shape = shape end
	p.Parent = parent
	return p
end

-- Build a Model with PrimaryPart = Chassis for the given bike spec.
function BikeRenderer.build(spec)
	local model = Instance.new("Model")
	model.Name = "Robike"

	local chassis = part(model, Vector3.new(0.25*S, 0.5*S, spec.wheelbase*0.6*S), Color3.fromRGB(230,80,40))
	chassis.Name = "Chassis"
	model.PrimaryPart = chassis

	local rider = part(model, Vector3.new(0.4*S, 0.8*S, 0.3*S), Color3.fromRGB(40,40,50))
	rider.Name = "Rider"

	local function wheel(name, radius)
		local w = part(model, Vector3.new(0.12*S, radius*2*S, radius*2*S), Color3.fromRGB(20,20,20), Enum.PartType.Cylinder)
		w.Name = name
		return w
	end
	local fw = wheel("FrontWheel", spec and Config.Tyres[spec.tyre].radiusF or 0.33)
	local rw = wheel("RearWheel",  spec and Config.Tyres[spec.tyre].radiusR or 0.33)

	local self = setmetatable({
		model = model, chassis = chassis, rider = rider,
		frontWheel = fw, rearWheel = rw, spec = spec,
		frontR = Config.Tyres[spec.tyre].radiusF, rearR = Config.Tyres[spec.tyre].radiusR,
		spin = 0,
	}, BikeRenderer)
	return self
end

-- chassisCF: the world CFrame the physics produced. Call after model:PivotTo(chassisCF).
function BikeRenderer:update(chassisCF, speed, steerAngle, lean, dt)
	local spec = self.spec
	local halfWB = spec.wheelbase * 0.5 * S
	local drop   = spec.comHeight * S
	self.spin = self.spin + (speed / math.max(self.rearR, 0.1)) * dt

	-- Cylinder's circular face is along local X; spin about X, orient axle along chassis right.
	local axle = CFrame.Angles(0, math.rad(90), 0) -- point cylinder length along X -> axle sideways
	local spinCF = CFrame.Angles(self.spin, 0, 0)

	local frontLocal = CFrame.new(0, -drop, -halfWB) * CFrame.Angles(0, steerAngle, 0) * axle * spinCF
	local rearLocal  = CFrame.new(0, -drop,  halfWB) * axle * spinCF
	self.frontWheel.CFrame = chassisCF * frontLocal
	self.rearWheel.CFrame  = chassisCF * rearLocal

	self.rider.CFrame = chassisCF * CFrame.new(0, 0.45*S, (lean or 0) * 0.3 * S)
end

return BikeRenderer
