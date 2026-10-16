# Corrections to the pasted "Robikes" build brief

The brief's plan is sound: a 1-body fixed-step sim, raycast suspension, Magic Formula tyres, a balance
controller, and engine → clutch → gearbox → chain. But several of its numbers disagree with our evidence. Use the
values below instead. Sources: `REPORT.md` / `SPEC.md` / `FINDINGS.md`, the extracted bike files, and the live
recording `recordings/mxb_20261015-180824_350xf_winchester_data.csv` (MEAS = measured there).

## What the brief gets wrong

| # | Brief says | Evidence says | Status |
|---|---|---|---|
| 1 | Torque curve x ≈ RPM/100, "calibrate so the peak sits near redline"; 450F peak torque at 12,250 rpm | x is **revolutions per second**: RPM = x × 60. The 450F peaks at **45.6 N·m at 7,350 rpm**, with peak power ~39.6 kW at ~10,000 rpm. The declared power (37.4 kW) matches within 6% for all 5 bikes | DERIVED (`tools/check_torque_units.js`) |
| 2 | 450F 4th gear ratio 1.077 | 26/22 = **1.182** | OBS (450xf.cfg) |
| 3 | `rpm = rearWheelOmega · finalDrive · gearRatio · 60/2π` | The **primary drive is missing**: `rpm = ω_rear · primary(76/32) · gear · final(50/14) · 60/2π`. Without it, RPM is 2.4× too low | OBS + MEAS (gear steps match within 0.2%) |
| 4 | Wheel radius 0.33 for speed | Front 0.335, rear 0.325 (tyre files), but the **effective rolling radius is ~0.31 m** at the rear: RPM vs wheel speed in every gear implies 0.3096–0.3103 m | MEAS |
| 5 | Brakes frontMaxTorque 900, rearMaxTorque 450 N·m; "front much stronger" | The cfg chain gives **front 392 N·m, rear 556 N·m** at full input. The front still stops harder because weight moves onto it, not because of more disc torque | DERIVED (450xf.cfg) |
| 6 | RearSusp springRate 30000, bumpDamp 9000, reboundDamp 6000 "at the wheel" | 57,000 N/m, 9,000 / 6,000 N·s/m are **at the shock shaft**. Moving to the wheel divides by the linkage ratio **squared**. With ~2.6:1 (0.31 m wheel / 0.12 m shaft, INF) the wheel rate is ≈ 8.4 kN/m and slow bump ≈ 1.3 kN·s/m | OBS + INF |
| 7 | Rear restLength 0.30, maxTravel 0.30 | Shock shaft stroke **0.12 m** (the game reports it). Wheel travel ≈ 0.31 m via the linkage | MEAS (evnt packet) + INF |
| 8 | Front bumpDamp 1900 / reboundDamp 1500 (single value) | **3-stage** dampers with knees: fork bump 2360 / 370 / 1500 N·s/m, knees 0.05 and 1.1 m/s; fork rebound 1500 / 495 / 1500; shock bump 9000 / 1800 / 12000, knees 0.05 and 0.4; shock rebound 6000 / 4500 / 12000. The live fit supports knees at 1.1 (fork) and 0.4 (shock) | OBS + MEAS (weak) |
| 9 | preload 200 N / 800 N | Preload is a **length**: fork 7 mm, shock 12 mm (450F). It shortens the stroke: top-out = max travel − preload | MEAS (350xf: 0.291 = 0.300 − 0.009, 0.108 = 0.120 − 0.012) |
| 10 | dt = 1/240 s | MX Bikes' states land exactly on a **10 ms grid**, so its fixed step divides 10 ms; 1/240 doesn't. Use **1/300 s** (5 steps per 60 Hz frame, 3 per 10 ms) | MEAS |
| 11 | "Physics timestep Hz [U]" | Fixed step, divides 10 ms (≥ 100 Hz). Faster can't be seen through the official interface | MEAS (bound) |
| 12 | 250X idle 1800, limiter 11000, peak torque at 13,291 | Idle **1450**, MaxRPM **10,600**, shiftRPM 8,200, BreakingRPM 12,000 (no Limiter0 key). Peak torque **42.9 N·m at 7,975 rpm**, weight 96.8 kg | OBS (250x.cfg/.engn/.ini) |
| 13 | SurfaceGrip Slate 1.30, CrackedLava 1.0 | Not in the data. Dirt-tyre table: see below | OBS (p_mx_r_midsoft.tyre) |
| 14 | "loadFactor from Key0/Key1" | Key0/Key1 meaning is unknown. Use the Magic Formula's own load terms: D = (p_Dx1 + p_Dx2·dfz)·Fz with p_Dx2 = −0.06, p_Dy2 = −0.20 | OBS + INF |
| 15 | inertia (5.0, 3.2, 2.3) = roll, pitch, yaw | cfg `Inertia = 4.89, 3.19, 2.28` is in bike axes (x side, y up, z forward), so it is probably **pitch 4.89, yaw 3.19, roll 2.28**. A long body has the smallest roll inertia | INF |
| 16 | STUDS_PER_METER 3.5 | SPEC uses 1/0.28 ≈ **3.571** (Roblox: 1 stud = 0.28 m) | DESIGN |
| 17 | ODE 0.13 single precision | Confirmed: `ode-0.13`, `ODE_single_precision`, `ODE_EXT_trimesh` are in mxbikes.exe | OBS (byte search) |

