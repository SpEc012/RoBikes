# RoBikes physics SPEC (Step 6)

Behavior specification for a motocross bike simulator, built from the observed behavior and data of MX Bikes
(see `REPORT.md`, `FINDINGS.md`). **No game code was copied** (the game's code was never read; it is
DRM-protected). Formulas below are public engineering models or our own designs, and each one is tagged:

- **[OBS]** matches observed data or official documentation
- **[MEAS]** measured live through the official telemetry plugin
  (`recordings/mxb_20261015-180824_350xf_winchester_data.csv`, REPORT §9)
- **[INF]** our best inference about how MX Bikes does it
- **[DESIGN]** our own choice where MX Bikes is unknown

Units are SI internally (m, kg, s, N, rad). Roblox rendering uses `STUDS_PER_METER = 1 / 0.28`.

---

## 1. Coordinate frames and state

- World: +Y up, gravity `g = 9.81 m/s²` [DESIGN]. Bike frame: +Z forward, +Y up, +X left [OBS: `.geom` uses
  y-up, z-forward; front wheel z > rear wheel z].
- **Bike state** (what the sim integrates):
  `position, orientation, linearVelocity, angularVelocity` (chassis rigid body), `steerAngle, steerRate`,
  `forkTravel, forkVel`, `shockTravel, shockVel`, `wheelSpin[2]`, `engineRPS`, `gear`, `clutchLock`, `crashed`,
  rider offsets `riderLat, riderLong` and their rates.
- **Inputs** (each frame, all clamped): `throttle 0..1`, `frontBrake 0..1`, `rearBrake 0..1`, `clutch 0..1`
  (1 = lever pulled) [OBS: telemetry convention], `steer -1..1` (lean request), `riderLean -1..1`,
  `riderPitch -1..1`, `shiftUp`, `shiftDown`.
- **Outputs / telemetry**: the same set MX Bikes publishes to plugins [OBS: official `SPluginsBikeData_t`,
  size-checked to 188 bytes]: RPM, gear (0 = N), speedometer (m/s), position, velocity, acceleration (G, chassis
  frame), yaw/pitch/roll (deg) and rates, suspension length and velocity (front, rear), crashed, steer (deg,
  negative = right), throttle, brakes, clutch, wheel speeds (m/s), wheel surface material (0 = airborne), brake
  pressure (kPa), steering torque (N·m).
- **What the telemetry numbers mean** [MEAS]. RoBikes' telemetry follows the same rules, so the same analyzer
  works on both:
  - `position` and `velocity` are for the chassis reference point (ground level in `.geom` coordinates), not the CG.
  - `speedometer` = |velocity|.
  - `acceleration` = kinematic (no gravity: 0 at rest) at the chassis CG, ~0.62 m up the chassis axis, in chassis
    axes, in G.
  - Rotation matrix: its columns are the chassis axes (side, up, forward) in world space; world +Y is up.
  - `suspLength` = travel left before bottom-out (0 = bottomed, top-out = max travel − preload).
  - `suspVelocity` = d(`suspLength`)/dt, so compression is negative.
  - Time stamps lie on a 10 ms grid.

## 2. Bike definition data

A bike is a table of the same groups MX Bikes uses [OBS]: `engine`, `gearbox`, `driveline`, `wheel[0|1].brake`,
`chassis`, `aero`, `steer`, `front_suspension`, `rear_suspension`, `geom`, `helpers`.

- **Adjustable values** use `{min, step, max, setting}`, and the value is `min + setting·step`, clamped to
  `[min, max]` [INF]. Edge cases: a setting below 0 becomes 0; a setting above the maximum becomes the
  max index.
- **Curves** are `{x, y}` points with linear interpolation. Below the first point clamp to the first y,
  above the last point clamp to the last y [DESIGN].
- RoBikes ships 5 bike tables modeled on the observed ranges: 250 2-stroke, 250F, 350F, 450F, 450 SM.
  Shared items are steering, geometry, aero and brakes [OBS: identical across all 5 bikes].

## 3. Engine, clutch, gearbox, driveline

**Torque**
- Torque curve `Tfull(rps)` and closed-throttle curve `Tbrake(rps) ≤ 0`, where x = engine
  **revolutions per second** [OBS data, DERIVED unit: peak T·2π·x ≈ declared kW for all 5 bikes].
