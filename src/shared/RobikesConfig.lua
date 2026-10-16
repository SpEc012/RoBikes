--[[
	RobikesConfig  —  all tuning data for the Robikes physics, in SI units (metres, kg, N, s).
	Values reverse-engineered from MX Bikes as a *feel* reference (facts/physics, not copied assets).
	See FINDINGS.md for provenance. Tune freely.
]]

local Config = {}

-- Rendering scale: 1 metre = this many studs. Physics is SI; multiply positions by this to draw.
Config.STUDS_PER_METRE = 3.5
Config.GRAVITY = 9.81          -- m/s^2, applied by our own integrator
Config.STEP_HZ   = 240         -- fixed physics step
Config.AIR_DENSITY = 1.2       -- kg/m^3

-- Map Roblox materials to the game's per-surface grip + rolling resistance (dirt-tyre numbers).
-- gripMult scales tyre peak friction; resistance adds rolling drag; soft>0 lets the rear dig in.
Config.Surfaces = {
	[Enum.Material.Asphalt]   = { grip = 1.40, resistance = 1.0, soft = 0.0 },
	[Enum.Material.Concrete]  = { grip = 1.40, resistance = 1.0, soft = 0.0 },
	[Enum.Material.Pavement]  = { grip = 1.38, resistance = 1.0, soft = 0.0 },
	[Enum.Material.Cobblestone]= { grip = 1.20, resistance = 1.5, soft = 0.0 },
	[Enum.Material.Rock]      = { grip = 1.40, resistance = 1.0, soft = 0.0 },
	[Enum.Material.Slate]     = { grip = 1.30, resistance = 1.0, soft = 0.0 },
	[Enum.Material.Grass]     = { grip = 1.00, resistance = 2.0, soft = 0.3 },
	[Enum.Material.LeafyGrass]= { grip = 0.96, resistance = 3.0, soft = 0.4 },
	[Enum.Material.Ground]    = { grip = 0.98, resistance = 2.5, soft = 0.6 },  -- "soil"
	[Enum.Material.Mud]       = { grip = 0.96, resistance = 3.0, soft = 0.9 },  -- "soft soil"
	[Enum.Material.Sand]      = { grip = 0.93, resistance = 4.0, soft = 1.0 },
	[Enum.Material.Snow]      = { grip = 0.70, resistance = 4.0, soft = 0.8 },
	[Enum.Material.Salt]      = { grip = 0.95, resistance = 3.0, soft = 0.5 },
}
Config.DefaultSurface = { grip = 1.0, resistance = 2.0, soft = 0.2 }

-- Tyre models. p_D* = peak friction coeff, *_K* = slip stiffness, C/E = MF shape/curvature.
-- Fed to Pacejka.lua. (From .tyre files: dirt p_mx, tarmac m_sm.)
Config.Tyres = {
	dirt = {   -- p_mx MidSoft
		radiusF = 0.335, radiusR = 0.325,
		muX = 0.78, muY = 0.75,      -- p_Dx1 / p_Dy1
		Cx = 1.00, Cy = 1.20,        -- p_Cx1 / p_Cy1
		Kx = 30.0, Ky = 20.0,        -- p_Kx1 / p_Ky1 (slip stiffness)
		Ex = 0.0,  Ey = 0.0,
		Fz0 = 1000, loadFalloff = 0.20, -- grip lost per Fz0 of extra load
		massF = 7.5, massR = 10.0,
	},
	tarmac = {  -- m_sm Soft (supermoto slick)
		radiusF = 0.299, radiusR = 0.305,
		muX = 1.20, muY = 1.75,
		Cx = 1.20, Cy = 1.20,
		Kx = 30.0, Ky = 20.0,
		Ex = 0.0,  Ey = 0.0,
		Fz0 = 1000, loadFalloff = 0.18,
		massF = 9.14, massR = 10.5,
	},
}

