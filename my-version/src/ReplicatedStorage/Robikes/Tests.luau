--!nonstrict
--[[
	Tests — behaviour tests for the pure physics core (run in Studio edit mode):
	    require(game.ReplicatedStorage.Robikes.Tests).run()
	Each test comes from SPEC.md or the milestone list (M1–M5). Ground is an analytic plane, so results
	are deterministic and independent of the workspace.
]]

local Robikes = script.Parent
local Config = require(Robikes.RobikesConfig)
local Tyre = require(Robikes.Tyre)
local Drivetrain = require(Robikes.Drivetrain)
local BikePhysics = require(Robikes.BikePhysics)

local Tests = {}
local DT = 1 / Config.PHYSICS_HZ

local function flatGround(surface, height)
	surface = surface or "soil"
	height = height or 0
	return function(origin, dir, len)
		if dir.Y >= -1e-6 then
			return nil
		end
		local t = (origin.Y - height) / -dir.Y
		if t < 0 or t > len then
			return nil
		end
		return t, Vector3.yAxis, surface
	end
end

local function newBike(id, opts)
	opts = opts or {}
	local assists = table.clone(Config.Assists)
	for k, v in pairs(opts.assists or {}) do
		assists[k] = v
	end
	local cf = opts.spawn or CFrame.new(0, 0, 0)
	return BikePhysics.new(id or "450xf", cf, { assists = assists })
end

local function input(t)
	local i = {
		throttle = 0, frontBrake = 0, rearBrake = 0, clutch = 0, steer = 0, riderLean = 0, riderPitch = 0,
		shiftUp = false, shiftDown = false, start = false,
	}
	for k, v in pairs(t or {}) do
		i[k] = v
	end
	return i
end

local function run(sim, seconds, inp, ground, each)
	local n = math.floor(seconds / DT + 0.5)
	for k = 1, n do
		local x = (type(inp) == "function") and inp(k * DT) or inp
		sim:step(DT, x, ground)
		if each then
			each(sim, k * DT)
		end
	end
end

local cases = {}
local function case(name, fn)
	table.insert(cases, { name = name, fn = fn })
end
local function approx(a, b, tol)
	return math.abs(a - b) <= tol
end

---------------------------------------------------------------- data helpers
case("settingValue = min + n*step, clamped", function()
	local r = { 4400, 200, 5600 }
	assert(Config.settingValue(r, 3) == 5000, "setting 3 should be 5000")
	assert(Config.settingValue(r, 99) == 5600, "clamps high")
	assert(Config.settingValue(r, -2) == 4400, "clamps low")
	return "fork spring setting 3 = 5000 N/m"
end)

case("curve interpolates and clamps", function()
	local c = { { 0, 0 }, { 10, 100 } }
	assert(Config.curve(c, 5) == 50 and Config.curve(c, -1) == 0 and Config.curve(c, 99) == 100)
	return "ok"
end)

---------------------------------------------------------------- engine / drivetrain
case("torque curve unit = rev/s: 450F peak power ~39.6 kW near 10,000 rpm", function()
	local bike = Config.buildBike("450xf")
	local best, bestRpm = 0, 0
	for rpm = 1000, 13000, 25 do
		local w = rpm * Drivetrain.RPM_TO_RAD
		local p = Drivetrain.engineTorque(bike, w, 1, true) * w
		if p > best then
			best, bestRpm = p, rpm
		end
	end
	assert(approx(best / 1000, 39.6, 0.8), ("peak %.1f kW"):format(best / 1000))
	assert(bestRpm > 9000 and bestRpm < 11000, "peak rpm " .. bestRpm)
	return ("peak %.1f kW @ %d rpm"):format(best / 1000, bestRpm)
end)

case("idle throttle balances each 4-stroke near IdleRPM", function()
	local out = {}
	for _, id in ipairs({ "250xf", "350xf", "450xf", "450sm" }) do
		local bike = Config.buildBike(id)
		local e = bike.engine
		local eq
		local prev
		for rpm = 500, 6000, 5 do
			local T = Drivetrain.engineTorque(bike, rpm * Drivetrain.RPM_TO_RAD, e.idleThrottle, true)
			if prev and prev > 0 and T <= 0 then
				eq = rpm
				break
			end
			prev = T
		end
		assert(eq and math.abs(eq - e.idleRPM) < 200, id .. " balance " .. tostring(eq))
		table.insert(out, id .. "=" .. eq)
	end
	return table.concat(out, " ")
end)