- Engine torque `Te = θ·Tfull(rps) + (1−θ)·Tbrake(rps)`, where `θ` is the effective throttle [INF].
- **Idle:** if RPM < IdleRPM then `θ = max(θ, IdleThrottle·k)`, with k ramping from 1 at IdleRPM−300 down to 0
  at IdleRPM [DESIGN] [OBS values: IdleThrottle 0.073, IdleRPM 2300]. **Test:** idle settles at IdleRPM ± 20
  [MEAS: 2305 for IdleRPM 2300].
- **Limiter:** above `Limiter` RPM, `θ = 0` until RPM drops 150 below it [DESIGN hysteresis] [OBS limiter values].
  **Test:** RPM peaks at most ~100 above the limiter [MEAS: 13,485 for a 13,400 limiter].
- **Stall:** if the clutch is locked and RPM < `Stall.RPM` (1600), the engine stops (rps → 0, `stalled = true`).
  It restarts with the starter: `starter.torque` up to `starter.maxRPM` [OBS values, DESIGN logic]. Stopping in gear
  stalls the engine [MEAS: RPM ≈ 0 at standstill in gear].
- **Over-rev:** RPM is clamped at `BreakingRPM` [DESIGN: no engine damage in v1].

**Crank inertia:** `Ie = engine.Inertia + FirstAxisInertia·r_p²`, where r_p is the primary ratio [DESIGN lumping].

**Clutch** [DESIGN law, OBS parameters]
- `engage = clamp((1 − clutchInput − DeadZone)/(1 − DeadZone), 0, 1)` [OBS DeadZone 0.25]
- `capacity = MaxTorque · engage^Mapping` [OBS MaxTorque 140, Mapping 2]
- If `|ω_engine − ω_input| < 0.5 rad/s` and the required torque is within capacity, the clutch is **locked**
  (rigid coupling). Otherwise it **slips** with torque `capacity·sign(Δω)`.
- **Auto-clutch** helper: engage ramps 0 → 1 between `minRPM` and `maxRPM` (2500–3000) when in gear [OBS values].

**Gearbox** [OBS values, DESIGN timing logic]
- Gears 0 = neutral, 1..N. A pair `(a, b)` gives ratio `b/a` [MEAS: gear-to-gear RPM steps match within 0.2%].
- A shift takes `UpshiftTime`/`DownshiftTime` (0.04 s). Drive torque is cut during the shift. Shifts are
  sequential; down from 1 goes to neutral; up from neutral goes to 1.

**Driveline** [OBS]
- Total ratio `R = primary · gear · (RSprocket/FSprocket)`. Wheel drive torque = `T_clutch · R · Efficiency`
  (0.92). Reflected inertia is added to the rear wheel. [MEAS]
- **Effective rolling radius** for wheel speed and tyre slip: `r_eff = 0.31 m` at the rear, not the tyre file's
  0.325 m [MEAS: RPM per m/s of rear wheel speed in gears 1–4 implies 0.3096–0.3103 m]. Front: r_eff ≈ 0.95 ×
  0.335 = 0.32 m [INF, same squash].
- **Behavior tests** (clutch in, no wheelspin):
  - 350xf, RPM per m/s of rear wheel speed: 670 / 545 / 446 / 382 / 316 in gears 1–5, ±1% [MEAS].
  - 450F, top gear at the limiter with r_eff 0.31: 11600/60·2π / 10.024 · 0.31 ≈ 37.6 m/s (135 km/h) on flat ground
    with no drag [DERIVED from MEAS].

## 4. Tyres

**Load:** the tyre is a radial spring + damper.
`k = springBase + springFactor·pressure_kPa` (60000 + 500·90 = 105 kN/m), damping `c = damper` [INF], and
`Fz = max(0, k·penetration + c·penetrationRate)`. Fz is 0 when airborne.

**Slips:**
- longitudinal `κ = (ω·Reff − Vx)/max(|Vx|, 1.0)` [DESIGN low-speed guard]
- lateral `α = atan2(−Vy, max(|Vx|, 1.0))`
- camber `γ` = wheel lean angle relative to the ground normal

**Magic Formula, motorcycle form** [INF: coefficient names match Pacejka's motorcycle MF; standard
public formulas]. With `dfz = (Fz − Fz0)/Fz0` and `μs` = surface grip:

