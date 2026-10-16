--!nonstrict
--[[
	BikePhysics — the Robikes motorcycle simulation (pure Luau, SI units; no Instances or services).

	One rigid body (bike + seated rider lumped) integrated with semi-implicit Euler at a fixed dt, plus:
	  • raycast suspension: fork (two legs, coil + air spring, 3-stage damper) and a linkage monoshock
	  • Magic Formula tyres with an implicit wheel-spin solve (stable wheelspin / lock-up)
	  • engine ⇄ clutch ⇄ gearbox ⇄ chain ⇄ rear wheel, solved implicitly together
	  • a rider steering controller (countersteer emerges) + optional balance assist torque
	  • rider weight shift (moves the CoM; reaction torque = body english in the air)
	  • wheel/crank spin reaction + gyroscopic torques, aero drag, collision probes, crash + respawn

	World queries come through an injected function, so this module runs in tests without a workspace:
	  ground(originWorld: Vector3, dirUnit: Vector3, maxLen: number) -> (dist, normal, surfaceName) | nil
	All vectors are metres in Roblox axes (+Y up). Body frame: +X right, +Y up, -Z forward.
	SPEC.md documents each law with [OBS]/[INF]/[DESIGN] tags.
]]

local Config = require(script.Parent.RobikesConfig)
local Tyre = require(script.Parent.Tyre)
local Drivetrain = require(script.Parent.Drivetrain)
local Ruts = require(script.Parent.Ruts)

local BikePhysics = {}
BikePhysics.__index = BikePhysics

local G = Config.GRAVITY
local UP = Vector3.yAxis
local abs, max, min, clamp, sqrt = math.abs, math.max, math.min, math.clamp, math.sqrt

local NEUTRAL_INPUT = table.freeze({
	throttle = 0, frontBrake = 0, rearBrake = 0, clutch = 1, steer = 0, riderLean = 0, riderPitch = 0,
	shiftUp = false, shiftDown = false, start = false,
})
BikePhysics.NEUTRAL_INPUT = NEUTRAL_INPUT

-- tuning [DESIGN] — see SPEC §5, §6, §7
local LAT_VREF = 4.0 -- m/s floor in the slip-angle denominator (low-speed stability)
local LONG_VREF = 1.0 -- m/s floor in the slip-ratio denominator
local CLUTCH_LOCK_C = 200 -- N·m·s/rad viscous lock stiffness of an engaged clutch (implicit, so stiff is fine)
local BOTTOM_K, BOTTOM_C = 2.0e5, 4000 -- hard stop past full travel
local PROBE_K, PROBE_C, PROBE_MU = 6.0e4, 3000, 0.6
local CRASH_ROLL = math.rad(75)
local CRASH_G = 35 -- [MEAS] MX Bikes rode out a 24 G landing and crashed at 49 G (10 ms averaged)
local RESPAWN_TIME = 3.0

local function sgn(x)
	return x > 0 and 1 or (x < 0 and -1 or 0)
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

-- 3-stage damper: slopes c1 | c2 | c3 split at |v| = t0, t1 (N·s/m); returns signed force [INF law]
local function damper3(c, t0, t1, v)
	local c1 = c[1] or 0
	local c2 = c[2] or c1
	local c3 = c[3] or c2
	local s = abs(v)
	local f
	if s <= t0 then
		f = c1 * s
	elseif s <= t1 then
		f = c1 * t0 + c2 * (s - t0)
	else
		f = c1 * t0 + c2 * (t1 - t0) + c3 * (s - t1)
	end
	return sgn(v) * f
end
BikePhysics.damper3 = damper3

------------------------------------------------------------------------
-- suspension laws (return the vertical-equivalent force at the wheel)
------------------------------------------------------------------------

-- Fork: x = vertical wheel travel (m), v = vertical travel speed (+ = compressing)
function BikePhysics.forkForce(fork, x, v)
	local c = fork.cosRake
	local u = clamp(x / c, 0, fork.travel) -- travel along the fork axis
	local ud = v / c
	local coil = fork.spring * (u + fork.preload)
	local air = fork.airPressure * fork.airArea * (fork.airLength / max(fork.airLength - u, 0.012) - 1)
	local damp = (ud >= 0) and damper3(fork.bump, fork.t0, fork.t1, ud) or damper3(fork.rebound, fork.rt0, fork.rt1, ud)
	local along = fork.legs * (coil + air + damp)
	return along / c -- wheel slides along the fork: vertical support = axial force / cos(rake)
end

-- Linkage: wheel travel x -> motion ratio and shaft travel
function BikePhysics.shockRatio(shock, x)
	return lerp(shock.ratioTop, shock.ratioBottom, clamp(x / shock.travel, 0, 1))
end

function BikePhysics.shockShaft(shock, x)
	local a, b = shock.ratioTop, shock.ratioBottom
	x = clamp(x, 0, shock.travel)
	if abs(b - a) < 1e-6 then
		return x / a
	end
	local k = (b - a) / shock.travel
	return math.log((a + k * x) / a) / k -- ∫ dx / MR(x)
end

function BikePhysics.shockForce(shock, x, v)
	local mr = BikePhysics.shockRatio(shock, x)
	local y = BikePhysics.shockShaft(shock, x)
	local yd = v / mr
	local f = shock.spring * (y + shock.preload)
	f += (yd >= 0) and damper3(shock.bump, shock.t0, shock.t1, yd) or damper3(shock.rebound, shock.rt0, shock.rt1, yd)
	local yMax = BikePhysics.shockShaft(shock, shock.travel)
	local d = y - (yMax - shock.bumpStopZone)
	if d > 0 then
		f += shock.bumpStopK * d * (1 + shock.bumpStopRise * d) + shock.bumpStopC * max(yd, 0) * d * 100
	end
	return f / mr
end

------------------------------------------------------------------------
-- construction / reset
------------------------------------------------------------------------

function BikePhysics.new(bikeId, spawnCFrame, opts)
	opts = opts or {}
	local self = setmetatable({}, BikePhysics)
	self.bike = Config.buildBike(bikeId or Config.DEFAULT_BIKE, opts.setup)
	-- start from the defaults so an aid the caller doesn't know about (e.g. tractionControl) is still set
	self.assists = table.clone(Config.Assists)
	for k, v in pairs(opts.assists or {}) do
		self.assists[k] = v
	end
	self.ruts = opts.ruts or Ruts.new()
	self.time = 0
	self:reset(spawnCFrame or CFrame.new())
	return self
end