case("450F speed at the limiter per gear ~80/96/114/135 km/h (MEAS rolling radius)", function()
	local bike = Config.buildBike("450xf")
	local d = bike.drivetrain
	local out = {}
	local expect = { 80, 96, 114, 135 }
	for g = 1, #d.gears do
		local wheelW = bike.engine.limiterRPM * Drivetrain.RPM_TO_RAD / (d.primary * d.gears[g] * d.final)
		local kmh = wheelW * bike.wheels[2].rollingRadius * 3.6
		assert(approx(kmh, expect[g], 3), ("gear %d %.1f km/h"):format(g, kmh))
		if g == #d.gears then
			-- SPEC §3: 11600/60·2π / 10.024 · 0.31 ≈ 37.6 m/s in top gear
			assert(approx(kmh / 3.6, 37.6, 0.4), ("top gear %.2f m/s"):format(kmh / 3.6))
		end
		table.insert(out, ("%d"):format(kmh))
	end
	return table.concat(out, " / ") .. " km/h"
end)

case("350F rpm per m/s per gear matches the MX Bikes recording (SPEC §3 MEAS ±1%, 5th ±1.5%)", function()
	local bike = Config.buildBike("350xf")
	local meas = { 670.1, 544.6, 445.9, 382.1, 315.9 }
	local out = {}
	for g, m in ipairs(meas) do
		local rpm = Drivetrain.rpmForWheel(bike, g, 1 / bike.wheels[2].rollingRadius)
		-- gears 1–4 fit r_eff 0.3096–0.3103 m; 5th implies 0.3134 m from few samples (analysis.md §4), so it gets 1.5%
		local tol = (g <= 4) and 0.01 or 0.015
		assert(math.abs(rpm - m) / m < tol, ("gear %d: %.1f vs %.1f"):format(g, rpm, m))
		table.insert(out, ("%.0f"):format(rpm))
	end
	return table.concat(out, " / ") .. " rpm per m/s"
end)

case("rolling radius: rear 0.31 m, front ~0.32 m (SPEC §3 MEAS)", function()
	for _, id in ipairs(Config.BIKE_ORDER) do
		local bike = Config.buildBike(id)
		if bike.tyreType == "mx" then
			assert(approx(bike.wheels[2].rollingRadius, 0.31, 0.002), id .. " rear " .. bike.wheels[2].rollingRadius)
			assert(approx(bike.wheels[1].rollingRadius, 0.32, 0.005), id .. " front " .. bike.wheels[1].rollingRadius)
		end
	end
	local b = Config.buildBike("350xf")
	return ("rear %.3f m, front %.3f m"):format(b.wheels[2].rollingRadius, b.wheels[1].rollingRadius)
end)

case("money-shift protection refuses an over-rev downshift", function()
	local bike = Config.buildBike("450xf")
	local st = Drivetrain.newState(bike)
	st.gear = 4
	local wheelW = 38 / bike.wheels[2].radius
	st.shiftTimer = 0
	local okTo3 = Drivetrain.shift(bike, st, -1, wheelW) -- 4 -> 3 at 38 m/s
	st.gear, st.shiftTimer = 2, 0
	local okTo1 = Drivetrain.shift(bike, st, -1, wheelW) -- 2 -> 1 at 38 m/s would be ~25k rpm
	assert(okTo1 == false and st.gear == 2, "2->1 at speed must be refused")
	return "4->3 " .. tostring(okTo3) .. ", 2->1 refused"
end)

case("brake hydraulics: 450F front full lever ~2515 kPa / ~392 N·m", function()
	local bike = Config.buildBike("450xf")
	assert(approx(bike.brakes.frontKPa, 2515, 40), "kPa " .. bike.brakes.frontKPa)
	assert(approx(bike.brakes.frontTorque, 392, 8), "Nm " .. bike.brakes.frontTorque)
	return ("front %.0f kPa %.0f N·m, rear %.0f kPa %.0f N·m"):format(bike.brakes.frontKPa, bike.brakes.frontTorque, bike.brakes.rearKPa, bike.brakes.rearTorque)
end)

