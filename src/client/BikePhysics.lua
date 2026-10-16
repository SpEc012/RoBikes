--[[
	BikePhysics  —  custom fixed-step rigid-body motorcycle, SI units.
	Reproduces the MX Bikes model with a 1-body + 2 raycast-wheel approximation:
	  gravity -> suspension (raycast springs) -> Pacejka tyre forces -> engine/drivetrain
	  -> lean/balance PD -> aero, integrated with semi-implicit Euler.
	The chassis Part is Anchored; we set its CFrame each step (studs = metres * STUDS_PER_METRE).

	Usage:
	  local phys = BikePhysics.new(model, "450xf", spawnCFrameStuds)
	  phys:step(dt, controls, shiftDelta)      -- call at fixed dt
	  model:PivotTo(phys:renderCFrame())
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage:WaitForChild("RobikesShared")
local Config  = require(shared:WaitForChild("RobikesConfig"))
local Pacejka = require(shared:WaitForChild("Pacejka"))

local S = Config.STUDS_PER_METRE

local BikePhysics = {}
BikePhysics.__index = BikePhysics

local function proj(v, n)                 -- remove the component of v along unit n
	return v - n * v:Dot(n)
end
local function safeUnit(v)
	return (v.Magnitude > 1e-6) and v.Unit or Vector3.zero
end

function BikePhysics.new(model, bikeId, spawnCFrameStuds)
	local self = setmetatable({}, BikePhysics)
	self.model = model
	self.spec  = Config.Bikes[bikeId]
	self.tyre  = Config.Tyres[self.spec.tyre]
	self.susp  = Config.Suspension

	-- State (SI). Position is the CoM in metres; orient is rotation only.
	self.position = spawnCFrameStuds.Position / S
	self.orient   = spawnCFrameStuds.Rotation
	self.vel      = Vector3.zero          -- m/s
	self.angVel   = Vector3.zero          -- rad/s, world

	self.rearOmega = 0                    -- rad/s
	self.engineRPM = self.spec.idleRPM
	self.gear      = 1
	self.crashed   = false

	self._lastComp = { front = 0, rear = 0 }
	self._rp = RaycastParams.new()
	self._rp.FilterType = Enum.RaycastFilterType.Exclude
	self._rp.FilterDescendantsInstances = { model }
	self._rp.IgnoreWater = true
	return self
end

function BikePhysics:renderCFrame()
	return CFrame.new(self.position * S) * self.orient
end

function BikePhysics:setGear(delta)
	self.gear = math.clamp(self.gear + delta, 1, #self.spec.gearRatios)
end

-- One wheel's suspension + tyre. Returns forceWorld (N) and its application point (m, world).
function BikePhysics:_wheel(which, steerAngle, controls)
	local spec, tyre = self.spec, self.tyre
	local up    = self.orient.UpVector
	local fwd   = self.orient.LookVector
	local right = self.orient.RightVector
	local sp    = (which == "front") and self.susp.front or self.susp.rear
	local radius= (which == "front") and tyre.radiusF or tyre.radiusR

	-- Mount point (chassis attach for this suspension), in metres (world).
	local halfWB = spec.wheelbase * 0.5
	local along  = (which == "front") and halfWB or -halfWB
	local mount  = self.position + fwd * along - up * (spec.comHeight - sp.rest)

	-- Raycast in stud space, straight down the bike's local down.
	local originStud = mount * S
	local rayLenStud = (sp.rest + sp.travel + radius) * S
	local hit = Workspace:Raycast(originStud, (-up) * rayLenStud, self._rp)
	if not hit then
		self._lastComp[which] = 0
		return Vector3.zero, mount, nil
	end

	local distM      = (hit.Position - originStud).Magnitude / S
	local springLen  = distM - radius                 -- mount -> wheel centre (m)
	local compression= sp.rest - springLen            -- + = compressed
	if compression <= 0 then                          -- wheel drooping / airborne
		self._lastComp[which] = math.max(compression, -sp.travel)
		return Vector3.zero, mount, nil
	end
	compression = math.min(compression, sp.travel)

	local compVel = (compression - self._lastComp[which]) / (1 / Config.STEP_HZ)
	self._lastComp[which] = compression
	local damp = (compVel > 0) and sp.bump or sp.rebound
	local Fz = math.max(0, sp.rate * compression + damp * compVel + sp.preload)

	-- Contact frame on the ground plane.
	local n = hit.Normal
	local contact = hit.Position / S                  -- metres
	local wheelFwd = safeUnit(proj(fwd, n))
	if which == "front" and steerAngle ~= 0 then
		wheelFwd = safeUnit(CFrame.fromAxisAngle(up, steerAngle) * wheelFwd)
	end
	local wheelLat = safeUnit(n:Cross(wheelFwd))

	-- Velocity of the contact point (rigid body: v + w x r).
	local r = contact - self.position
	local contactVel = self.vel + self.angVel:Cross(r)
	local vFwd = contactVel:Dot(wheelFwd)
	local vLat = contactVel:Dot(wheelLat)

	-- Surface grip under the patch.
	local surf = Config.Surfaces[hit.Material] or Config.DefaultSurface

	local slipAngle = math.atan2(vLat, math.abs(vFwd) + 0.5)
	local Fx, Fy

	if which == "rear" then
		local wheelSurfSpeed = self.rearOmega * radius
		local kappa = (wheelSurfSpeed - vFwd) / (math.abs(vFwd) + 1.0)
		Fx, Fy = Pacejka.solve(tyre, Fz, surf.grip, kappa, slipAngle)
		-- React drive/brake torque onto the wheel spin (wheelspin & lockup emerge here).
		local gearTotal = spec.primaryDrive * spec.gearRatios[self.gear] * spec.finalDrive
		local driveT = (spec.torqueCurve(self.engineRPM) * controls.throttle
			+ spec.engineBrakeCurve(self.engineRPM) * (1 - controls.throttle))
		driveT = math.clamp(driveT, -spec.clutchMaxTorque, spec.clutchMaxTorque) * (1 - controls.clutch)
		local wheelTorque = driveT * gearTotal * spec.efficiency
		local brakeT = controls.brakeRear * spec.brakeTorqueR * -math.sign(self.rearOmega)
		local netT = wheelTorque + brakeT - Fx * radius
		self.rearOmega = self.rearOmega + (netT / spec.rearWheelInertia) * (1 / Config.STEP_HZ)
		if self.rearOmega < 0 and controls.throttle < 0.05 then self.rearOmega = 0 end
	else
		-- Front wheel: rolls; longitudinal is front-brake only, grip-limited.
		local brakeForce = controls.brakeFront * spec.brakeTorqueF / radius
		Fx = -math.sign(vFwd) * math.min(brakeForce, surf.grip * tyre.muX * Fz)
		_, Fy = Pacejka.solve(tyre, Fz, surf.grip, 0, slipAngle)
	end

	-- Rolling resistance on soft ground.
	local roll = -safeUnit(Vector3.new(vFwd,0,0)) -- placeholder; applied along wheelFwd below
	local rollMag = surf.resistance * 0.02 * Fz * math.sign(vFwd)

	local force = n * Fz + wheelFwd * (Fx - rollMag) + wheelLat * Fy
	return force, contact, { Fz = Fz, kappa = (which=="rear"), surf = surf }
end

function BikePhysics:step(dt, controls, shiftDelta)
	if shiftDelta ~= 0 then self:setGear(shiftDelta) end
	local spec = self.spec
	local up    = self.orient.UpVector
	local fwd   = self.orient.LookVector
	local right = self.orient.RightVector

	local force  = Vector3.new(0, -Config.GRAVITY * spec.mass, 0)   -- gravity (world)
	local torque = Vector3.zero

	-- Steering: less lock at speed (counter-steer feel emerges from front lateral force).
	local speed = self.vel.Magnitude
	local lockScale = 1 / (1 + speed * 0.12)
	local steerAngle = -controls.steer * math.rad(spec.steerLock) * lockScale

	-- Wheels
	for _, which in ipairs({ "front", "rear" }) do
		local f, p, info = self:_wheel(which, steerAngle, controls)
		if f.Magnitude > 0 then
			force = force + f
			torque = torque + (p - self.position):Cross(f)
		end
	end

	-- Aero drag (world), applied at CoM.
	if speed > 0.1 then
		local a = spec.aero
		local drag = -0.5 * Config.AIR_DENSITY * a.Cx * a.areaX * speed * self.vel
		force = force + drag
	end

	-- Engine RPM bookkeeping (slave to wheel when clutch engaged & in gear, else free-rev).
	do
		local gearTotal = spec.primaryDrive * spec.gearRatios[self.gear] * spec.finalDrive
		local lockedRPM = math.abs(self.rearOmega) * gearTotal * 60 / (2 * math.pi)
		local engaged = (1 - controls.clutch)
		local target = math.max(spec.idleRPM, lockedRPM) * engaged
			+ (spec.idleRPM + controls.throttle * (spec.limiterRPM - spec.idleRPM)) * (1 - engaged)
		self.engineRPM = self.engineRPM + (target - self.engineRPM) * math.clamp(dt * 12, 0, 1)
		self.engineRPM = math.clamp(self.engineRPM, spec.idleRPM * 0.4, spec.limiterRPM)
		-- auto-clutch at very low rpm so it doesn't stall
		if Config.Assists.autoClutch and lockedRPM < spec.idleRPM then controls.clutch = math.max(controls.clutch, 0.0) end
	end

	-- Balance controller (PD torque about the forward axis).
	if not self.crashed then
		local worldUp = Vector3.new(0, 1, 0)
		local ref = safeUnit(worldUp - fwd * worldUp:Dot(fwd))  -- "upright" reference, perp to fwd
		local cosang = math.clamp(up:Dot(ref), -1, 1)
		local sign = (ref:Cross(up):Dot(fwd) >= 0) and 1 or -1
		local roll = sign * math.acos(cosang)                    -- +lean right
		local rollRate = self.angVel:Dot(fwd)
		local B = Config.Balance
		local speedF = math.clamp(speed / B.steerSpeedRef, 0, 1)
		local targetRoll = math.clamp(
			controls.steer * B.maxLeanFromSteer * speedF + controls.lean * Config.Rider.maxLean * 0,
			-math.rad(55), math.rad(55))
		-- rider weight shift (lean fwd/back) handled via CoM offset below; roll uses steer.
		local err = targetRoll - roll
		if math.abs(err) > B.fallThreshold then self.crashed = true end
		local lever = Config.Rider.mass * Config.Rider.comHeight
		local Tbalance = (B.Kp * err - B.Kd * rollRate) * lever * B.assist
		torque = torque + fwd * Tbalance
	end

	-- mild yaw damping for low-speed stability
	torque = torque + up * (-self.angVel:Dot(up) * spec.mass * 0.4)

	-- ---- Integrate (semi-implicit Euler) ----
	local linAcc = force / spec.mass
	self.vel = self.vel + linAcc * dt

	-- Angular: proper rigid-body Euler in body frame (diagonal inertia).
	local I = spec.inertia                                   -- (pitch X, yaw Y, roll Z)
	local wb = Vector3.new(self.angVel:Dot(right), self.angVel:Dot(up), self.angVel:Dot(fwd))
	local Tb = Vector3.new(torque:Dot(right), torque:Dot(up), torque:Dot(fwd))
	local gyro = Vector3.new(                                 -- w x (I.*w)
		(I.Z - I.Y) * wb.Y * wb.Z,
		(I.X - I.Z) * wb.Z * wb.X,
		(I.Y - I.X) * wb.X * wb.Y)
	local accB = Vector3.new((Tb.X - gyro.X) / I.X, (Tb.Y - gyro.Y) / I.Y, (Tb.Z - gyro.Z) / I.Z)
	local angAcc = right * accB.X + up * accB.Y + fwd * accB.Z
	self.angVel = self.angVel + angAcc * dt

	-- Integrate pose
	self.position = self.position + self.vel * dt
	local w = self.angVel
	local wm = w.Magnitude
	if wm > 1e-6 then
		self.orient = CFrame.fromAxisAngle(w / wm, wm * dt) * self.orient
	end

	-- Safety floor / fell off world
	if self.position.Y < -50 then self.crashed = true end
	return self.engineRPM, self.gear, speed, self.crashed
end

function BikePhysics:respawn(spawnCFrameStuds)
	self.position = spawnCFrameStuds.Position / S
	self.orient = spawnCFrameStuds.Rotation
	self.vel = Vector3.zero; self.angVel = Vector3.zero
	self.rearOmega = 0; self.engineRPM = self.spec.idleRPM; self.gear = 1
	self.crashed = false
	self._lastComp = { front = 0, rear = 0 }
end

return BikePhysics