-- spawnCFrame: metres; position = ground point under the bike, LookVector = heading
function BikePhysics:reset(spawnCFrame)
	local b = self.bike
	local rot = spawnCFrame - spawnCFrame.Position
	self.rot = rot
	self.pos = spawnCFrame.Position + rot.UpVector * (b.comHeight + 0.03)
	self.vel = Vector3.zero
	self.angVel = Vector3.zero
	self.wheels = {}
	for i, wd in ipairs(b.wheels) do
		self.wheels[i] = {
			omega = 0, angle = 0, comp = 0, contact = false, load = 0, kappa = 0, alpha = 0,
			surface = "", ext = wd.travel, fx = 0, fy = 0,
		}
	end
	self.engine = Drivetrain.newState(b)
	self.steer = 0
	self.rider = { lat = 0, long = 0, latVel = 0, longVel = 0 }
	self.crashed = false
	self.crashTimer = 0
	self.crashReason = nil
	self.riderBody = nil
	self.lastSafe = spawnCFrame
	self.safeQueue = {}
	self.safeTimer = 0
	self.accelFilter = 0
	self.airTime = 0
	self.contacts = 0
	self.roll, self.rollRate, self.targetRoll = 0, 0, 0
	self.rollInt = 0
	self.tcScale, self.loopScale = 1, 1
	self.whip = 0 -- signed whip amount (-1..1) for the renderer: + = bike thrown to the right
	self.airYaw = 0 -- heading of the bike relative to its direction of travel while airborne (rad, + = right)
	self.telemetry = {}
	self.prevVel = Vector3.zero
end

function BikePhysics:setBike(bikeId, setup)
	local cf = CFrame.new(self.pos - self.rot.UpVector * self.bike.comHeight) * self.rot
	self.bike = Config.buildBike(bikeId, setup)
	self:reset(cf)
end

-- Change setup (gearing / suspension clicks) without moving the bike.
function BikePhysics:applySetup(setup)
	self.bike = Config.buildBike(self.bike.id, setup)
end

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------

local function surfaceProps(compound, surface)
	local s = compound and compound[surface]
	if type(s) ~= "table" then
		return 1.0, 1.0, 0, 0
	end
	return s.dry_grip or 1, s.resistance_dry or 1, s.compacting_factor or 0, s.bulldozing_factor or 0
end

-- Effective mass of the rigid body for a force along `dir` applied at offset r from the CoM:
-- 1/m_eff = 1/m + dir · ((I⁻¹ (r × dir)) × r)
local function effMass(rot, Iv, mass, r, dir)
	local rc = r:Cross(dir)
	local rcB = rot:VectorToObjectSpace(rc)
	local iInv = rot:VectorToWorldSpace(rcB / Iv)
	local k = 1 / mass + dir:Dot(iInv:Cross(r))
	return 1 / max(k, 1e-6)
end

-- implicit wheel spin step with linearised tyre force Fx(ω) = F0 + kS·R·(ω − ω0)
local function solveWheel(I, w0, R, F0, kS, Text, dt)
	local w1 = (I * w0 / dt + Text - R * F0 + R * R * kS * w0) / (I / dt + R * R * kS)
	return w1, F0 + kS * R * (w1 - w0)
end

------------------------------------------------------------------------
-- one fixed step
------------------------------------------------------------------------