case("brake hydraulics: 450F rear full lever ~4209 kPa / ~556 N·m (SPEC §6)", function()
	local bike = Config.buildBike("450xf")
	assert(approx(bike.brakes.rearKPa, 4209, 40), "kPa " .. bike.brakes.rearKPa)
	assert(approx(bike.brakes.rearTorque, 556, 8), "Nm " .. bike.brakes.rearTorque)
	return ("rear %.0f kPa %.0f N·m"):format(bike.brakes.rearKPa, bike.brakes.rearTorque)
end)

case("steering lock 42° (SPEC §6 MEAS p99 ±42.03°)", function()
	for _, id in ipairs(Config.BIKE_ORDER) do
		local lock = math.deg(Config.buildBike(id).steer.lock)
		assert(approx(lock, 42, 0.5), id .. " lock " .. lock)
	end
	return "42° on all bikes"
end)

case("fixed step divides both 10 ms and a 60 Hz frame (SPEC §10 MEAS 10 ms grid)", function()
	local hz = Config.PHYSICS_HZ
	assert(hz % 100 == 0 and hz % 60 == 0, "PHYSICS_HZ " .. hz)
	assert(approx(Config.STUDS_PER_METER, 1 / 0.28, 1e-9), "STUDS_PER_METER " .. Config.STUDS_PER_METER)
	return ("%d Hz: %d steps per 10 ms, %d per frame"):format(hz, hz / 100, hz / 60)
end)

---------------------------------------------------------------- tyres
case("Magic Formula Fx: dirt tyre saturates (p_Cx1 = 1), supermoto tyre peaks (p_Cx1 = 1.2)", function()
	-- [OBS] p_Cx1 = 1.0 on the MX tyre means sin(atan(x)): traction keeps rising with wheelspin and
	-- never drops (dirt digging). The supermoto slick (1.2) has a real peak and falls off after it.
	local mx = Config.buildBike("450xf").wheels[2].tyre
	local sm = Config.buildBike("450sm").wheels[2].tyre
	assert(approx(Tyre.pureFx(mx, 1000, 0.1, 1), -Tyre.pureFx(mx, 1000, -0.1, 1), 1e-6), "odd")
	local D = (mx.p_Dx1) * 1000
	local f30, f100 = Tyre.pureFx(mx, 1000, 0.3, 1), Tyre.pureFx(mx, 1000, 1, 1)
	assert(f30 > 0.85 * D and f100 >= f30 and f100 <= D + 1e-6, "dirt curve shape")
	local best, bestK = 0, 0
	for k = 0, 1, 0.005 do
		local f = Tyre.pureFx(sm, 1000, k, 1)
		if f > best then
			best, bestK = f, k
		end
	end
	assert(bestK > 0.02 and bestK < 0.4 and Tyre.pureFx(sm, 1000, 1, 1) < best, "sm peak " .. bestK)
	return ("dirt: %.0f N @0.3 → %.0f N @1.0 (limit %.0f); slick peak %.0f N @ kappa %.2f"):format(f30, f100, D, best, bestK)
end)

case("surface grip ordering: sand < soil < asphalt", function()
	local p = Config.buildBike("450xf").wheels[2].tyre
	local comp = Config.buildBike("450xf").wheels[2].compound
	local function peak(s)
		return Tyre.pureFx(p, 1000, 0.12, comp[s].dry_grip)
	end
	local a, b, c = peak("sand"), peak("soil"), peak("asphalt1")
	assert(a < b and b < c, ("%f %f %f"):format(a, b, c))
	return ("sand %.0f < soil %.0f < asphalt %.0f N"):format(a, b, c)
end)

case("camber thrust pushes toward the lean; slip pushes against the slide", function()
	local p = Config.buildBike("450xf").wheels[1].tyre
	local right = Tyre.pureFy(p, 1000, 0, math.rad(30), 1)
	local left = Tyre.pureFy(p, 1000, 0, -math.rad(30), 1)
	local slideRight = Tyre.pureFy(p, 1000, math.rad(5), 0, 1)
	assert(right > 0 and left < 0 and slideRight < 0)
	return ("30° lean thrust %.0f N; 5° slide %.0f N"):format(right, slideRight)
end)