- **Longitudinal:**
  - `Cx = p_Cx1`
  - `Dx = (p_Dx1 + p_Dx2·dfz)·μs·Fz`
  - `Kx = Fz·(p_Kx1 + p_Kx2·dfz)·e^(p_Kx3·dfz)`
  - `Bx = Kx/(Cx·Dx)`
  - `Ex = min(1, p_Ex1 + p_Ex2·dfz + p_Ex3·dfz²)·(1 − p_Ex4·sgn κ)`
  - `Fx0 = Dx·sin(Cx·atan(Bx·κ − Ex·(Bx·κ − atan(Bx·κ))))`
- **Lateral:**
  - `Dy = (p_Dy1 + p_Dy2·dfz)·μs·Fz`
  - `Kyα = p_Ky1·Fz0·sin(2·atan(Fz/(p_Ky2·Fz0)))·(1 − p_Ky3·|γ|)`
  - `Kyγ = Fz·p_Ky6`
  - `By = Kyα/(p_Cy1·Dy)`
  - `Bγ = Kyγ/(p_Cy2·Dy)`
  - `Fy0 = Dy·sin(p_Cy1·atan(By·α − Ey(…)) + p_Cy2·atan(Bγ·γ − Eγ(…)))`, with `Ey = p_Ey1` and `Eγ = p_Ey5`
- **Combined slip:**
  - `Gxα = cos(r_Cx1·atan(r_Bx1·cos(atan(r_Bx2·κ))·α))`
  - `Gyκ = cos(r_Cy1·atan(r_By1·cos(atan(r_By2·α))·κ))`
  - `Fx = Fx0·Gxα` and `Fy = Fy0·Gyκ`
- **Rolling resistance:** `Fr = q_sy1·Fz·resistance(surface)`, against the rolling direction [INF].

**Surface grip** `μs = dry_grip` (or `wet_grip` when wet), per surface [OBS table, 13 surfaces].

**Edge cases:**
- Fz = 0 gives zero force.
- At |V| < 0.5 m/s a blend toward a "sticky" damping force prevents jitter [DESIGN].
- NaN guards: any non-finite force becomes 0 and is logged.

**Behavior tests:**
- Fx0 is odd in κ, has a single peak near κ ≈ 0.1–0.2, and decays after the peak.
- The peak scales with μs (sand < compact soil < asphalt).
- Fy at γ = 30° with α = 0 is > 0, i.e. camber thrust exists.
- **Whole-bike slip targets on dirt** [MEAS, 350xf on Winchester]. Slip = wheel speed ÷ ground speed − 1.
  - Full throttle, median rear slip: 1st 15% (p90 85%), 2nd 7%, 3rd 4%, 4th 2.3%, 5th 2.6%.
  - Mean forward acceleration is highest at 6–9% slip.
  - Coasting rear: −1.4%. Free-rolling front: −0.8%.
  - Hard front braking: median −2.8%, p10 −13.5%.
  - Median forward acceleration at full throttle: 0.61 G in 1st down to 0.37 G in 5th.

## 5. Suspension

- **Fork** (along the steering axis): travel 0..0.30 m [MEAS: the game reports max travel 0.30 / 0.12 m, and both
  ends reach 0 on big landings]. Two legs [INF], each with:
  - coil spring `k_f` (range 4400..5600 N/m) and preload (m)
  - air spring `F_air = P0·A·(L0/(L0 − x) − 1)` with `L0 = 0.40 − oilLevel` [DESIGN], `P0 = 100 kPa`,
    `A = 0.0016 m²` [OBS]
- **Shock** (through the linkage): shaft stroke 0..0.12 m [MEAS: telemetry `suspLength` rear is the shaft, 0..0.12 − preload]. Wheel travel 0..0.31 m
  using a progressive motion ratio from 3.0 (top) down to 2.2 (bottom) [DESIGN].
  `F_wheel = F_shaft / ratio(x)`. Spring 48–60 kN/m plus preload [OBS].
- **Preload** [MEAS]: preload p shortens the usable stroke. The fork tops out at `0.30 − p` and the shock at
  `0.12 − p` (350xf: fork 0.291 with p = 9 mm, shock 0.108 with p = 12 mm, exact). So the spring is already squeezed
  by p at top-out, and its force there is `k·p` [INF].
