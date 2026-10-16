--!nonstrict
--[[
	Drivetrain — engine, clutch and gearbox logic (pure Luau, SI).

	Engine torque blend [INF, DERIVED check]: T = θ·Tfull(rps) + (1−θ)·Tbrake(rps).
	With θ floored at IdleThrottle this balances near IdleRPM for the stock bikes (450F: ≈2260 vs 2300 rpm),
	which is strong evidence the blend is what MX Bikes uses. Curves are indexed by crank rev/s [DERIVED].

	The coupled engine/rear-wheel solve itself lives in BikePhysics (it needs the tyre linearisation).
]]

local Config = require(script.Parent.RobikesConfig)

local Drivetrain = {}

local TWO_PI = 2 * math.pi
local RPM_TO_RAD = TWO_PI / 60

function Drivetrain.newState(bike)
	return {
		omega = bike.engine.idleRPM * RPM_TO_RAD, -- crank rad/s
		running = true,
		gear = 1, -- 0 = neutral
		shiftTimer = 0,
		limiterCut = false,
		clutchEngage = 0,
		throttleEff = 0,
		stallTimer = 0,
		shiftCooldown = 0,
		shiftHelpTimer = 0,
		lastShiftDir = 0,
	}
end

function Drivetrain.rpm(st)
	return st.omega / RPM_TO_RAD
end

-- Engine torque at the crank for an effective throttle (0..1)
function Drivetrain.engineTorque(bike, omega, throttle, running)
	local rps = math.max(0, omega) / TWO_PI
	local tBrake = Config.curve(bike.engine.brake, rps)
	if not running then
		return tBrake -- no combustion: only friction / pumping
	end
	local tFull = Config.curve(bike.engine.torque, rps)
	return throttle * tFull + (1 - throttle) * tBrake
end

-- Clutch-shaft → wheel ratio for a gear (0 = neutral -> 0)
function Drivetrain.wheelRatio(bike, gear)
	if gear <= 0 then
		return 0
	end
	return bike.drivetrain.gears[gear] * bike.drivetrain.final
end

-- Crank rpm that the rear wheel speed (rad/s) would force in a given gear
function Drivetrain.rpmForWheel(bike, gear, wheelOmega)
	local G = Drivetrain.wheelRatio(bike, gear)
	return wheelOmega * G * bike.drivetrain.primary / RPM_TO_RAD
end

-- Effective throttle after idle floor, limiter and anti-wheelie.
-- frontShare = % of the ground load on the front wheel. Wheelie help [INF]: wheelinghelp MinRatio/MaxRatio
-- (15/25) read as front-load %, throttle eased toward `Throttle` (0.5) as the front goes light.
function Drivetrain.effectiveThrottle(bike, st, throttleInput, frontShare, antiWheelie)
	local e = bike.engine
	local rpm = Drivetrain.rpm(st)
	if rpm > e.limiterRPM then
		st.limiterCut = true
	elseif rpm < e.limiterRPM - 150 then
		st.limiterCut = false
	end
	if st.limiterCut or not st.running then
		return 0
	end
	local th = math.clamp(throttleInput, 0, 1)
	-- shift help [OBS shifthelp: LiftThrottle/LiftTime on upshift, BlipThrottle/BlipTime on downshift]
	if st.shiftHelpTimer > 0 then
		if st.lastShiftDir > 0 then
			th = math.min(th, bike.helpers.liftThrottle)
		elseif st.lastShiftDir < 0 then
			th = math.max(th, bike.helpers.blipThrottle)
		end
	end
	if antiWheelie and frontShare < bike.helpers.wheelieMaxRatio then
		local h = bike.helpers
		local t = math.clamp((h.wheelieMaxRatio - frontShare) / (h.wheelieMaxRatio - h.wheelieMinRatio), 0, 1)
		th = math.min(th, 1 - t * (1 - h.wheelieThrottle))
	end
	-- idle: a minimum throttle [DERIVED for 4-strokes: balances within 60–115 rpm of IdleRPM], faded out
	-- above IdleRPM so engines whose curves never balance (250 2-stroke) still settle near idle [DESIGN]
	local idleFloor = e.idleThrottle * math.clamp((e.idleRPM + 400 - rpm) / 400, 0, 1)
	return math.max(th, idleFloor)