---------------------------------------------------------------- suspension
case("preload shortens the stroke: 350F fork tops out at 0.291 m, shock at 0.108 m (SPEC §5 MEAS)", function()
	local bike = Config.buildBike("350xf")
	assert(approx(bike.fork.travel, 0.291, 0.0005), "fork " .. bike.fork.travel)
	assert(approx(bike.shock.stroke, 0.108, 0.0005), "shock " .. bike.shock.stroke)
	return ("fork %.3f m, shock %.3f m"):format(bike.fork.travel, bike.shock.stroke)
end)

case("3-stage damper is continuous and monotonic; more clicks = more force", function()
	local c = { 2360, 370, 1500 }
	local d = BikePhysics.damper3
	assert(approx(d(c, 0.05, 1.1, 0.05 - 1e-6), d(c, 0.05, 1.1, 0.05 + 1e-6), 0.01))
	assert(approx(d(c, 0.05, 1.1, 1.1 - 1e-6), d(c, 0.05, 1.1, 1.1 + 1e-6), 0.01))
	local prev = -1
	for v = 0, 3, 0.01 do
		local f = d(c, 0.05, 1.1, v)
		assert(f >= prev)
		prev = f
	end
	local tbl = Config.BikeData.bikes["450xf"].front_suspension.Damper.Bump
	assert(d(tbl.setting14, 0.05, 1.1, 0.5) > d(tbl.setting0, 0.05, 1.1, 0.5))
	return "ok"
end)

case("M1 static sag ≈ MX Bikes recording (SPEC §5 MEAS fork 63 mm, shock shaft 28 mm, ±10 mm)", function()
	local sim = newBike("350xf", { assists = { balanceAssist = 1 } })
	run(sim, 4, input(), flatGround())
	local t = sim.telemetry
	assert(approx(t.forkTravel, 0.063, 0.010), ("fork sag %.3f"):format(t.forkTravel))
	assert(approx(t.shockShaft, 0.028, 0.010), ("shaft sag %.3f"):format(t.shockShaft))
	assert(sim.vel.Magnitude < 0.05 and not sim.crashed, "settled")
	return ("fork %.0f mm, shock shaft %.0f mm (rear wheel %.0f mm)"):format(t.forkTravel * 1000, t.shockShaft * 1000, sim.wheels[2].comp * 1000)
end)

case("M1 drop from 2 m: settles, no sinking, no endless bounce, no crash", function()
	local sim = newBike("450xf", { assists = { balanceAssist = 1 }, spawn = CFrame.new(0, 2, 0) })
	local touches, wasContact = 0, false
	run(sim, 5, input(), flatGround(), function(s)
		local c = s.wheels[2].contact
		if c and not wasContact then
			touches += 1
		end
		wasContact = c
	end)
	local h = sim.pos.Y
	run(sim, 1, input(), flatGround())
	assert(not sim.crashed, "crashed on a 2 m flat drop")
	assert(touches <= 3, "bounces " .. touches)
	assert(math.abs(sim.pos.Y - h) < 0.01 and math.abs(sim.vel.Y) < 0.05, "still moving")
	return ("touchdowns %d, settled CoM %.3f m"):format(touches, sim.pos.Y)
end)

---------------------------------------------------------------- M2 powertrain
case("M2 neutral + full throttle: limiter overshoot < 100 rpm, bike stays put (SPEC §3 MEAS 13,485 / 13,400)", function()
	local out = {}
	for _, id in ipairs({ "350xf", "450xf" }) do
		local sim = newBike(id, { assists = { balanceAssist = 1, autoShift = false } })
		sim.engine.gear = 0
		local maxRpm = 0
		run(sim, 3, input({ throttle = 1 }), flatGround(), function(s)
			maxRpm = math.max(maxRpm, s.telemetry.rpm)
		end)
		local lim = sim.bike.engine.limiterRPM
		assert(maxRpm >= lim and maxRpm <= lim + 100, ("%s max rpm %.0f, limiter %d"):format(id, maxRpm, lim))
		assert(sim.vel.Magnitude < 0.2, "moved " .. sim.vel.Magnitude)
		table.insert(out, ("%s %.0f/%d rpm"):format(id, maxRpm, lim))
	end
	return table.concat(out, ", ")
end)

