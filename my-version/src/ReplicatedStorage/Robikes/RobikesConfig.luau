--!nonstrict
--[[
	RobikesConfig — every tunable number in one place, in SI units (m, kg, N, s, rad).

	Bike tables are built from BikeData (numbers exported from the user's MX Bikes install by
	tools/export_luau_data.js — physics facts only, no assets). Where MX Bikes' own maths is unknown
	(its code is DRM-protected), values marked [DESIGN] are our own choices; see SPEC.md.

	STUDS_PER_METER lives here and nowhere else: physics never sees studs.
]]

local BikeData = require(script.Parent.BikeData)

local Config = {}

Config.STUDS_PER_METER = 1 / 0.28 -- [DESIGN, SPEC.md header] Roblox: 1 stud = 0.28 m (was 3.5)
Config.GRAVITY = 9.81
Config.AIR_DENSITY = 1.2
Config.PHYSICS_HZ = 300 -- [MEAS] MX Bikes states land on a 10 ms grid, so its step divides 10 ms (1/240 doesn't)
Config.MAX_SUBSTEPS = 30 -- cap per frame so a lag spike can't explode the sim
Config.DEFAULT_BIKE = "450xf"
Config.BIKE_ORDER = { "250x", "250xf", "350xf", "450xf", "450sm" }

-- Player-facing assists (toggle in game). balanceAssist 1 = arcade-stable, 0 = hardcore (the full MX Bikes feel).
-- balanceAssist also scales the other forgiving aids in BikePhysics: a lean target kept inside the grip limit,
-- a balance hold that keeps the bike up at walking pace, loop-out protection and the landing straightener.
-- tractionControl trims throttle when the rear tyre spins past a slip target.
Config.Assists = {
	autoClutch = true,
	autoShift = true,
	balanceAssist = 0.6,
	antiWheelie = false,
	tractionControl = true,
}

-- Aids tuning [DESIGN]. Each scales with balanceAssist (aid) unless noted.
Config.Aids = {
	holdK = 1.7, -- balance torque stiffness at aid 1, in units of m·g·h (1 = just cancels gravity's tip-over)
	holdZeta = 0.8, -- damping ratio of that hold
	leanMargin = 0.3, -- aid 1 asks for at most (1 − 0.3) of the grip-limited lean
	tcSlip = { 0.25, 0.10 }, -- traction control slip target at aid 0 / aid 1 (halved at full lean)
	loopPitchDeg = { 70, 38 }, -- wheelie angle where the loop-out guard starts cutting throttle, aid 0 / 1
	spinGripKeep = 0.6, -- share of the side grip lost to wheelspin that the aid keeps (× aid)
	sideGrip = 0.25, -- extra side grip at aid 1 (× aid)
	loopTorque = 1400, -- N·m nose-down the guard adds at full cut (the rider tapping the rear brake), × aid
}

-- Air and whips [DESIGN]: rider lean (arrows / rider stick) in the air throws the bike sideways (yaw + roll);
-- letting go brings it back, and just before landing the aid lines the bike up with its path.
Config.Air = {
	pitchTorque = 150, -- N·m from rider pitch input
	rollTorque = 0, -- N·m from steer input (steering in the air no longer rolls the bike: lean the rider to whip)
	yawTorque = 25, -- N·m from steer input
	whipYawMax = math.rad(70), -- full rider lean whips the nose this far across the direction of travel
	whipRollMax = math.rad(55), -- ...and lays the bike over this far into it
	whipK = 40, -- rad/s² per rad: how hard the rider throws the bike toward that attitude
	whipZeta = 0.85, -- damping ratio of the throw and the return
	whipRate = 5, -- rad/s the rider can move the whip target (a full throw takes ~0.25 s)
	whipTorqueMax = 650, -- N·m the rider can put into the bike (limits how fast a whip builds)
	returnK = 16, -- rad/s² per rad pulling yaw/roll back once released (× balance assist, at least × 0.5)
	landAlign = 2.5, -- extra straightening in the last moments before touch-down (× balance assist)
	gyroCancel = 0.85, -- share of the wheels' gyroscopic torque the rider cancels while airborne
}

-- Roblox material name -> MX surface name (MX surface grip comes from each tyre set's table) [DESIGN map]
Config.MaterialSurface = {
	Grass = "grass", LeafyGrass = "grass",
	Sand = "sand", Sandstone = "compact soil",
	Mud = "soft soil",
	Ground = "soil",
	Slate = "compact soil", Basalt = "compact soil", Limestone = "compact soil",
	Rock = "rock", Cobblestone = "rock",
	Asphalt = "asphalt1", Pavement = "asphalt2", Concrete = "concrete",
	Pebble = "gravel", Salt = "gravel",
	Snow = "soft soil", Glacier = "concrete", Ice = "concrete",
}
Config.DefaultSurface = "compact soil"

-- Rear-wheel "roost" loss [DESIGN, tuned to SPEC.md §4 MEAS slip targets]: past ~5% slip a driven rear tyre on
-- loose ground spends torque throwing dirt. Without it the saturating dirt tyre (p_Cx1 = 1) lets a full-throttle
-- wheelspin carry over every upshift (RoBikes median slip 66% / 46% in 2nd / 3rd vs MEAS 6.9% / 4.1%).
-- Extra wheel torque = k · bulldozing_factor · max(0, kappa − slip0) · Fz · R.
Config.Roost = { k = 2, slip0 = 0.05 }

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------

-- PiBoSo-style adjustable: {min, step, max} + setting index  ->  min + n*step (clamped) [INF]
function Config.settingValue(range, setting)
	if type(range) ~= "table" then
		return range
	end
	local mn, st, mx = range[1], range[2], range[3]
	local n = math.max(0, math.floor(setting or 0))
	local lo, hi = math.min(mn, mx), math.max(mn, mx)
	return math.clamp(mn + n * st, lo, hi)
end

-- Linear interpolation through {x, y} points, clamped at both ends.
function Config.curve(points, x)
	local n = #points
	if x <= points[1][1] then
		return points[1][2]
	end
	if x >= points[n][1] then
		return points[n][2]
	end
	for i = 2, n do
		local p1 = points[i]
		if x <= p1[1] then
			local p0 = points[i - 1]
			local t = (x - p0[1]) / (p1[1] - p0[1])
			return p0[2] + (p1[2] - p0[2]) * t
		end
	end
	return points[n][2]
end

-- Case-insensitive child lookup (the source files mix "Leverage0" / "leverage0").
local function ci(tbl, key)
	if type(tbl) ~= "table" then
		return nil
	end
	if tbl[key] ~= nil then
		return tbl[key]
	end
	local lk = string.lower(key)
	for k, v in pairs(tbl) do
		if type(k) == "string" and string.lower(k) == lk then
			return v
		end
	end
	return nil
end
Config.ci = ci

------------------------------------------------------------------------
-- Shared geometry [DESIGN, sized from the observed .geom: rake 26.5°, wheelbase ~1.47 m]
-- Coordinates: (forward, up) in metres, origin = ground under the rear axle at static sag.
------------------------------------------------------------------------
local GEOM = {
	wheelbase = 1.47,
	rake = math.rad(26.5),
	frontTravel = 0.30, -- along the fork [OBS front_length 0.3, MEAS max travel 0.3]
	shockStroke = 0.12, -- shaft stroke [OBS rear_length 0.12, MEAS max travel 0.12]
	rearSagTarget = 0.075, -- used only to place the mounts so the bike sits level at rest
	frontSagTarget = 0.055,
	rollingRadiusLoss = 0.015, -- [MEAS] rpm vs wheel speed in every gear implies r_eff ≈ 0.31 m for a 0.325 m tyre
	-- part masses and positions (forward, up) for the inertia / CoM calculation
	parts = {
		chassis = { 0.70, 0.62 },
		steer = { 1.15, 0.95 },
		fsusp = { 1.30, 0.55 },
		rsusp = { 0.25, 0.40 },
	},
	rider = { 0.64, 1.05 }, -- seated rider CoM [OBS rider_mass y = 1.05; fwd tuned to MEAS fork sag]
	riderOwnInertia = { pitch = 8, yaw = 4, roll = 6 }, -- [DESIGN] 80 kg body
}
Config.GEOM = GEOM

------------------------------------------------------------------------
-- Build one bike description (SI) from BikeData
------------------------------------------------------------------------
local function buildCurve(points)
	local out = {}
	for i, p in ipairs(points) do
		out[i] = { p[1], p[2] }
	end
	return out
end

local function brakeMaxTorque(wheelCfg)
	-- hydraulic chain [OBS]: lever force * leverage / master-cylinder area -> kPa; * PressureToTorque -> N·m
	local b = ci(wheelCfg, "Brake")
	if not b then
		return 0, 0
	end
	local mc = ci(b, "MasterCylinder" .. tostring(ci(b, "mastercylindersetting") or 0)) or {}
	local lev = ci(b, "Leverage" .. tostring(ci(b, "leveragesetting") or 0)) or {}
	local disc = ci(b, "disc" .. tostring(ci(b, "discsetting") or 0)) or {}
	local force = ci(b, "RiderMaxForce") or 40
	local ratio = ci(lev, "ratio") or 10
	local d = ci(mc, "Diameter") or 0.013
	local area = math.pi * (d * 0.5) ^ 2
	local kPa = force * ratio / area / 1000
	local torque = kPa * (ci(disc, "PressureToTorque") or 0.15)
	return torque, kPa
end

local function damperTable(tbl, setting)
	local v = tbl and tbl["setting" .. tostring(setting or 0)]
	if type(v) == "number" then
		return { v }
	end
	return v or { 0 }
end

-- Setup knobs the player can change (index-based, like the game's own setup screen).
-- Returns the default setting indices and their [min, max] ranges for a bike.
function Config.setupDefaults(id)
	local d = BikeData.bikes[id]
	local fs, rs, dl = d.front_suspension, d.rear_suspension, d.driveline
	local function count(tbl, prefix)
		local n = 0
		while tbl and tbl[prefix .. n] ~= nil do
			n += 1
		end
		return n
	end
	local function steps(range)
		return math.floor((range[3] - range[1]) / range[2] + 0.5)
	end
	local fd, rdmp = fs.Damper or {}, rs.Damper or {}
	local defaults = {
		FSprocketSetting = dl.FSprocketSetting or 0,
		RSprocketSetting = dl.RSprocketSetting or 0,
		forkSpring = fs.Spring.setting or 0,
		shockSpring = rs.Spring.setting or 0,
		forkBump = fd.BumpSetting or 0,
		forkRebound = fd.ReboundSetting or 0,
		shockBump = rdmp.BumpSetting or 0,
		shockRebound = rdmp.ReboundSetting or 0,
	}
	local limits = {
		FSprocketSetting = { 0, count(dl.FSprocket, "gear") - 1 },
		RSprocketSetting = { 0, count(dl.RSprocket, "gear") - 1 },
		forkSpring = { 0, steps(fs.Spring.range) },
		shockSpring = { 0, steps(rs.Spring.range) },
		forkBump = { 0, count(fd.Bump, "setting") - 1 },
		forkRebound = { 0, count(fd.Rebound, "setting") - 1 },
		shockBump = { 0, count(rdmp.Bump, "setting") - 1 },
		shockRebound = { 0, count(rdmp.Rebound, "setting") - 1 },
	}
	return defaults, limits
end

-- Human-readable setup values for the HUD.
function Config.describeSetup(id, setup)
	local d = BikeData.bikes[id]
	local dl, fs, rs = d.driveline, d.front_suspension, d.rear_suspension
	return {
		FSprocketSetting = tostring(dl.FSprocket["gear" .. setup.FSprocketSetting]) .. "T",
		RSprocketSetting = tostring(dl.RSprocket["gear" .. setup.RSprocketSetting]) .. "T",
		forkSpring = string.format("%d N/m", Config.settingValue(fs.Spring.range, setup.forkSpring)),
		shockSpring = string.format("%d N/m", Config.settingValue(rs.Spring.range, setup.shockSpring)),
		forkBump = "click " .. setup.forkBump,
		forkRebound = "click " .. setup.forkRebound,
		shockBump = "click " .. setup.shockBump,
		shockRebound = "click " .. setup.shockRebound,
	}
end

function Config.buildBike(id, setup)
	id = id or Config.DEFAULT_BIKE
	local d = BikeData.bikes[id]
	assert(d, "unknown bike " .. tostring(id))
	local tyreType = (d.info and d.info.tyres_type) or "mx"
	local tyres = BikeData.tyres[tyreType] or BikeData.tyres.mx
	local eng, gb = d.engine, d.gearbox
	-- apply setup overrides on shallow copies (the data tables stay untouched)
	setup = setup or {}
	local dl = table.clone(d.driveline)
	local fs = table.clone(d.front_suspension)
	local rs = table.clone(d.rear_suspension)
	fs.Spring = table.clone(fs.Spring)
	rs.Spring = table.clone(rs.Spring)
	fs.Damper = table.clone(fs.Damper or {})
	rs.Damper = table.clone(rs.Damper or {})
	if setup.FSprocketSetting then dl.FSprocketSetting = setup.FSprocketSetting end
	if setup.RSprocketSetting then dl.RSprocketSetting = setup.RSprocketSetting end
	if setup.forkSpring then fs.Spring.setting = setup.forkSpring end
	if setup.shockSpring then rs.Spring.setting = setup.shockSpring end
	if setup.forkBump then fs.Damper.BumpSetting = setup.forkBump end
	if setup.forkRebound then fs.Damper.ReboundSetting = setup.forkRebound end
	if setup.shockBump then
		rs.Damper.BumpSetting = setup.shockBump
		rs.Damper.FastBumpSetting = setup.shockBump
	end
	if setup.shockRebound then rs.Damper.ReboundSetting = setup.shockRebound end

	local bike = { id = id, name = d.name, tyreType = tyreType, setup = setup }

	-- ----- masses & inertia (computed from parts) -----
	local tyreF, tyreR = tyres.front, tyres.rear
	local wheelF = { mass = tyreF.mass or 7.5, pos = { GEOM.wheelbase, tyreF.Radius } }
	local wheelR = { mass = tyreR.mass or 10, pos = { 0, tyreR.Radius } }
	local items = {
		{ m = d.chassis.Mass, p = GEOM.parts.chassis, own = { pitch = d.chassis.Inertia[1], yaw = d.chassis.Inertia[2], roll = d.chassis.Inertia[3] } },
		{ m = d.steer.Mass, p = GEOM.parts.steer },
		{ m = fs.Mass, p = GEOM.parts.fsusp },
		{ m = rs.Mass, p = GEOM.parts.rsusp },
		{ m = wheelF.mass, p = wheelF.pos, own = { pitch = 0.24, yaw = 0.24, roll = 0.47 } },
		{ m = wheelR.mass, p = wheelR.pos, own = { pitch = 0.26, yaw = 0.26, roll = 0.49 } },
	}
	local bikeParts = 0
	for _, it in ipairs(items) do
		bikeParts += it.m
	end
	-- the .ini weight includes fuel and small parts: put the remainder on the chassis point
	local extra = math.max(0, (d.info.weight or bikeParts) - bikeParts)
	table.insert(items, { m = extra, p = GEOM.parts.chassis })

	bike.bikeMass = 0
	local sf, su = 0, 0
	for _, it in ipairs(items) do
		bike.bikeMass += it.m
		sf += it.m * it.p[1]
		su += it.m * it.p[2]
	end
	bike.bikeCoM = { sf / bike.bikeMass, su / bike.bikeMass }
	bike.riderMass = 80 -- [OBS rider.cfg mass = 80]
	local rider = { m = bike.riderMass, p = GEOM.rider, own = GEOM.riderOwnInertia }
	table.insert(items, rider)
	bike.mass = bike.bikeMass + bike.riderMass
	local cf = (sf + rider.m * rider.p[1]) / bike.mass
	local cu = (su + rider.m * rider.p[2]) / bike.mass
	bike.com = { cf, cu } -- (forward, up) of the whole system, rider seated

	local Ipitch, Iyaw, Iroll = 0, 0, 0
	for _, it in ipairs(items) do
		local df, du = it.p[1] - cf, it.p[2] - cu
		Ipitch += it.m * (df * df + du * du) + (it.own and it.own.pitch or 0)
		Iyaw += it.m * (df * df) + (it.own and it.own.yaw or 0)
		Iroll += it.m * (du * du) + (it.own and it.own.roll or 0)
	end
	-- body axes: X = right (pitch), Y = up (yaw), Z = back (roll)
	bike.inertia = Vector3.new(Ipitch, Iyaw, Iroll)

	-- ----- wheels / suspension hardpoints, body frame relative to the CoM -----
	-- Static axle positions (forward, up) from the ground origin, then shift by CoM.
	local function bodyPoint(fwd, up)
		-- Roblox body frame: +X right, +Y up, -Z forward
		return Vector3.new(0, up - cu, -(fwd - cf))
	end
	-- Preload is a length that pre-compresses the spring AND shortens the usable stroke [MEAS: 350XF fork top-out
	-- 0.291 = 0.300 − 0.009, shock 0.108 = 0.120 − 0.012].
	local forkPreload = Config.settingValue(fs.Preload and fs.Preload.range or { 0, 0, 0 }, fs.Preload and fs.Preload.setting)
	local shockPreload = Config.settingValue(rs.Preload and rs.Preload.range or { 0, 0, 0 }, rs.Preload and rs.Preload.setting)
	local forkTravel = GEOM.frontTravel - forkPreload
	local frontVerticalTravel = forkTravel * math.cos(GEOM.rake)
	-- Rear linkage: motion ratio (wheel/shaft) falls linearly from ratioTop to ratioBottom over the wheel travel.
	-- Ratios chosen so the static shaft sag matches MEAS (~28–30 mm); wheel travel then follows from the stroke.
	local ratioTop, ratioBottom = 2.45, 2.25 -- [DESIGN fitted to MEAS]
	local strokeEff = GEOM.shockStroke - shockPreload
	local rearTravel = strokeEff * (ratioBottom - ratioTop) / math.log(ratioBottom / ratioTop) -- ∫dx/MR = stroke
	local frontStatic = bodyPoint(GEOM.wheelbase, tyreF.Radius)
	local rearStatic = bodyPoint(0, tyreR.Radius)
	bike.wheels = {
		{
			name = "front",
			radius = tyreF.Radius,
			rollingRadius = tyreF.Radius - GEOM.rollingRadiusLoss, -- [MEAS] used for slip, drive and the speedo
			spinInertia = (tyreF.Inertia and tyreF.Inertia[1]) or 0.47,
			travel = frontVerticalTravel,
			-- mount = wheel centre at full compression
			mount = frontStatic + Vector3.new(0, frontVerticalTravel - GEOM.frontSagTarget, 0),
			tyre = tyreF,
			compound = tyres.compound.front,
		},
		{
			name = "rear",
			radius = tyreR.Radius,
			rollingRadius = tyreR.Radius - GEOM.rollingRadiusLoss,
			spinInertia = (tyreR.Inertia and tyreR.Inertia[1]) or 0.49,
			travel = rearTravel,
			mount = rearStatic + Vector3.new(0, rearTravel - GEOM.rearSagTarget, 0),
			tyre = tyreR,
			compound = tyres.compound.rear,
		},
	}
	bike.wheelbase = GEOM.wheelbase
	bike.comHeight = cu
	bike.rake = GEOM.rake

	-- ----- front fork (two legs) [OBS values, INF law] -----
	local fd = fs.Damper or {}
	bike.fork = {
		legs = 2,
		spring = Config.settingValue(fs.Spring.range, fs.Spring.setting), -- N/m per leg
		preload = forkPreload,
		airArea = fs.Area or 0.0016,
		airPressure = (fs.AirPressure or 100) * 1000, -- Pa
		airLength = 0.40 - Config.settingValue(fs.Oil and fs.Oil.range or { 0.1, 0, 0.1 }, fs.Oil and fs.Oil.setting), -- [DESIGN]
		travel = forkTravel,
		cosRake = math.cos(GEOM.rake),
		bump = damperTable(fd.Bump, fd.BumpSetting),
		rebound = damperTable(fd.Rebound, fd.ReboundSetting),
		t0 = math.abs(fd.BumpThreshold0 or 0.05),
		t1 = math.abs(fd.BumpThreshold1 or 1.1),
		rt0 = math.abs(fd.ReboundThreshold0 or 0.05),
		rt1 = math.abs(fd.ReboundThreshold1 or 1.1),
	}

	-- ----- rear shock through a progressive linkage -----
	local rdmp = rs.Damper or {}
	local bs = rs.BumpStop or {}
	local slowBump = damperTable(rdmp.Bump, rdmp.BumpSetting)
	local fastBump = damperTable(rdmp.FastBump, rdmp.FastBumpSetting)
	bike.shock = {
		spring = Config.settingValue(rs.Spring.range, rs.Spring.setting), -- N/m at the shaft
		preload = shockPreload,
		ratioTop = ratioTop, -- wheel/shaft motion ratio at full extension
		ratioBottom = ratioBottom, -- ...and at full compression (mildly progressive)
		travel = rearTravel,
		stroke = strokeEff,
		-- 3 stages: slow bump from Bump, mid/fast from FastBump when BumpSeparateSetting is on
		bump = (rdmp.BumpSeparateSetting == 1) and { slowBump[1], fastBump[1] or slowBump[1], fastBump[2] or slowBump[1] } or slowBump,
		rebound = damperTable(rdmp.Rebound, rdmp.ReboundSetting),
		t0 = math.abs(rdmp.BumpThreshold0 or 0.05),
		t1 = math.abs(rdmp.BumpThreshold1 or 0.4),
		rt0 = math.abs(rdmp.ReboundThreshold0 or 0.05),
		rt1 = math.abs(rdmp.ReboundThreshold1 or 0.4),
		bumpStopZone = Config.settingValue(bs.range or { 0.015, 0, 0.015 }, bs.setting),
		bumpStopK = (bs.SpringBase or 5) * 1e5, -- [DESIGN unit mapping]
		bumpStopRise = (bs.SpringRisingRate or 0.4) * 1e3,
		bumpStopC = (bs.DampingBase or 0.5) * 1e4,
	}

	-- ----- engine & drivetrain -----
	local primary = eng.Ratio0[2] / eng.Ratio0[1]
	local gears = {}
	for g = 0, (gb.NumGears or 4) - 1 do
		local pair = gb.gearing["ratio" .. g]
		gears[g + 1] = pair[2] / pair[1] -- (driving, driven) -> driven/driving [DERIVED]
	end
	local fs_ = dl.FSprocket["gear" .. tostring(dl.FSprocketSetting or 0)]
	local rs_ = dl.RSprocket["gear" .. tostring(dl.RSprocketSetting or 0)]
	local autoshift = {}
	for g = 1, #gears do
		local a = gb.autoshift and gb.autoshift["gear" .. g]
		autoshift[g] = { up = a and a.up or nil, down = a and a.down or nil }
	end
	bike.engine = {
		torque = buildCurve(d.curves.torque), -- x = crank rev/s [DERIVED], y = N·m
		brake = buildCurve(d.curves.brake),
		inertia = eng.Inertia,
		idleRPM = eng.IdleRPM,
		idleThrottle = eng.IdleThrottle,
		limiterRPM = eng.Limiter0 or eng.MaxRPM,
		maxRPM = eng.MaxRPM,
		shiftRPM = eng.shiftRPM or eng.MaxRPM,
		breakingRPM = eng.BreakingRPM,
		stallRPM = eng.stall and eng.stall.RPM or 1200,
		clutchMaxTorque = eng.Clutch.MaxTorque,
		clutchMapping = eng.Clutch.Mapping or 2,
		clutchDeadZone = eng.Clutch.DeadZone or 0.25,
	}
	bike.drivetrain = {
		primary = primary,
		gears = gears,
		final = rs_ / fs_,
		efficiency = dl.Efficiency or 0.92,
		firstAxisInertia = dl.FirstAxisInertia or 0.0025,
		secondAxisInertia = dl.SecondAxisInertia or 0.00075,
		upshiftTime = gb.UpshiftTime or 0.04,
		downshiftTime = gb.DownshiftTime or 0.04,
		autoshift = autoshift,
		autoClutchMin = d.autoclutch and d.autoclutch.minRPM or 2500,
		autoClutchMax = d.autoclutch and d.autoclutch.maxRPM or 3000,
	}

	-- ----- brakes -----
	local frontT, frontKPa = brakeMaxTorque(d.wheel0)
	local rearT, rearKPa = brakeMaxTorque(d.wheel1)
	bike.brakes = { frontTorque = frontT, rearTorque = rearT, frontKPa = frontKPa, rearKPa = rearKPa }

	-- ----- aero [OBS Min/MaxCdA, Cl] -----
	bike.aero = {
		cdaTuck = d.aero.MinCdA or 0.544,
		cdaUpright = d.aero.MaxCdA or 0.608,
		cl = d.aero.Cl or 0.09,
		liftArea = 0.7,
	}

	-- ----- steering & rider [OBS lock 42°, DESIGN controller] -----
	bike.steer = {
		lock = math.rad(d.steer.Lock or 42),
		rate = 5.0, -- rad/s max steering speed
		kp = 24, -- desired roll response (rad/s² per rad) — see SPEC §6
		kd = 20, -- well damped: the rider shouldn't overshoot the lean he asked for
		slideCatch = 0.85, -- share of the slide angle the rider steers into (opposite lock)
		ki = 10, -- integral on lean error: tyre slip means the kinematic steer never quite holds the lean
		maxLeanDeg = 50, -- design cap; the grip cap below usually wins
		gripLeanFactor = 0.8, -- ask for at most atan(0.8 * lateral grip) of lean
	}
	bike.rider = {
		maxLat = 0.25,
		maxLong = 0.30,
		k = 4000,
		c = 400,
		mass = bike.riderMass,
	}
	bike.helpers = {
		wheelieMinRatio = d.wheelinghelp and d.wheelinghelp.MinRatio or 15, -- [INF] % of load on the front wheel
		wheelieMaxRatio = d.wheelinghelp and d.wheelinghelp.MaxRatio or 25,
		wheelieThrottle = d.wheelinghelp and d.wheelinghelp.Throttle or 0.5,
		-- [OBS shifthelp] throttle lift on upshifts, blip on downshifts
		liftThrottle = d.shifthelp and d.shifthelp.LiftThrottle or 0.3,
		liftTime = d.shifthelp and d.shifthelp.LiftTime or 0.1,
		blipThrottle = d.shifthelp and d.shifthelp.BlipThrottle or 0.4,
		blipTime = d.shifthelp and d.shifthelp.BlipTime or 0.1,
	}
	-- chassis collision / crash probe points, body frame relative to CoM (metres) [DESIGN]
	bike.probes = {
		{ name = "frontFender", pos = bodyPoint(1.10, 0.75), radius = 0.12 }, -- fenders scrape on big compressions, not a crash,
		{ name = "rearFender", pos = bodyPoint(-0.25, 0.90), radius = 0.12 },
		{ name = "skidPlate", pos = bodyPoint(0.70, 0.28), radius = 0.08 },
		{ name = "barLeft", pos = bodyPoint(1.02, 1.05) + Vector3.new(-0.40, 0, 0), radius = 0.06, crashOnTouch = true },
		{ name = "barRight", pos = bodyPoint(1.02, 1.05) + Vector3.new(0.40, 0, 0), radius = 0.06, crashOnTouch = true },
		{ name = "pegLeft", pos = bodyPoint(0.55, 0.35) + Vector3.new(-0.20, 0, 0), radius = 0.05 },
		{ name = "pegRight", pos = bodyPoint(0.55, 0.35) + Vector3.new(0.20, 0, 0), radius = 0.05 },
		{ name = "head", pos = bodyPoint(0.62, 1.62), radius = 0.15, isHead = true },
	}
	bike.surfaceTable = tyres.compound.rear
	return bike
end

function Config.surfaceFromMaterial(materialName)
	return Config.MaterialSurface[materialName] or Config.DefaultSurface
end

Config.BikeData = BikeData
return Config