- **3-stage damper** [INF law, OBS tables, MEAS knees]: for shaft speed `v` with thresholds `t0 < t1`:
  `F = c1·v` for `|v| ≤ t0`; `F = c1·t0 + c2·(|v| − t0)` for `t0 < |v| ≤ t1`;
  `F = c1·t0 + c2·(t1 − t0) + c3·(|v| − t1)` beyond. The sign follows v. Bump and rebound use their own tables;
  the rear fast-bump table replaces c2 and c3 for compression.
  - Compression = negative shaft speed, so cfg bump thresholds are negative [MEAS].
  - The live fit prefers knees at the cfg speeds (fork bump 1.1 m/s, shock bump 0.4 m/s), and 3 stages beat 1
    [MEAS, weak effect].
  - Shaft speeds to support: fork up to ~4.3 m/s, shock up to ~4.0 m/s on landings. 46% / 38% of compression is
    above the first knee [MEAS].
- **Bump stop** (rear, last 15 mm): `F = SpringBase·1000·d·(1 + SpringRisingRate·d·1000)`, with
  `d` = depth into the stop zone [DESIGN mapping of OBS params].
- **Top-out:** travel is clamped at 0 with a stiff spring (2×10⁵ N/m) [DESIGN].
- **Behavior tests:**
  - static rider sag (80 kg rider, stopped, default setup): fork ≈ 63 mm, shock shaft ≈ 28 mm (wheel ≈ 70 mm with
    the ~2.6 linkage ratio) [MEAS on the 350xf, ±10 mm for the 450F]. Riding median: fork 76 mm, shock 36 mm
  - damper force is continuous at both thresholds and monotonic in |v|
  - more bump clicks give more force

## 6. Brakes and steering

**Brakes** [OBS chain]: `P_kPa = (input·RiderMaxForce·leverage) / (π·(D/2)²) / 1000`,
`T_brake = P_kPa·PressureToTorque`, applied against the wheel spin direction. When the wheel is
(nearly) stopped, brake friction holds it static, with no reversal. **Check:** 450F front at full lever gives
P ≈ 2515 kPa and T ≈ 392 N·m; rear P ≈ 4209 kPa and T ≈ 556 N·m [DERIVED from cfg]. (The game's telemetry
brake-pressure fields are not filled in this build [MEAS], so these stay derived.)

**Steering geometry** [OBS]:
- rake 26.5°, fork offset from geom, lock ±42° [MEAS: p99 ±42.03°], steering body mass 10.5 kg.
- Trail comes from rake, offset and the front radius.
- Gyroscopic torque from wheel spin (wheel inertia from the tyre data) is included [DESIGN].

**Rider steering controller** [INF that MX Bikes uses one: `spg/sdg/sig` gains; DESIGN for the exact law]:
- The player's `steer` input sets the **target lean** `φt = steer·φmax(v)`, where `φmax` rises from 15° at
  2 m/s to 50° at 15 m/s.
- Handlebar torque = `Kp·(φt − φ) − Kd·φ̇ − Ks·steerRate`, clamped to ±60 N·m.
- Countersteering emerges from the physics. **Behavior test:** at 10 m/s, a step to the right makes the bars
  first turn **left** (steer > 0), then the bike leans right and turns right.

**Low-speed stability assist** [INF: `stability/roll factor,rate` names exist; DESIGN law]: a roll-righting torque
`τ = −kr·(φ − φt)·max(0, 1 − v/6)` keeps the bike upright below ~6 m/s (MX Bikes riders dab their feet).

## 7. Rider

- **Mass** 80 kg [OBS], seated CoM at geom `rider_mass` (0, 1.05, 0) [OBS].
- **Weight shift** [INF: PitchSpring / Legs names; DESIGN values]:
  - `riderLean` moves the rider CoM laterally up to ±0.25 m.
  - `riderPitch` moves it forward/back ±0.30 m.
  - Both use spring-dampers (k = 4000 N/m, c = 400 N·s/m), and reaction forces act on the chassis.
- **Standing vs seated** [INF]: standing raises the CoM by 0.25 m and uses softer legs (k = 2500).
- **Aero tuck** [INF from Min/MaxCdA]: `CdA = lerp(MaxCdA, MinCdA, max(0, riderPitch))`.
- **Crash / detach** [OBS concept `m_iCrashed`; DESIGN rules]. The rider detaches when any of these happens:
  1. head point (CoM + 0.6 m along bike up) hits the ground
  2. |roll| > 75° with speed > 3 m/s
  3. chassis acceleration > 20 g for more than 30 ms (bad landing)
  4. chassis collision sphere impact speed > 9 m/s

  After a crash: rider ragdoll, `crashed = 1`, inputs are ignored, and the bike resets after 3 s.