end

-- Clutch engagement 0..1 from the lever (1 = pulled) and auto-clutch [OBS DeadZone, autoclutch rpm]
function Drivetrain.clutchEngage(bike, st, clutchInput, autoClutch)
	local e = bike.engine
	local dz = e.clutchDeadZone
	local manual = math.clamp((1 - clutchInput - dz) / (1 - dz), 0, 1)
	if st.gear == 0 or st.shiftTimer > 0 then
		return 0
	end
	if autoClutch then
		local dt = bike.drivetrain
		local rpm = Drivetrain.rpm(st)
		local auto = math.clamp((rpm - dt.autoClutchMin) / (dt.autoClutchMax - dt.autoClutchMin), 0, 1)
		manual = math.min(manual, auto)
	end
	return manual
end

function Drivetrain.clutchCapacity(bike, engage)
	return bike.engine.clutchMaxTorque * engage ^ bike.engine.clutchMapping
end

-- Shift request: +1 up, -1 down. Refuses a downshift that would over-rev past BreakingRPM. [DESIGN]
function Drivetrain.shift(bike, st, dir, wheelOmega)
	local n = #bike.drivetrain.gears
	local target = math.clamp(st.gear + dir, 0, n)
	if target == st.gear then
		return false
	end
	if dir < 0 and target > 0 then
		local rpmAfter = Drivetrain.rpmForWheel(bike, target, wheelOmega)
		if rpmAfter > bike.engine.breakingRPM then
			return false
		end
	end
	st.gear = target
	st.shiftTimer = (dir > 0) and bike.drivetrain.upshiftTime or bike.drivetrain.downshiftTime
	st.lastShiftDir = (target == 0) and 0 or dir
	st.shiftHelpTimer = (dir > 0) and bike.helpers.liftTime or bike.helpers.blipTime
	st.shiftCooldown = 0.35
	return true
end

-- Auto-shift using the per-gear up/down rpm table [OBS values]. Decisions use the rpm the rear wheel
-- imposes in the current gear (road speed), never the free-revving engine, plus a short cooldown —
-- otherwise the engine flaring during the 40 ms shift triggers the next shift immediately.
function Drivetrain.autoShift(bike, st, wheelOmega, throttle)
	if st.shiftTimer > 0 or st.shiftCooldown > 0 then
		return
	end
	local n = #bike.drivetrain.gears
	if st.gear == 0 then
		if throttle > 0.05 then
			Drivetrain.shift(bike, st, 1, wheelOmega)
		end
		return
	end
	local a = bike.drivetrain.autoshift[st.gear]
	local roadRpm = Drivetrain.rpmForWheel(bike, st.gear, wheelOmega)
	if a and a.up and st.gear < n and roadRpm > a.up and throttle > 0.2 then
		Drivetrain.shift(bike, st, 1, wheelOmega)
	elseif st.gear > 1 and a and a.down and roadRpm < a.down then
		Drivetrain.shift(bike, st, -1, wheelOmega)
	end
end

-- Stall / auto-start bookkeeping (called once per step)
function Drivetrain.updateRunning(bike, st, dt, wantsStart)
	local e = bike.engine
	local rpm = Drivetrain.rpm(st)
	if st.running and rpm < e.stallRPM then
		st.running = false
		st.stallTimer = 0
	end
	if not st.running then
		st.stallTimer += dt
		if wantsStart and st.stallTimer > 0.5 and (st.gear == 0 or st.clutchEngage < 0.05) then
			-- starter: spin up to idle and fire [DESIGN simplification of the starter model]
			st.running = true
			st.omega = math.max(st.omega, e.idleRPM * RPM_TO_RAD)
		end
	end
	if st.shiftTimer > 0 then
		st.shiftTimer = math.max(0, st.shiftTimer - dt)
	end
	st.shiftCooldown = math.max(0, st.shiftCooldown - dt)
	st.shiftHelpTimer = math.max(0, st.shiftHelpTimer - dt)
end

Drivetrain.RPM_TO_RAD = RPM_TO_RAD
return Drivetrain