case("M2 idle settles at IdleRPM ± 20 after a blip, every bike (SPEC §3 MEAS 2305 for 2300)", function()
	local out = {}
	for _, id in ipairs(Config.BIKE_ORDER) do
		local sim = newBike(id, { assists = { balanceAssist = 1, autoShift = false } })
		sim.engine.gear = 0
		run(sim, 1, input(), flatGround())
		run(sim, 0.5, input({ throttle = 1 }), flatGround())
		run(sim, 5, input(), flatGround())
		local idle = sim.bike.engine.idleRPM
		assert(sim.engine.running and approx(sim.telemetry.rpm, idle, 20), ("%s %.0f rpm vs %d"):format(id, sim.telemetry.rpm, idle))
		table.insert(out, ("%s %.0f"):format(id, sim.telemetry.rpm))
	end
	return table.concat(out, " ")
end)

case("M2 stopping in gear with the clutch out stalls the engine (SPEC §3 MEAS rpm ≈ 0)", function()
	local sim = newBike("350xf", { assists = { balanceAssist = 1, autoShift = false, autoClutch = false } })
	run(sim, 1, input({ clutch = 1 }), flatGround())
	run(sim, 3, input({ frontBrake = 1, rearBrake = 1 }), flatGround())
	assert(not sim.engine.running, "still running at " .. sim.telemetry.rpm)
	assert(sim.telemetry.rpm < 100, "rpm " .. sim.telemetry.rpm)
	return ("stalled, %.0f rpm"):format(sim.telemetry.rpm)
end)

case("M2 full brakes at standstill in gear: no creep", function()
	local sim = newBike("450xf", { assists = { balanceAssist = 1 } })
	run(sim, 1, input(), flatGround())
	local p0 = sim.pos
	run(sim, 3, input({ frontBrake = 1, rearBrake = 1 }), flatGround())
	local moved = (sim.pos - p0) * Vector3.new(1, 0, 1)
	assert(moved.Magnitude < 0.02, "crept " .. moved.Magnitude)
	return ("moved %.4f m"):format(moved.Magnitude)
end)

case("M2 full-throttle launch: shifts up, accelerates, stays upright", function()
	local sim = newBike("450xf", { assists = { balanceAssist = 0.6, antiWheelie = true } })
	local maxGear = 1
	run(sim, 5, input({ throttle = 1, riderPitch = 1 }), flatGround(), function(s)
		maxGear = math.max(maxGear, s.engine.gear)
	end)
	local v = sim.vel.Magnitude
	assert(not sim.crashed, "crashed during launch")
	assert(v > 18, ("only %.1f m/s after 5 s"):format(v))
	assert(maxGear >= 3, "max gear " .. maxGear)
	return ("%.1f m/s (%.0f km/h) after 5 s, gear %d"):format(v, v * 3.6, maxGear)
end)

case("M5 loose surfaces slow you down: sand < soil after 4 s", function()
	local function launch(surface)
		local sim = newBike("450xf", { assists = { balanceAssist = 0.6, antiWheelie = true } })
		run(sim, 4, input({ throttle = 1, riderPitch = 1 }), flatGround(surface))
		return sim.vel.Magnitude, sim.crashed
	end
	local vSand, cs = launch("sand")
	local vSoil, co = launch("soil")
	assert(not cs and not co)
	assert(vSand < vSoil, ("sand %.1f vs soil %.1f"):format(vSand, vSoil))
	return ("sand %.1f m/s < soil %.1f m/s"):format(vSand, vSoil)
end)

---------------------------------------------------------------- M3 steering / balance
local function upToSpeed(sim, target, ground)
	run(sim, 8, function()
		local th = (sim.vel.Magnitude < target) and 0.6 or 0.15
		return input({ throttle = th })
	end, ground)
end