function BikePhysics:step(dt, input, ground)
	local b = self.bike
	input = (self.crashed or not input) and NEUTRAL_INPUT or input
	self.time += dt

	local pos, vel, w, rot = self.pos, self.vel, self.angVel, self.rot
	local F, U, Rt = rot.LookVector, rot.UpVector, rot.RightVector
	local mass = b.mass
	local Iv = b.inertia -- body inertia (pitch X, yaw Y, roll Z)

	local force = Vector3.zero
	local torque = Vector3.zero
	local function applyAt(f, point)
		force += f
		torque += (point - pos):Cross(f)
	end

	-- ---------------- rider weight shift (spring-damper toward the input target) ----------------
	local rd, rcfg = self.rider, b.rider
	local tLat = clamp(input.riderLean or 0, -1, 1) * rcfg.maxLat + clamp(input.steer or 0, -1, 1) * 0.06
	local tLong = clamp(input.riderPitch or 0, -1, 1) * rcfg.maxLong
	local aLat = (rcfg.k * (tLat - rd.lat) - rcfg.c * rd.latVel) / rcfg.mass
	local aLong = (rcfg.k * (tLong - rd.long) - rcfg.c * rd.longVel) / rcfg.mass
	rd.latVel += aLat * dt
	rd.lat += rd.latVel * dt
	rd.longVel += aLong * dt
	rd.long += rd.longVel * dt
	local share = rcfg.mass / mass
	local comWorld = pos + Rt * (rd.lat * share) + F * (rd.long * share)
	-- reaction of moving the rider (internal force: torque only) — "body english"
	local riderPoint = pos + U * 0.35 + Rt * rd.lat + F * rd.long
	local riderAccel = Rt * aLat + F * aLong
	torque += (riderPoint - pos):Cross(-riderAccel * rcfg.mass)

	-- ---------------- gravity at the (shifted) CoM ----------------
	applyAt(Vector3.new(0, -mass * G, 0), comWorld)

	-- ---------------- suspension + ground contact per wheel ----------------
	local contacts = 0
	local normalSum = Vector3.zero
	local wheelHits = {}
	for i, wd in ipairs(b.wheels) do
		local ws = self.wheels[i]
		local mountW = pos + rot:VectorToWorldSpace(wd.mount)
		local reach = wd.travel + wd.radius
		-- optional 4th arg: the world casts a sphere about the tyre's size (if it can), so the tyre rolls over small
		-- steps and voxel edges instead of the contact point dropping into each one
		-- (cast from 0.4 m above the mount so a sphere never starts inside the ground on a deep compression)
		local dist, n, surface = ground(mountW + U * 0.4, -U, reach + 0.65, wd.radius * 0.8)
		if dist then
			dist -= 0.4
		end
		if dist and surface then
			local _, _, compacting = surfaceProps(wd.compound, surface)
			if compacting > 0 then
				local hp = mountW - U * dist
				dist += self.ruts:depth(hp.X, hp.Z) -- ruts lower the ground
			end
		end
		if dist and dist < reach then
			local x = reach - dist
			local over = max(0, x - wd.travel)
			local xs = min(x, wd.travel)
			local contactPoint = mountW - U * dist
			local r = contactPoint - pos
			local vc = vel + w:Cross(r)
			local nU = max(n:Dot(U), 0.3)
			local compVel = -vc:Dot(n) / nU
			local fs
			if i == 1 then
				fs = BikePhysics.forkForce(b.fork, xs, compVel)
			else
				fs = BikePhysics.shockForce(b.shock, xs, compVel)
			end
			if over > 0 then
				-- hard stop past full travel; capped so a wheel that starts deep inside the ground (bad spawn,
				-- terrain edit) pushes the bike out firmly instead of launching it
				fs += min(BOTTOM_K * over + BOTTOM_C * max(compVel, 0), 25000)
			end
			local N = max(0, fs) / nU
			ws.contact = N > 0
			ws.comp, ws.ext, ws.load, ws.surface = xs, wd.travel - xs, N, surface
			wheelHits[i] = { point = contactPoint, n = n, r = r, vc = vc, N = N }
			if N > 0 then
				contacts += 1
				normalSum += n
				applyAt(n * N, contactPoint)
			end
		else
			ws.contact, ws.comp, ws.ext, ws.load, ws.surface = false, 0, wd.travel, 0, ""
		end
	end
	self.contacts = contacts

	-- ---------------- lean state & steering controller ----------------
	local refN = (contacts > 0) and normalSum.Unit or UP
	-- lean against gravity drives the rider and the balance aid: on an off-camber landing or a berm the bike must
	-- balance on world vertical, not square to the surface (that tipped it down every side slope) [DESIGN]
	local roll = math.asin(clamp(-Rt:Dot(UP), -1, 1)) -- + = leaning right
	-- lean against the ground under the wheels: what decides whether the bike is lying on it (crash rules)
	local rollS = math.asin(clamp(-Rt:Dot(refN), -1, 1))
	local rollRate = w:Dot(F)
	local vFwd = vel:Dot(F)
	local speed = vel.Magnitude
	local sc = b.steer
	-- the rider never asks for more lean than the surface can hold: atan(k · lateral grip) [DESIGN]
	local rearW = b.wheels[2]
	local surfGrip = surfaceProps(rearW.compound, self.wheels[2].surface ~= "" and self.wheels[2].surface or "soil")
	local gripLean = math.atan(sc.gripLeanFactor * (rearW.tyre.p_Dy1 or 1) * surfGrip)
	local aid = clamp(self.assists.balanceAssist or 0, 0, 1)
	-- with the aids on the rider keeps a margin below the grip limit, so a full keyboard steer can't slide out
	gripLean *= 1 - Config.Aids.leanMargin * aid
	local phiMax = min(math.rad(lerp(12, sc.maxLeanDeg, clamp((abs(vFwd) - 1) / 14, 0, 1))), gripLean)
	local targetRoll = clamp(input.steer or 0, -1, 1) * phiMax
	-- land upright first, then lean: the asked-for lean fades back in over 0.4 s after touch-down
	targetRoll *= clamp((self.landTimer or 99) / 0.4, 0, 1)
	local steerCmd
	if contacts > 0 then
		local vv = max(abs(vFwd), 0.7 * speed, 3) -- a sliding bike still carries its speed
		local L, h = b.wheelbase, b.comHeight
		local dss = math.atan(L * G * math.tan(clamp(roll, -1.3, 1.3)) / (vv * vv))
		local kp = L * h * sc.kp / (vv * vv)
		local kd = L * h * sc.kd / (vv * vv)
		local wLow = clamp((abs(vFwd) - 1.0) / 2.0, 0, 1)
		-- integral on the lean error: the tyres need slip angle to corner, so the no-slip steady-state steer
		-- (dss) always under-steers and the bike would sink into the turn and fall in without it [DESIGN]
		-- (integrates only near the target, or it winds up during a lean-in and overshoots past the grip limit)
		local rollErr = roll - targetRoll
		local near = clamp(1 - (abs(rollErr) - 0.06) / 0.08, 0, 1)
		self.rollInt = clamp(self.rollInt * (1 - 0.3 * dt) + rollErr * dt * wLow * near, -0.25, 0.25)
		local ki = L * h * (sc.ki or 0) / (vv * vv)
		local ctrl = dss + kp * (roll - targetRoll) + kd * rollRate + ki * self.rollInt
		local direct = clamp(input.steer or 0, -1, 1) * sc.lock * 0.7
		steerCmd = lerp(direct, ctrl, wLow)
		local limit = clamp(sc.lock * 6 / max(abs(vFwd), 6), math.rad(6), sc.lock)
		-- just after a landing the rider keeps the bars nearly straight while the suspension settles
		local sinceLand = self.landTimer or 99
		if sinceLand < 0.4 then
			limit = min(limit, lerp(math.rad(4), limit, sinceLand / 0.4))
		end
		-- catch slides: when the bike is travelling sideways to where it points (a landing a bit crossed up, a
		-- washed-out rear), point the front wheel along the direction of travel, like a rider steering into a slide.
		-- Without this the lean controller reads the slide as lean error and slams the bars to full lock [DESIGN]
		local vSide = vel:Dot(Rt)
		local beta = math.atan2(vSide, max(abs(vFwd), 1)) * clamp((speed - 2) / 3, 0, 1)
		beta = sgn(beta) * clamp(abs(beta) - math.rad(4), 0, math.rad(25)) -- normal cornering sideslip is left alone
		steerCmd = clamp(steerCmd, -limit, limit) + beta * sc.slideCatch
		-- only the front tyre down (rear skipping off a crest, a nose-first landing): the front alone would yaw
		-- the whole bike round, so the bars just follow the direction of travel until the rear is back down
		if self.wheels[1].contact and not self.wheels[2].contact and speed > 3 then
			steerCmd = beta * sc.slideCatch
		end
		steerCmd = clamp(steerCmd, -sc.lock, sc.lock)
	else
		-- airborne: bars come back straight so the front tyre lands pointing where the bike is going
		steerCmd = clamp(input.steer or 0, -1, 1) * math.rad(2)
		self.rollInt = 0
	end
	self.steer += clamp(steerCmd - self.steer, -sc.rate * dt, sc.rate * dt)
	self.roll, self.rollRate, self.targetRoll = roll, rollRate, targetRoll

	-- ---------------- drivetrain bookkeeping ----------------
	local eng = self.engine
	local throttleIn = clamp(input.throttle or 0, 0, 1)
	local rear = self.wheels[2]
	if input.shiftUp then
		Drivetrain.shift(b, eng, 1, rear.omega)
	end
	if input.shiftDown then
		Drivetrain.shift(b, eng, -1, rear.omega)
	end
	if self.assists.autoShift then
		Drivetrain.autoShift(b, eng, rear.omega, throttleIn)
	end
	eng.clutchEngage = Drivetrain.clutchEngage(b, eng, clamp(input.clutch or 0, 0, 1), self.assists.autoClutch)
	Drivetrain.updateRunning(b, eng, dt, throttleIn > 0.1 or input.start)
	-- front share of ground load (%) for the wheelie help; airborne counts as "fully loaded" (no cut)
	local loadF, loadR = self.wheels[1].load, self.wheels[2].load
	local frontShare = (loadF + loadR > 50) and (100 * loadF / (loadF + loadR)) or 50
	eng.throttleEff = Drivetrain.effectiveThrottle(b, eng, throttleIn, frontShare, self.assists.antiWheelie)
	-- traction control: trim throttle while the rear spins past a slip target (lower when leaned over) [DESIGN]
	local tcTarget = 1
	if self.assists.tractionControl and rear.contact then
		local slipMax = lerp(Config.Aids.tcSlip[1], Config.Aids.tcSlip[2], aid) * (1 - 0.5 * min(abs(roll) / 0.6, 1))
		-- slip against a 4 m/s floor: from a standstill any spin reads as 100% slip, and cutting on that would
		-- leave a bike on an uphill bogged at full throttle forever; pulling away keeps at least 45% throttle
		local Vx = rear.vx or 0
		local slipTC = (rear.omega * b.wheels[2].rollingRadius - Vx) / max(abs(Vx), 4)
		local floor = lerp(0.45, 0.15, clamp((abs(Vx) - 2) / 4, 0, 1))
		tcTarget = clamp(1 - (slipTC - slipMax) / 0.15, floor, 1)
	elseif (self.assists.tractionControl or aid > 0) and not rear.contact and speed > 3 then
		-- airborne: an unloaded rear wheel at full throttle spins up to the limiter, and lands at double road speed
		-- with no side grip, so the back steps out on every little hop. Hold it near road speed in the air.
		local over = (rear.omega * b.wheels[2].rollingRadius - speed) / speed
		tcTarget = clamp(1 - (over - 0.08) / 0.12, 0.05, 1)
	end
	self.tcScale += (tcTarget - self.tcScale) * clamp(dt * ((tcTarget < self.tcScale) and 30 or 4), 0, 1)
	-- loop-out guard: past a wheelie angle the throttle fades so the bike can't flip over backwards [DESIGN]
	local loopTarget = 1
	self.loopGuard = false
	if aid > 0 and rear.contact and not self.wheels[1].contact then
		-- look ahead along the pitch rate: by the time a wheelie is past the angle it's too late
		local pitchUp = math.asin(clamp(F:Dot(refN), -1, 1)) + max(w:Dot(Rt), 0) * 0.3
		local p0 = math.rad(lerp(Config.Aids.loopPitchDeg[1], Config.Aids.loopPitchDeg[2], aid))
		loopTarget = clamp(1 - (pitchUp - p0) / math.rad(12), 0, 1)
		self.loopGuard = loopTarget < 1
	end
	self.loopScale += (loopTarget - self.loopScale) * clamp(dt * 25, 0, 1)
	eng.throttleEff *= self.tcScale * self.loopScale

	-- ---------------- tyres + wheel spin (front alone, rear coupled to the engine) ----------------
	local spinReaction = 0 -- Σ I·dω/dt of forward-rolling rotors (wheels + crank)
	local spinMomentum = 0 -- Σ I·ω for the gyroscopic term
	local steerGround = self.steer * math.cos(b.rake)
	for i, wd in ipairs(b.wheels) do
		local ws = self.wheels[i]
		local hit = wheelHits[i]
		local R = wd.rollingRadius or wd.radius -- [MEAS] loaded rolling radius for slip / drive
		local I = wd.spinInertia
		local w0 = ws.omega
		local brakeT = (i == 1) and (clamp(input.frontBrake or 0, 0, 1) * b.brakes.frontTorque)
			or (clamp(input.rearBrake or 0, 0, 1) * b.brakes.rearTorque)
		ws.brakeKPa = (i == 1) and (clamp(input.frontBrake or 0, 0, 1) * b.brakes.frontKPa)
			or (clamp(input.rearBrake or 0, 0, 1) * b.brakes.rearKPa)

		local F0, kS, Vx, Vy, t, l, N, alpha, mu, res = 0, 0, 0, 0, F, Rt, 0, 0, 1, 1
		local compacting, bulldozing = 0, 0
		if hit and hit.N > 0 then
			N = hit.N
			local n = hit.n
			local hdg = (i == 1) and (F * math.cos(steerGround) + Rt * math.sin(steerGround)) or F
			t = (hdg - n * hdg:Dot(n))
			t = (t.Magnitude > 1e-6) and t.Unit or F
			l = t:Cross(n)
			Vx, Vy = hit.vc:Dot(t), hit.vc:Dot(l)
			mu, res, compacting, bulldozing = surfaceProps(wd.compound, ws.surface)
			alpha = math.atan2(Vy, max(abs(Vx), LAT_VREF))
			local den = max(abs(Vx), LONG_VREF)
			local kappa0 = (w0 * R - Vx) / den
			local dFdk
			F0, dFdk = Tyre.fxAndSlope(wd.tyre, N, kappa0, alpha, mu)
			-- use the secant slope F/κ when it is steeper than the local slope: on the saturated part of
			-- the curve the local slope is ~0 and the wheel would overshoot zero slip every step (chatter)
			if abs(kappa0) > 1e-4 then
				dFdk = max(dFdk, F0 / kappa0)
			end
			kS = dFdk / den
			ws.kappa, ws.alpha, ws.vx, ws.f0 = kappa0, alpha, Vx, F0
		else
			ws.kappa, ws.alpha = 0, 0
		end

		-- rolling resistance (+ bulldozing in ruts / when digging) acts like a brake on the wheel [INF/DESIGN]
		local rutD = (hit and compacting > 0) and self.ruts:depth(hit.point.X, hit.point.Z) or 0
		local rollT = Tyre.rollingCoeff(wd.tyre) * res * N * R * (1 + bulldozing * (rutD / 0.05 + 0.5 * min(abs(ws.kappa), 1)))
		if i == 2 and ws.kappa > Config.Roost.slip0 then
			-- roost loss on a spinning rear tyre [DESIGN tuned to SPEC.md §4 MEAS slip per gear]
			rollT += Config.Roost.k * bulldozing * (ws.kappa - Config.Roost.slip0) * N * R
		end
		local coulomb = brakeT + rollT

		local w1, Fx
		if i == 2 then
			-- ===== rear: engine ⇄ clutch ⇄ wheel, implicit =====
			local dtr = b.drivetrain
			local p = dtr.primary
			local gw = Drivetrain.wheelRatio(b, eng.gear)
			local eta = dtr.efficiency
			local Ie = b.engine.inertia
			local a0 = eng.omega
			local Te = Drivetrain.engineTorque(b, a0, eng.throttleEff, eng.running)
			local cap = (gw > 0) and Drivetrain.clutchCapacity(b, eng.clutchEngage) or 0
			local Iw = I
			if gw > 0 then
				Iw += (dtr.firstAxisInertia * dtr.gears[eng.gear] ^ 2 + dtr.secondAxisInertia) * dtr.final ^ 2
			end

			local function solve(Text)
				if cap <= 1e-6 then
					local a = max(0, a0 + dt * Te / Ie)
					local wb, fx = solveWheel(Iw, w0, R, F0, kS, Text, dt)
					return a, wb, fx, 0
				end
				local cv = CLUTCH_LOCK_C
				local A11 = Ie / dt + cv / (p * p)
				local A12 = -cv * gw / p
				local B1 = Ie * a0 / dt + Te
				local A21 = -eta * gw * cv / p
				local A22 = Iw / dt + eta * gw * gw * cv + R * R * kS
				local B2 = Iw * w0 / dt - R * F0 + R * R * kS * w0 + Text
				local det = A11 * A22 - A12 * A21
				local a = (B1 * A22 - A12 * B2) / det
				local wb = (A11 * B2 - A21 * B1) / det
				local Tc = cv * (a / p - gw * wb)
				if abs(Tc) > cap then
					Tc = cap * sgn(Tc)
					a = a0 + dt * (Te - Tc / p) / Ie
					local fx
					wb, fx = solveWheel(Iw, w0, R, F0, kS, Text + eta * gw * Tc, dt)
					return max(0, a), wb, fx, Tc
				end
				return max(0, a), wb, F0 + kS * R * (wb - w0), Tc
			end

			local a1, wb, fx = solve(0)
			if coulomb > 0 then
				local dir = (wb ~= 0) and sgn(wb) or sgn(w0)
				local a2, wb2, fx2 = solve(-dir * coulomb)
				if dir == 0 or sgn(wb2) ~= dir then
					-- wheel stops (brake/rolling resistance holds it)
					wb = 0
					fx = F0 + kS * R * (0 - w0)
					local tcl = clamp(CLUTCH_LOCK_C * (a0 / p), -cap, cap)
					a1 = max(0, a0 + dt * (Te - tcl / p) / Ie)
				else
					a1, wb, fx = a2, wb2, fx2
				end
			end
			spinReaction += Ie * (a1 - a0) / dt
			spinMomentum += Ie * a1
			eng.omega = math.min(a1, b.engine.breakingRPM * Drivetrain.RPM_TO_RAD)
			w1, Fx = wb, fx
			I = Iw
		else
			-- ===== front: free wheel with brake =====
			w1, Fx = solveWheel(I, w0, R, F0, kS, 0, dt)
			if coulomb > 0 then
				local dir = (w1 ~= 0) and sgn(w1) or sgn(w0)
				local wb2, fx2 = solveWheel(I, w0, R, F0, kS, -dir * coulomb, dt)
				if dir == 0 or sgn(wb2) ~= dir then
					w1, Fx = 0, F0 + kS * R * (0 - w0)
				else
					w1, Fx = wb2, fx2
				end
			end
		end
		spinReaction += I * (w1 - w0) / dt
		spinMomentum += I * w1
		ws.omega = w1
		ws.angle = (ws.angle + w1 * dt) % (2 * math.pi)

		if hit and N > 0 then
			-- lateral force (motorcycle MF with camber thrust) × combined-slip weight
			local gamma = math.asin(clamp(-Rt:Dot(hit.n), -1, 1))
			-- camber thrust is a rolling-tyre effect: fade it in with speed so a parked bike gets no
			-- phantom sideways push (it would creep and could never fall over) [DESIGN]
			gamma *= clamp((abs(Vx) - 0.5) / 2.5, 0, 1)
			local _, Gyk = Tyre.weights(wd.tyre, ws.kappa, alpha)
			-- forgiving grip with the aids on: side grip falls off less with wheelspin, and a little more of it overall,
			-- so a spinning or skipping rear tyre steps out instead of letting go completely [DESIGN]
			local aidGrip = clamp(self.assists.balanceAssist or 0, 0, 1)
			Gyk += (1 - Gyk) * Config.Aids.spinGripKeep * aidGrip
			local Fy = Tyre.pureFy(wd.tyre, N, alpha, gamma, mu * (1 + Config.Aids.sideGrip * aidGrip)) * Gyk
			-- rut capture: ruts steer the tyre toward their centre line [DESIGN]
			if compacting > 0 and rutD > 0.005 then
				local gx, gz = self.ruts:gradient(hit.point.X, hit.point.Z)
				Fy += -(l.X * gx + l.Z * gz) * 2000
			end
			-- static-friction guard: a locked wheel (and any tyre at walking pace) must not push harder in
			-- one step than it takes to stop the patch sliding, or the stiff friction overshoots every
			-- step and "walks" the bike [DESIGN, numerical]
			-- (effective mass at the patch includes rotation: a push low under the bike also pitches/rolls it)
			local share = 0.5 / max(contacts, 1)
			if w1 == 0 then
				local cap = share * effMass(rot, Iv, mass, hit.r, t) * abs(Vx) / dt
				Fx = clamp(Fx, -cap, cap)
			end
			if abs(Vx) < 3 then
				local capY = share * effMass(rot, Iv, mass, hit.r, l) * abs(Vy) / dt
				Fy = clamp(Fy, -capY, capY)
			end
			ws.fx, ws.fy = Fx, Fy
			applyAt(t * Fx + l * Fy, hit.point)
			-- dig ruts
			if compacting > 0 then
				self.ruts:dig(hit.point.X, hit.point.Z, N, ws.kappa, compacting, dt)
			end
		else
			ws.fx, ws.fy = 0, 0
		end
	end

	-- rotor reactions: spinning a wheel up pitches the bike the other way; spinning rotors resist tilting
	torque += Rt * spinReaction + w:Cross(Rt) * spinMomentum
	self.spinMomentum = spinMomentum

	-- ---------------- chassis probes (collisions with the ground / objects) ----------------
	local headHit, hardHit = false, false
	for _, pr in ipairs(b.probes) do
		local pw = pos + rot:VectorToWorldSpace(pr.pos)
		local dist, n = ground(pw + UP * 0.6, -UP, 0.6 + pr.radius)
		if dist then
			local pen = 0.6 + pr.radius - dist
			if pen > 0 then
				local r = pw - pos
				local vp = vel + w:Cross(r)
				local vn = vp:Dot(n)
				local Fn = max(0, PROBE_K * pen - PROBE_C * vn)
				local vt = vp - n * vn
				local Ff = Vector3.zero
				if vt.Magnitude > 1e-4 then
					Ff = -vt.Unit * min(PROBE_MU * Fn, vt.Magnitude * mass / dt * 0.25)
				end
				applyAt(n * Fn + Ff, pw - n * pr.radius)
				-- head on the ground = down. Bars: a brush against a berm or a jump face at moderate lean is a
				-- scrape; it is a crash once the bike is laid over or the bar digs in hard [DESIGN, HANDLING §3]
				if pr.isHead or (pr.crashOnTouch and (abs(rollS) > math.rad(50) or -vn > 2.5)) then
					headHit = true
				end
				if -vn > 9 then
					hardHit = true
				end
			end
		end
	end

	-- ---------------- balance assist & air control ----------------
	if not self.crashed then
		if contacts > 0 then
			if self.airTime > 0.25 then
				self.landTimer = 0
			end
			-- loop-out guard, part two: the aid taps the rear brake / shifts the rider forward (nose down)
			if self.loopGuard then
				torque += -Rt * (aid * Config.Aids.loopTorque * (1 - self.loopScale))
			end
			self.landTimer = (self.landTimer or 99) + dt
			-- the rider soaks up a landing at every level: a short hold right after touch-down [DESIGN]
			local absorb = 0.6 * clamp(1 - self.landTimer / 0.5, 0, 1)
			if aid > 0 or absorb > 0 then
				-- balance hold toward the lean the rider asked for. Stiffness is in units of gravity's tip-over
				-- stiffness m·g·h, so at aid ≥ ~0.6 the bike stays up even at walking pace or parked [DESIGN]
				local Ic = Iv.Z + mass * b.comHeight * b.comHeight -- roll inertia about the contact line
				-- below walking pace any aid level above 0 dabs a foot: the hold rises toward 0.6 of full
				local slow = (aid > 0) and clamp((3 - abs(vFwd)) / 2, 0, 1) or 0
				local holdAid = max(aid + (1 - aid) * 0.6 * slow, absorb)
				local k = holdAid * Config.Aids.holdK * mass * G * b.comHeight
				local c = 2 * Config.Aids.holdZeta * sqrt(k * Ic)
				torque += F * (k * (targetRoll - roll) - c * rollRate)
			end
			-- touch-down still whipped across the path: the rider can't hold it (HANDLING §3) [DESIGN]
			if self.airTime > 0.3 and abs(self.airYaw) > math.rad(lerp(40, 60, aid)) then
				self.badLanding = true
			end
			self.airTime = 0
			self.airYaw = 0
			self.whipPitch = nil
			self.tYawS = 0
		else
			self.airTime += dt
			torque += self:airControl(input, aid, rot, w, vel, ground, dt)
		end
	end
	torque -= w * 1.5 -- small rotational air damping

	-- ---------------- aero [OBS CdA range, INF law] ----------------
	if speed > 0.1 then
		local tuck = clamp(rd.long / max(rcfg.maxLong, 1e-3), 0, 1)
		local cda = lerp(b.aero.cdaUpright, b.aero.cdaTuck, tuck)
		force += -vel * (0.5 * Config.AIR_DENSITY * cda * speed)
		force += U * (0.5 * Config.AIR_DENSITY * b.aero.cl * b.aero.liftArea * speed * speed)
	end

	-- ---------------- integrate (semi-implicit Euler) ----------------
	vel += force / mass * dt
	pos += vel * dt
	local wb = rot:VectorToObjectSpace(w)
	local tb = rot:VectorToObjectSpace(torque)
	local Iw = Vector3.new(Iv.X * wb.X, Iv.Y * wb.Y, Iv.Z * wb.Z)
	local wdot = (tb - wb:Cross(Iw)) / Iv
	wb += wdot * dt
	w = rot:VectorToWorldSpace(wb)
	local ang = w.Magnitude * dt
	if ang > 1e-9 then
		rot = CFrame.fromAxisAngle(w.Unit, ang) * rot
	end
	rot = rot:Orthonormalize()

	self.pos, self.vel, self.angVel, self.rot = pos, vel, w, rot

	-- ---------------- crash rules [DESIGN; OBS: crash = rider detached] ----------------
	local accelG = (vel - self.prevVel).Magnitude / dt / G
	self.prevVel = vel
	self.accelFilter += (accelG - self.accelFilter) * clamp(dt / 0.03, 0, 1)
	if not self.crashed then
		local upDot = rot.UpVector:Dot(UP)
		local grounded = contacts > 0 or headHit or hardHit
		-- lying over too far for a moment (on pegs / skid plate) also counts as down
		if grounded and abs(rollS) > math.rad(65) then
			self.lowTimer = (self.lowTimer or 0) + dt
		else
			self.lowTimer = 0
		end
		local why = (headHit and "head or bars hit")
			or (hardHit and "hard impact")
			or (grounded and abs(rollS) > CRASH_ROLL and "lowside")
			or (grounded and upDot < -0.2 and "upside down")
			or (self.lowTimer > 0.3 and "lying down")
			or (self.accelFilter > CRASH_G and "landing too hard")
			or (self.badLanding and "landed sideways")
		if why then
			self.badLanding = false
			self.crashReason = why
			self:crash()
		end
		-- remember a safe respawn point: both wheels down on near-level ground, upright, settled and rolling.
		-- It faces the way the bike was travelling, and only becomes the respawn point once the ride carried on
		-- for 2 s without a crash, so a spot just before a fall (or on a bank) can never trap the respawn
		self.safeTimer += dt
		local hv = Vector3.new(vel.X, 0, vel.Z)
		if contacts == 2 and abs(roll) < math.rad(20) and refN.Y > 0.975 and hv.Magnitude > 2
			and (self.landTimer or 99) > 1 and self.safeTimer > 0.5 then
			self.safeTimer = 0
			local groundPos = pos - UP * b.comHeight
			table.insert(self.safeQueue, { cf = CFrame.lookAt(groundPos, groundPos + hv.Unit), t = self.time })
		end
		while contacts > 0 and self.safeQueue[1] and self.time - self.safeQueue[1].t > 2 do -- (not while falling)
			self.lastSafe = table.remove(self.safeQueue, 1).cf
		end
	else
		self.crashTimer += dt
		self:stepRagdoll(dt, ground)
		if self.crashTimer > RESPAWN_TIME then
			self:respawn(ground)
		end
	end

	-- non-finite guard
	-- (and off the edge of the world: nothing below for 6 s of free fall)
	if pos ~= pos or vel ~= vel or w ~= w or pos.Magnitude > 1e5 or self.airTime > 6 then
		self:respawn(ground)
	end

	self:updateTelemetry(roll, rollRate, speed)