-- Helper: torque in Nm at a given rpm, linear-interpolated over the curve (x already = rpm).
local function makeCurve(points)
	return function(rpm)
		if rpm <= points[1][1] then return points[1][2] end
		for i = 2, #points do
			if rpm <= points[i][1] then
				local a, b = points[i-1], points[i]
				local t = (rpm - a[1]) / (b[1] - a[1])
				return a[2] + (b[2] - a[2]) * t
			end
		end
		return points[#points][2]
	end
end
Config.makeCurve = makeCurve

Config.Bikes = {
	["450xf"] = {
		name = "MSM 450XF (4-stroke)",
		tyre = "dirt",
		mass = 110,                         -- kg (bike), rider adds lean mass separately
		inertia = Vector3.new(5.0, 2.3, 3.2), -- body-frame diag: pitch(X), yaw(Y), roll(Z) kg*m^2
		wheelbase = 1.45,                   -- m
		comHeight = 0.62,                   -- m above axle plane
		rakeAngle = 26.5,                   -- deg
		steerLock = 42,                     -- deg
		-- Engine (x-axis = rpm; see FINDINGS: inferred RPM/100 * 100). Clamp usable band to idle..limiter.
		idleRPM = 2300, shiftRPM = 9700, limiterRPM = 11600, crankInertia = 0.008,
		torqueCurve = makeCurve({ {0,1.15},{1250,9.39},{3437,24.73},{5500,32.40},{8500,40.07},
			{11600,45.0},{12250,45.63} }),
		engineBrakeCurve = makeCurve({ {0,0},{3312,-1.73},{6687,-4.22},{10000,-7.86},{11600,-10.5} }),
		clutchMaxTorque = 140,
		gearRatios = { 2.00, 1.667, 1.40, 1.077 },  -- 16:32,18:30,20:28,22:26
		primaryDrive = 76/32,
		finalDrive = 50/14,
		efficiency = 0.92,
		rearWheelInertia = 0.9,             -- kg*m^2 (wheel + disc + sprocket)
		brakeTorqueF = 900, brakeTorqueR = 450,  -- Nm
		aero = { Cx = 0.8, areaX = 1.3, Cl = 0.09, areaZ = 0.5 },
	},
	["250x"] = {
		name = "MSM 250X (2-stroke)",
		tyre = "dirt",
		mass = 100,
		inertia = Vector3.new(4.4, 2.1, 2.9),
		wheelbase = 1.44, comHeight = 0.60, rakeAngle = 26.5, steerLock = 42,
		idleRPM = 1800, shiftRPM = 9500, limiterRPM = 11000, crankInertia = 0.006,
		torqueCurve = makeCurve({ {0,0.23},{3333,15.72},{6666,28.37},{8333,30.29},
			{9958,35.47},{11666,41.41},{13291,42.94} }), -- 2-stroke "hit": steep, peaky
		engineBrakeCurve = makeCurve({ {0,0},{3375,-1.92},{6687,-4.60},{10000,-8.44} }),
		clutchMaxTorque = 110,
		gearRatios = { 2.14, 1.75, 1.45, 1.25, 1.09 },   -- 5-speed
		primaryDrive = 70/23, finalDrive = 48/13, efficiency = 0.92,
		rearWheelInertia = 0.85,
		brakeTorqueF = 850, brakeTorqueR = 420,
		aero = { Cx = 0.8, areaX = 1.25, Cl = 0.09, areaZ = 0.5 },
	},
}

-- Suspension (effective at the wheel). rate N/m, damping N*s/m, travel/rest in m.
Config.Suspension = {
	front = { rest = 0.30, travel = 0.30, rate = 5000,  bump = 1900, rebound = 1500, preload = 200 },
	rear  = { rest = 0.30, travel = 0.30, rate = 30000, bump = 9000, rebound = 6000, preload = 800 },
}

-- Rider & balance controller.
Config.Rider = {
	mass = 80, comHeight = 1.05, maxLean = math.rad(26),  -- body lean authority (rad)
}
Config.Balance = {
	Kp = 220, Kd = 55,           -- PD gains on roll (per rad / per rad/s), scaled by mass*comHeight
	maxLeanFromSteer = math.rad(38),
	steerSpeedRef = 8,           -- m/s where steering authority is ~full
	fallThreshold = math.rad(70),-- roll error that triggers a crash
	assist = 0.85,               -- 0 = hardcore, 1 = arcade-stable
}

-- Input (PC). Mobile handled in BikeController via ContextActionService.
Config.Keys = {
	throttle   = Enum.KeyCode.W,
	brakeRear  = Enum.KeyCode.S,
	brakeFront = Enum.KeyCode.LeftShift, -- hold with S, or bind as you like
	leanFwd    = Enum.KeyCode.Up,
	leanBack   = Enum.KeyCode.Down,
	steerLeft  = Enum.KeyCode.A,
	steerRight = Enum.KeyCode.D,
	clutch     = Enum.KeyCode.Space,
	shiftUp    = Enum.KeyCode.E,
	shiftDown  = Enum.KeyCode.Q,
	resetBike  = Enum.KeyCode.R,
	toggleCam  = Enum.KeyCode.C,
}
Config.Assists = { autoClutch = true, autoShift = false, antiWheelie = false }

return Config