case("M3 countersteer: bars go left first, then the bike leans and turns right", function()
	local g = flatGround()
	local sim = newBike("450xf", { assists = { balanceAssist = 0.3 } })
	upToSpeed(sim, 10, g)
	local F0, R0 = sim.rot.LookVector, sim.rot.RightVector
	local minSteer, maxRoll = 0, 0
	run(sim, 2.5, input({ steer = 1, throttle = 0.25 }), g, function(s, t)
		if t < 0.4 then
			minSteer = math.min(minSteer, s.steer)
		end
		maxRoll = math.max(maxRoll, s.roll)
	end)
	local turned = sim.rot.LookVector:Dot(R0)
	assert(not sim.crashed, "crashed")
	assert(minSteer < -math.rad(0.3), ("no countersteer (min steer %.2f°)"):format(math.deg(minSteer)))
	assert(maxRoll > math.rad(10), ("max roll %.1f°"):format(math.deg(maxRoll)))
	assert(turned > 0.2, "heading change " .. turned)
	return ("countersteer %.1f°, lean %.0f°, heading -> right (%.2f)"):format(math.deg(minSteer), math.deg(maxRoll), turned)
end)

case("M3 holds a steady circle", function()
	local g = flatGround()
	local sim = newBike("450xf", { assists = { balanceAssist = 0.3 } })
	upToSpeed(sim, 10, g)
	local rolls = {}
	run(sim, 6, input({ steer = 0.5, throttle = 0.3 }), g, function(s, t)
		if t > 3 then
			table.insert(rolls, s.roll)
		end
	end)
	assert(not sim.crashed, "crashed in the circle")
	local mean = 0
	for _, r in ipairs(rolls) do
		mean += r
	end
	mean /= #rolls
	local var = 0
	for _, r in ipairs(rolls) do
		var += (r - mean) ^ 2
	end
	local sd = math.sqrt(var / #rolls)
	assert(mean > math.rad(8), ("mean lean %.1f°"):format(math.deg(mean)))
	assert(sd < math.rad(4), ("lean wobble %.1f°"):format(math.deg(sd)))
	return ("lean %.1f° ± %.1f° at %.1f m/s"):format(math.deg(mean), math.deg(sd), sim.vel.Magnitude)
end)

case("M3 hardcore (assist 0) at standstill: falls over and the rider detaches", function()
	local sim = newBike("450xf", { assists = { balanceAssist = 0 } })
	sim.rot = CFrame.fromAxisAngle(sim.rot.LookVector, math.rad(-3)) * sim.rot -- tiny lean
	local crashed = false
	run(sim, 5, input(), flatGround(), function(s)
		crashed = crashed or s.crashed
	end)
	assert(crashed, "did not fall")
	return "fell and crashed"
end)

case("crash when landing upside down", function()
	local sim = newBike("450xf", { spawn = CFrame.new(0, 1.5, 0) * CFrame.Angles(0, 0, math.pi) })
	local crashed = false
	run(sim, 2, input(), flatGround(), function(s)
		crashed = crashed or s.crashed
	end)
	assert(crashed)
	return "crashed"
end)

---------------------------------------------------------------- M4 air
case("M4 air control: rider pitch input rotates the bike in the air", function()
	local function pitchRate(p)
		local sim = newBike("450xf", { spawn = CFrame.new(0, 40, 0) })
		run(sim, 0.5, input({ riderPitch = p }), flatGround())
		return sim.angVel:Dot(sim.rot.RightVector) -- + = nose up
	end
	local fwd, back = pitchRate(1), pitchRate(-1)
	assert(fwd < -0.1 and back > 0.1, ("fwd %.2f back %.2f rad/s"):format(fwd, back))
	return ("lean forward %.2f rad/s nose-down, back %.2f rad/s nose-up"):format(fwd, back)
end)

case("M4 rear brake in the air dips the nose (wheel reaction torque)", function()
	local sim = newBike("450xf", { spawn = CFrame.new(0, 40, 0) })
	sim.wheels[2].omega = 100 -- rear wheel spinning as after a take-off
	run(sim, 0.3, input({ rearBrake = 1 }), flatGround())
	local rate = sim.angVel:Dot(sim.rot.RightVector)
	assert(rate < -0.05, ("pitch rate %.3f"):format(rate))
	return ("pitch rate %.2f rad/s nose-down"):format(rate)
end)

---------------------------------------------------------------- robustness
case("large time step stays finite", function()
	local sim = newBike("450xf")
	for _ = 1, 10 do
		sim:step(0.25, input({ throttle = 1, steer = 1 }), flatGround())
	end
	local p = sim.pos
	assert(p == p and p.Magnitude < 1e5)
	return "finite"
end)

-- RoBikes vs the MX Bikes recording (350XF, Winchester, dirt) — full-throttle pull from rest.
-- SPEC §4 MEAS medians per gear: slip 15.3 / 6.9 / 4.1 / 2.3 / 2.6 %, forward accel 0.61 / 0.59 / 0.50 / 0.43 / 0.37 G.
-- (5th is not compared: the recording only reaches 5th at track speeds, the flat pull reaches it near top speed.)
local MEAS_PULL = {
	slip = { 15.3, 6.9, 4.1, 2.3, 2.6 },
	accel = { 0.614, 0.586, 0.502, 0.427, 0.374 },
}

local function median(t)
	if #t == 0 then
		return 0 / 0
	end
	table.sort(t)
	return t[math.floor(#t / 2) + 1]
end

local function fullThrottlePull(opts)
	opts = opts or {}
	local sim = newBike("350xf", { assists = { balanceAssist = 0.6, antiWheelie = opts.antiWheelie or false } })
	local g = flatGround(opts.surface or "soil")
	run(sim, 1, input(), g)
	local per = {}
	local prevV = sim.vel
	run(sim, opts.seconds or 14, input({ throttle = 1, riderPitch = opts.riderPitch or 0.6 }), g, function(s)
		local F = s.rot.LookVector
		local a = (s.vel - prevV):Dot(F) / DT / Config.GRAVITY
		prevV = s.vel
		local gear = s.engine.gear
		if gear > 0 and s.engine.shiftTimer == 0 and s.contacts == 2 then
			per[gear] = per[gear] or { slip = {}, accel = {} }
			table.insert(per[gear].slip, s.wheels[2].kappa * 100)
			table.insert(per[gear].accel, a)
		end
	end)
	local res = { sim = sim }
	for gi, p in pairs(per) do
		res[gi] = { slip = median(p.slip), accel = median(p.accel), n = #p.slip }
	end
	return res
end

case("M5 full-throttle pull on dirt: slip within 5 pts and accel within 0.1 G of the recording, gears 1–4 (SPEC §4 MEAS)", function()
	local r = fullThrottlePull()
	assert(not r.sim.crashed, "crashed")
	local out = {}
	for g = 1, 4 do
		local p = r[g]
		assert(p and p.n > 50, "too few samples in gear " .. g)
		assert(math.abs(p.slip - MEAS_PULL.slip[g]) <= 5, ("gear %d slip %.1f%% vs %.1f%%"):format(g, p.slip, MEAS_PULL.slip[g]))
		assert(math.abs(p.accel - MEAS_PULL.accel[g]) <= 0.1, ("gear %d accel %.2f G vs %.2f G"):format(g, p.accel, MEAS_PULL.accel[g]))
		table.insert(out, ("%d: %.1f%% %.2fG"):format(g, p.slip, p.accel))
	end
	return table.concat(out, ", ")
end)

-- Calibration report (all 5 gears), printed side by side with the recording.
function Tests.calibrate(opts)
	local r = fullThrottlePull(opts)
	local sim = r.sim
	local lines = { "gear | RoBikes slip % | MX slip % | RoBikes accel G | MX accel G | samples" }
	for gi = 1, 5 do
		local p = r[gi]
		if p then
			table.insert(lines, ("%d | %.1f | %.1f | %.2f | %.2f | %d"):format(gi, p.slip, MEAS_PULL.slip[gi], p.accel, MEAS_PULL.accel[gi], p.n))
		end
	end
	table.insert(lines, ("final speed %.1f m/s, crashed %s"):format(sim.vel.Magnitude, tostring(sim.crashed)))
	return table.concat(lines, "\n")
end

function Tests.run()
	local lines, passed = {}, 0
	local t0 = os.clock()
	for _, c in ipairs(cases) do
		local ok, res = pcall(c.fn)
		if ok then
			passed += 1
			table.insert(lines, "PASS  " .. c.name .. "  — " .. tostring(res))
		else
			table.insert(lines, "FAIL  " .. c.name .. "  — " .. tostring(res))
		end
	end
	table.insert(lines, ("%d/%d passed in %.2f s"):format(passed, #cases, os.clock() - t0))
	return table.concat(lines, "\n"), passed == #cases
end

return Tests