end

------------------------------------------------------------------------
-- air control and whips
------------------------------------------------------------------------

-- Torque (world, N·m) the rider puts into the bike while airborne.
--   rider pitch (W/S arrows, rider stick Y)  → nose up / down
--   steer (A/D, steer stick)                 → small roll + yaw, as before
--   rider lean (←/→ arrows, rider stick X)   → the whip: throws the nose sideways and lays the bike over
-- Released, the bike swings back toward its direction of travel; just before touch-down the aid lines it
-- up (yaw, roll and pitch to the landing) so a whip that's let go in time lands clean. [DESIGN]
function BikePhysics:airControl(input, aid, rot, w, vel, ground, dt)
	local A = Config.Air
	local b = self.bike
	local Iv = b.inertia
	local F, U, Rt = rot.LookVector, rot.UpVector, rot.RightVector
	local torque = Vector3.zero
	local pitchIn = clamp(input.riderPitch or 0, -1, 1)
	local steerIn = clamp(input.steer or 0, -1, 1)
	local leanIn = clamp(input.riderLean or 0, -1, 1)

	torque += -Rt * (pitchIn * A.pitchTorque)
	torque += F * (steerIn * A.rollTorque)
	torque += -U * (steerIn * A.yawTorque)

	-- yaw of the bike against its horizontal path (+ = nose right of the path)
	local fh = Vector3.new(F.X, 0, F.Z)
	local vh = Vector3.new(vel.X, 0, vel.Z)
	local airYaw = 0
	if fh.Magnitude > 0.2 and vh.Magnitude > 2 then
		fh, vh = fh.Unit, vh.Unit
		airYaw = math.atan2(vh:Cross(fh).Y * -1, vh:Dot(fh))
	end
	self.airYaw = airYaw
	local yawRate = -w.Y -- + = nose swinging right
	local rollW = math.asin(clamp(-Rt:Dot(UP), -1, 1)) -- + = leaning right (world)
	local rollRate = w:Dot(F)

	-- the spinning wheels' gyroscopic torque would turn every whip into a nose-dive; a rider whips *with*
	-- it, so most of it is cancelled while airborne (counted by the caller in spinMomentum) [DESIGN]
	torque -= w:Cross(Rt) * (self.spinMomentum or 0) * A.gyroCancel

	-- landing window: time until the wheels reach the ground below
	local landing = 0
	if vel.Y < 0 and ground then
		local d = ground(self.pos, -UP, 12)
		if d then
			local tLand = max(d - b.comHeight - 0.25, 0) / max(-vel.Y, 0.5)
			landing = clamp(1 - tLand / lerp(0.3, 0.6, aid), 0, 1) -- the aid starts squaring up earlier
		end
	end

	-- the whip: rider lean sets a target attitude (yaw across the path, laid over into it like a turn) and the
	-- rider's body drives the bike there, limited to what a rider can put in. Released, the target is straight
	-- and the pull back is gentle unless the aid helps; near the ground the aid takes over and squares it up.
	local held = abs(leanIn) > 0.05
	-- the target moves at a rider's pace, so flicking the input across swings the bike through straight
	-- instead of snapping it the short way round (which tumbles the nose)
	local rate = A.whipRate * (dt or 0)
	local yawGoal = leanIn * A.whipYawMax
	self.tYawS = (self.tYawS or 0) + clamp(yawGoal - (self.tYawS or 0), -rate, rate)
	local tYaw = self.tYawS
	local tRoll = tYaw / A.whipYawMax * A.whipRollMax
	local K = held and A.whipK or (A.returnK * max(aid, 0.5))
	-- every level squares up a little before touch-down (HANDLING §4); the aid does it harder and earlier
	local landAid = max(aid, 0.4)
	if landing > 0 then
		tYaw, tRoll = lerp(tYaw, 0, landAid * landing), lerp(tRoll, 0, landAid * landing)
		K = max(K, A.returnK * (1 + A.landAlign * landAid * landing))
	end
	local C = 2 * A.whipZeta * sqrt(K)
	local whipAmt = clamp(max(abs(leanIn), abs(airYaw) / A.whipYawMax, abs(rollW) / A.whipRollMax), 0, 1)
	if vh.Magnitude > 0.5 and (whipAmt > 0.01 or landing > 0) then
		-- target attitude in the path frame: yaw across the path, the bike's current pitch, rolled into the whip.
		-- One 3-D attitude error (axis·angle) instead of separate yaw/roll loops, so a big whip on a pitched,
		-- laid-over bike doesn't leak into pitch and dive the nose.
		local pitchNow = math.asin(clamp(F.Y, -1, 1))
		-- the nose is held where it was when the whip started (rider pitch input still moves it)
		if whipAmt < 0.05 or not self.whipPitch then
			self.whipPitch = pitchNow
		end
		self.whipPitch = clamp(self.whipPitch - pitchIn * 2.5 * (dt or 0), -1.3, 1.3)
		local pitchT = lerp(pitchNow, self.whipPitch, whipAmt)
		local target = CFrame.lookAt(Vector3.zero, vh) * CFrame.Angles(0, -tYaw, 0) * CFrame.Angles(pitchT, 0, 0)
			* CFrame.Angles(0, 0, -tRoll)
		local axis, angle = (target * rot.Rotation:Inverse()):ToAxisAngle()
		local err = axis * angle
		-- rotation the rider damps: everything except free pitch (unless whipped, when the nose is held too)
		local wDamp = w - Rt * w:Dot(Rt) * (1 - whipAmt * (1 - abs(pitchIn)))
		local accel = rot:VectorToObjectSpace(err * K - wDamp * C)
		local tq = rot:VectorToWorldSpace(Vector3.new(Iv.X * accel.X, Iv.Y * accel.Y, Iv.Z * accel.Z))
		if tq.Magnitude > A.whipTorqueMax then
			tq = tq.Unit * A.whipTorqueMax
		end
		torque += tq
	else
		-- no whip and no path to line up with: just the gentle release damping on yaw and roll
		torque += -UP * (Iv.Y * (-K * airYaw - C * yawRate)) + F * (Iv.Z * (-K * rollW - C * rollRate))
	end
	-- pitch: only in the landing window, match the nose to the path so the wheels land together
	if landing > 0 and vel.Magnitude > 3 then
		local pathPitch = math.asin(clamp(vel.Unit.Y, -1, 1))
		local pitch = math.asin(clamp(F.Y, -1, 1))
		local target = pathPitch * 0.5 -- land slightly nose-up of the path, like a rider does
		local pr = w:Dot(Rt)
		local kp = A.returnK * landAid * A.landAlign * landing * 0.6
		torque += Rt * (Iv.X * (kp * (target - pitch) - 2 * sqrt(kp) * pr) * (1 - abs(pitchIn)))
	end

	self.whip = clamp(airYaw / A.whipYawMax, -1, 1)
	return torque