- Wheelie, stoppie and jump pitch limits are rider-animation limits only (visual) [INF].

## 8. Aero

`F = ½·ρ·CdA·|v|²` against velocity (ρ = 1.2), plus lift `½·ρ·Cl·A·v²` (Cl 0.09, small) [OBS params, INF law].

## 9. Terrain, surfaces, deformation

**Surface lookup** [DESIGN mapping, OBS surface names], Roblox material → MX surface:

| Roblox material | Surface |
|---|---|
| Grass, LeafyGrass | grass |
| Sand | sand |
| Mud | soft soil |
| Ground | soil |
| Slate, Basalt | compact soil |
| Rock, Cobblestone | rock |
| Asphalt | asphalt1 |
| Concrete | concrete |
| Pavement | asphalt2 |
| Pebble | gravel |
| (any other Part) | compact soil |

**Ruts** [DESIGN; MX Bikes has `track_deformation`/`groove`, law unknown]:
- A sparse grid of 0.5 m cells stores depth `d` (0..0.10 m).
- Each wheel contact adds `Δd = 2e-6·Fz·(1 + 5|κ|)·compacting_factor·dt`.
- The wheel ride height is lowered by `d`.
- A lateral rut-capture force `−k_r·∂d/∂x` (k_r = 4000 N/m) steers toward the rut centre.
- Extra rolling resistance is `bulldozing_factor·d·Fz·0.5`.

**Track objects:** boxes with a material and `soft` → contact stiffness 2·10⁴/soft N/m [DESIGN].

## 10. Simulation loop

- Fixed step `dt = 1/300 s` [DESIGN], with an accumulator: 5 substeps per 60 Hz frame, and telemetry every 3 steps
  (100 Hz).
  - Why not 1/240: MX Bikes' states land exactly on a 10 ms grid, so its fixed step divides 10 ms [MEAS]. 1/240 s
    does not; 1/300 s divides both 10 ms and a 60 Hz frame.
  - If the frame time is > 0.1 s, at most 30 substeps run (no spiral of death).
- **Order per step:**
  1. read inputs
  2. ground queries (raycast per wheel + chassis spheres)
  3. suspension forces
  4. tyre loads and slips, then forces
  5. engine/clutch/gearbox/driveline (rigid when the clutch is locked)
  6. brakes
  7. steering controller
  8. rider springs
  9. aero
  10. integrate (semi-implicit Euler: velocities first, then positions; orientation via quaternion,
      renormalised)
  11. crash checks
  12. telemetry
- **Determinism:** the core is pure Luau with no Roblox API calls. Ground queries come through an injected
  `query(origin, dir, len) → {hit, normal, material}` [DESIGN], so tests can use flat planes and ramps.

## 11. Edge cases (must hold)

- Upside down or airborne: no tyre forces; the bike still rotates from rider shifts (pitch control in the air)
  [OBS behavior of MX-style games, DESIGN magnitude].
- Neutral plus throttle: RPM rises to the limiter, and the wheel gets no drive.
- Full brake at standstill: no creep.
- Clutch pulled at speed: the bike coasts and the engine returns toward idle.
- Very large dt (lag spike): the substep cap prevents explosion; the state stays finite.
- Shifting during the limiter is allowed; a downshift that would over-rev past `BreakingRPM` is refused
  [DESIGN money-shift protection].

## 12. Evidence map

All [OBS] values trace to: `bikes/<bike>/<bike>.cfg|.engn|.geom|.ini` (ev_58e62a75), `tyres/*/**.tyre`
(ev_8f490ff3), `rider/rider.cfg` (ev_225ba7a8), `misc/objs/objs.cfg` (ev_1edc496d), exe setting names
(ev_01e7976c), and the official plugin data layout (ev_490af6f1, ev_12e8b9e0 + mx-bikes.com `mxb_example.c`).
Plugin behavior (100 Hz request, sender thread, ms truncation): ev_75e74954. [MEAS] values come from
`recordings/mxb_20261015-180824_350xf_winchester_data.csv` (sha256 d4e8fcc0…) via `tools/analyze_telemetry.js`
(`..._analysis.md`). DRM blocker: unk_80a2febd.