## Tuning targets measured from the real game (use as M2–M5 tests)

- **Gears** (350XF, clutch out): 670 / 545 / 446 / 382 / 316 rpm per m/s of rear wheel speed. For the 450F with
  r_eff 0.31 at the limiter: 80 / 96 / 114 / 135 km/h in gears 1–4.
- **Rear wheelspin on dirt at full throttle** (median slip): 1st 15% (p90 85%), 2nd 7%, 3rd 4%, 4th 2.3%, 5th 2.6%.
  Coasting −1.4%. Hard front braking median −2.8% (p10 −13.5%).
- **Forward acceleration at full throttle:** 0.61 G (1st) down to 0.37 G (5th).
- **Static sag** (80 kg rider, stopped): fork 63 mm, shock shaft 28 mm. Riding median: 76 mm / 36 mm.
- **Shaft speeds on landings:** fork up to 4.3 m/s, shock up to 4.0 m/s. Both bottom out on big jumps.
- **Idle and limiter:** idle settles at IdleRPM (+5 rpm); the limiter overshoots by < 100 rpm.
- **Steering lock:** 42°.

## Corrected config (Luau, SI units)

```lua
-- RobikesConfig: reference numbers. Tags: OBS = bike files, DERIVED = calculated, MEAS = live telemetry,
-- INF = our reading, DESIGN = our choice.
local Config = {}

Config.STUDS_PER_METER = 1 / 0.28   -- DESIGN (Roblox: 1 stud = 0.28 m)
Config.DT = 1 / 300                 -- DESIGN, consistent with MEAS (MX Bikes steps divide 10 ms)
Config.GRAVITY = 9.81

Config.Bike450 = {
	massBike = 106.1, riderMass = 80,            -- OBS (450xf.ini weight, rider.cfg)
	chassisMass = 64.31, steerMass = 10.5,       -- OBS
	inertia = { pitch = 4.89, yaw = 3.19, roll = 2.28 }, -- OBS values, INF axis mapping (chassis only)
	rakeDeg = 26.5, steerLockDeg = 42,           -- OBS, MEAS (lock)
	idleRPM = 2300, limiterRPM = 11600, shiftRPM = 9700, stallRPM = 1600, breakingRPM = 18000, -- OBS
	crankInertia = 0.008, idleThrottle = 0.073,  -- OBS
	-- {rpm, N·m}; rpm = .engn x * 60 (x is rev/s) -- DERIVED
	torque = { {0,1.15},{750,9.39},{2063,24.73},{3300,32.40},{5100,40.07},{7350,45.63},
		{9037,41.41},{10013,37.77},{12000,27.22},{14025,7.98},{16050,1.15},{17888,0} },
	engineBrake = { {0,0},{1988,-1.73},{4013,-4.22},{6000,-7.86},{8025,-12.08},
		{11963,-23.20},{13988,-30.10},{18000,-46.87} },
	clutch = { maxTorque = 140, deadZone = 0.25, mapping = 2 },   -- OBS
	primary = 76 / 32,                                            -- OBS (2.375)
	gears = { 32/16, 30/18, 28/20, 26/22 },                       -- OBS: 2.000, 1.667, 1.400, 1.182
	finalDrive = 50 / 14,                                         -- OBS (default sprockets 14 / 50)
	efficiency = 0.92, shiftTime = 0.04,                          -- OBS
	wheel = { frontRadius = 0.335, rearRadius = 0.325, rearRollingRadius = 0.31 }, -- OBS, MEAS
	brakes = { frontMaxTorque = 392, rearMaxTorque = 556, deadZone = 0.01 },      -- DERIVED from cfg chain
	front = { -- fork, along the steering axis; spring per leg, 2 legs (INF)
		springPerLeg = 5000, legs = 2, travel = 0.30, preload = 0.007,           -- OBS, MEAS (travel)
		airArea = 0.0016, airPressure = 100e3, oilLevel = 0.10,                  -- OBS
		bump    = { knees = {0.05, 1.1}, c = {2360, 370, 1500} },                -- OBS (setting 9)
		rebound = { knees = {0.05, 1.1}, c = {1500, 495, 1500} },                -- OBS (setting 8)
	},
	rear = { -- monoshock, values AT THE SHAFT; force at the wheel = shaft force / motionRatio
		spring = 57000, stroke = 0.12, preload = 0.012, motionRatio = 2.6,      -- OBS, MEAS (stroke), INF (ratio)
		bump    = { knees = {0.05, 0.4}, c = {9000, 1800, 12000} },              -- OBS (Bump 7 + FastBump 7)
		rebound = { knees = {0.05, 0.4}, c = {6000, 4500, 12000} },              -- OBS (setting 7)
		bumpStop = { zone = 0.015, springBase = 5, risingRate = 0.4 },           -- OBS
	},
	aero = { Cx = 0.8, areaX = 1.3, Cl = 0.09 },                                 -- OBS
}

Config.Bike250 = { -- 2-stroke, OBS (250x.cfg/.engn/.ini)
	massBike = 96.8, idleRPM = 1450, maxRPM = 10600, shiftRPM = 8200, breakingRPM = 12000,
	torque = { {38,0.23},{2000,15.72},{3000,18.21},{4000,28.37},{5000,30.29},{5975,35.47},
		{7000,41.41},{7975,42.94},{8975,35.08},{10000,14.95},{10400,1.53},{10650,-0.19} },
	engineBrake = { {0,0},{2025,-1.92},{4013,-4.60},{6000,-8.44},{8025,-13.23},{10800,-21.09} },
	primary = 72 / 26,
	gears = { 28/14, 24/15, 24/18, 24/21, 21/22 },
	finalDrive = 50 / 12,
}

Config.DirtTyre = { -- p_mx_*_midsoft.tyre, OBS
	R0 = 0.34, Fz0 = 1000,
	pCx1 = 1.0, pDx1 = 0.78, pDx2 = -0.06, pEx1 = 0.0, pKx1 = 30,
	pCy1 = 1.2, pDy1 = 0.75, pDy2 = -0.20, pEy1 = 0.0, pKy1 = 20, pKy2 = 1.0,
	carcass = { springBase = 60000, springFactor = 500, pressure = 90, damper = 205 },
}

-- Dirt tyre, dry: { grip multiplier, rolling resistance } per MX surface (OBS). Roblox mapping: SPEC §9.
Config.Surfaces = {
	asphalt1 = {1.40, 1}, asphalt2 = {1.38, 1}, asphalt3 = {1.36, 1}, concrete = {1.40, 1},
	grass = {1.00, 8}, sand = {0.93, 4}, kerb = {1.00, 1}, softSoil = {0.96, 3}, soil = {0.98, 2.5},
	compactSoil = {0.93, 2}, paint = {1.20, 1}, gravel = {0.95, 8}, rock = {1.40, 1},
}

return Config
```

## Telemetry rules (so RoBikes can be compared with the same analyzer)

Report position and velocity for the chassis reference point (ground level), not the CG. Report acceleration
without gravity, in chassis axes, at the chassis CG. Report the rotation matrix with the chassis axes as its
columns, suspension length as travel left (0 = bottomed), and suspension velocity as its time derivative. Time
stamps go on a 10 ms grid. See SPEC §1.