end

------------------------------------------------------------------------
-- crash, ragdoll rider, respawn
------------------------------------------------------------------------

function BikePhysics:crash()
	if self.crashed then
		return
	end
	self.crashed = true
	self.crashTimer = 0
	local U, F = self.rot.UpVector, self.rot.LookVector
	self.riderBody = {
		pos = self.pos + U * 0.45 + F * 0.05,
		vel = self.vel + U * 1.5 + F * 1.0,
		rot = self.rot,
		angVel = Vector3.new(math.random() * 6 - 3, math.random() * 4 - 2, math.random() * 6 - 3),
	}
end

function BikePhysics:stepRagdoll(dt, ground)
	local rb = self.riderBody
	if not rb then
		return
	end
	rb.vel += Vector3.new(0, -G, 0) * dt
	rb.pos += rb.vel * dt
	local ang = rb.angVel.Magnitude * dt
	if ang > 1e-9 then
		rb.rot = CFrame.fromAxisAngle(rb.angVel.Unit, ang) * rb.rot
	end
	local dist, n = ground(rb.pos + UP * 1.0, -UP, 1.3)
	if dist and dist < 1.3 then
		rb.pos += n * (1.3 - dist)
		local vn = rb.vel:Dot(n)
		if vn < 0 then
			rb.vel -= n * vn * 1.3 -- small bounce
		end
		rb.vel *= (1 - min(1, 3 * dt)) -- tumble to a stop
		rb.angVel *= (1 - min(1, 2 * dt))
	end
end

-- Put a spawn CFrame (metres) on the real ground under it. Terrain surfaces are voxel-quantised, so a
-- spawn height chosen by hand can be inside the ground; always snap before placing the bike.
function BikePhysics.snapToGround(cf, ground)
	if not ground then
		return cf
	end
	local origin = cf.Position + Vector3.new(0, 6, 0)
	local d = ground(origin, -UP, 30)
	if d then
		return CFrame.new(origin - Vector3.new(0, d, 0)) * cf.Rotation
	end
	return cf
end

function BikePhysics:respawn(ground)
	local safe = BikePhysics.snapToGround(self.lastSafe, ground)
	local ruts = self.ruts
	local eng = self.engine
	local gear = eng and eng.gear or 1
	self:reset(safe + Vector3.new(0, 0.05, 0))
	self.ruts = ruts
	self.engine.gear = math.max(1, gear)
end

------------------------------------------------------------------------
-- telemetry (same channels as MX Bikes' plugin interface, see REPORT §8)
------------------------------------------------------------------------

function BikePhysics:updateTelemetry(roll, rollRate, speed)
	local t = self.telemetry
	local rot = self.rot
	local F = rot.LookVector
	t.rpm = Drivetrain.rpm(self.engine)
	t.gear = self.engine.gear
	t.running = self.engine.running
	t.speedometer = speed -- [MEAS] MX Bikes' speedometer = length of the velocity vector
	t.speed = speed
	t.velocity = self.vel
	t.position = self.pos
	t.roll = math.deg(roll)
	t.rollRate = math.deg(rollRate)
	t.pitch = math.deg(math.asin(clamp(F:Dot(UP), -1, 1)))
	t.yaw = math.deg(math.atan2(-F.X, -F.Z))
	t.steer = -math.deg(self.steer) -- MX telemetry convention: negative = right
	t.throttle = self.engine.throttleEff
	t.clutch = 1 - self.engine.clutchEngage
	t.suspFront = self.wheels[1].comp
	t.suspRear = self.wheels[2].comp
	t.wheelSpeedFront = self.wheels[1].omega * self.bike.wheels[1].rollingRadius
	t.wheelSpeedRear = self.wheels[2].omega * self.bike.wheels[2].rollingRadius
	t.shockShaft = BikePhysics.shockShaft(self.bike.shock, self.wheels[2].comp) -- shaft travel used (m)
	t.forkTravel = self.wheels[1].comp / self.bike.fork.cosRake -- along the fork (m)
	t.surfaceFront = self.wheels[1].surface
	t.surfaceRear = self.wheels[2].surface
	t.brakeKPaFront = self.wheels[1].brakeKPa or 0
	t.brakeKPaRear = self.wheels[2].brakeKPa or 0
	t.crashed = self.crashed
	t.crashReason = self.crashed and self.crashReason or nil
	t.contacts = self.contacts
	t.accelG = self.accelFilter
end

-- CFrame of the whole bike for rendering (metres). Origin = system CoM, rider seated.
function BikePhysics:getCFrame()
	return CFrame.new(self.pos) * self.rot
end

-- Compact state for BikeRenderer and for network replication (metres).
function BikePhysics:getRenderState(out)
	out = out or { wheels = { {}, {} } }
	out.cf = CFrame.new(self.pos) * self.rot
	for i = 1, 2 do
		out.wheels[i].ext = self.wheels[i].ext
		out.wheels[i].angle = self.wheels[i].angle
	end
	out.steer = self.steer
	out.riderLat = self.rider.lat
	out.riderLong = self.rider.long
	out.crashed = self.crashed
	local rb = self.riderBody
	out.riderCF = rb and (CFrame.new(rb.pos) * rb.rot.Rotation) or nil
	out.bikeId = self.bike.id
	out.whip = (self.contacts == 0) and self.whip or 0
	out.airborne = self.contacts == 0 and self.airTime > 0.15
	out.sim = self -- local bike only (never sent over the network): lets the renderer publish debug telemetry
	return out
end

return BikePhysics
