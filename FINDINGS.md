# FINDINGS ledger — MX Bikes physics (REA evidence)

Legend: **OBSERVED** = seen directly in shipped files via REA. **INFERRED** = my reading of it, not yet
proven by the .exe code. **UNKNOWN** = still open.

Game: `C:\Program Files (x86)\Steam\steamapps\common\MX Bikes` (read only).
Extracted copies (REA temp folders, may be cleaned by Windows):
- tyres.pkz → `%TEMP%\rea-extracted-e3bcbc3b-2a00-481e-822b-966ba3e23d5e`
- bikes.pkz → `%TEMP%\rea-extracted-6ccdd34f-8535-451f-b0d3-cdf5c4585edd`
- misc.pkz  → `%TEMP%\rea-extracted-5ce2edf0-139f-4fe0-9421-75f49967dbf0`
- rider.pkz → `%TEMP%\rea-extracted-6c92e44a-0648-4ba9-a606-9e60e95ceb60`

## Data archives

| Archive | sha256 (prefix) | Format | Evidence |
|---|---|---|---|
| tyres.pkz | 6ef98419… | ZIP, 27 files | inventory ev_390d9e19…, extract ev_8f490ff3… |
| bikes.pkz | 92006a88… | ZIP, 182 files, 5 bikes | inventory ev_7fe9c2c1…, extract ev_58e62a75… |
| misc.pkz  | 52be98c3… | ZIP, graphics/HUD + objs.cfg | extract ev_1edc496d… |
| rider.pkz | 3b201d99… | ZIP, 167 files | extract ev_225ba7a8… |

- OBSERVED: `.pkz` = plain ZIP (REA open_binary format=zip).
- OBSERVED: `.edf` = 3D scene/model (".hrc" files reference `scene = X.edf` with LOD `switch` distances).
- OBSERVED: physics data is plain-text `key = value` with `{ }` blocks, `;` comments.

## 1. Bike setup numbers (bikes/<bike>/<bike>.cfg, .geom, .engn, .ini) — ev_58e62a75…

Bikes: 250x (2-stroke), 250xf, 350xf, 450xf, 450sm (supermoto).
450xf observed values:
- chassis: Mass 64.31, Inertia 4.89/3.19/2.28, Front/RearLatStiffness 750/500, LatDamping 4/3
- ini: weight 106.1, max_power 37.4, 4 gears, engine 450cc 4-stroke
- geom: chassis_mass (0,0.623,-0.025); rake 26.5°; steer head (0,0.9912,0.3372); rsusp_type "Linkage Rod
  Chassis" (shock/rocker/rod points); fwheel/rwheel positions; collision = 2 spheres + boxes per part
- steer: Mass 10.5, Lock 42, spg0/1 = -150/-2.5, sdg0/1 = -30/0.25, sig0/1 = 0/0, KYaw 10, KDamping0/1 6/0.15
- front_suspension: Spring range 4400..5600 step 200 (setting 3), air spring Area 0.0016 / AirPressure 100 kPa
  / Oil level, 3-stage damper Bump/Rebound tables (15 clicks, 3 numbers each), Preload, RideHeight
- rear_suspension: Spring 48000..60000 step 3000, damper Bump/FastBump/Rebound tables, Preload, BumpStop
  (SpringBase/RisingRate/DampingBase/RisingRate), RodLength
- aero: AreaX/Y/Z, Cx 0.8, Cl 0.09, Rot drag, MinCdA/MaxCdA
- helpers: autoclutch (2500–3000 rpm), shifthelp, wheelinghelp
- INFERRED: `range = min, step, max` + `setting = n` → value = min + n*step (e.g. fork spring 4400+3*200=5000).

## 2. Engine & drivetrain — ev_58e62a75…

- engine: Inertia 0.008, stall (1600 rpm, 0.035), IdleThrottle 0.073, IdleRPM 2300, Limiter 11600,
  BreakingRPM 18000, primary Ratio0 = 32:76, Clutch MaxTorque 140 / Mapping 2 / DeadZone 0.25,
  starter torque 3 / maxRPM 2100, temperature model (OptTemperature 60, thermostat 55–60)
- .engn: `torque` curve 12 points (x 0..298.1, y up to 45.63) + `brake` (engine braking) 8 points (negative)
- gearbox: 4 gears 16:32, 18:30, 20:28, 22:26; Up/Downshift 0.04 s; Disengage/Engage times & limits
- driveline: FirstAxisInertia 0.0025, SecondAxisInertia 0.00075, Efficiency 0.92, FSprocket 11..16,
  RSprocket 38..52
- UNKNOWN: unit of torque-curve x axis. INFERRED candidate: revolutions/second (298 rps ≈ 17.9k rpm < BreakingRPM 18000).

## 3. Tyres — ev_8f490ff3…

- `.tyre` keys p_Cx1, p_Dx1, p_Kx1, r_Bx1, p_Cy1, p_Ky1..7, r_By1, r_Hy1, q_Bz1, q_Dz1, q_Ez1, s_Sz1, R0, Fz0
- INFERRED: Pacejka "Magic Formula" (MF-Tyre style) coefficients — needs exe confirmation.
- Per-surface table (asphalt1-3, concrete, grass, sand, kerb, soft soil, soil, compact soil, paint, gravel, rock):
  dry_grip, wet_grip, resistance_dry/wet, compacting_factor, bulldozing_factor (soft surfaces only)
- Carcass: springBase 60000, springFactor 500, damper 205, mass 10, Radius 0.325, TorusRadius 0.075,
  Width 75, OptimalPressure 90, pressure range 70..90, SlipSinkage 1, MaxDrainage 100, KnobsFactor 0.4,
  KnobsMaxVelocity 14
- Temperature: OptTemperature 20, Below/AboveTempFactor 2.5/1.5, heating factors 0, WearRate 0

## 6. Rider — ev_225ba7a8…

- rider.cfg: mass 80, fall_ref (0,-0.2,-0.05), detach_blend 0.3333, params = rider.prm
- animations gfx.cfg: maxlean 55, headmaxrot 100, 42 animation files (.anm)
- OBSERVED: `rider.prm` is ENCRYPTED (high-entropy bytes, trailer "PYRC"). DECISION: do not decrypt —
  RoBikes uses its own rider parameters.

## 7. Track objects — ev_1edc496d…

- objs.cfg: cones/haybales/tyre stacks/barriers with collision boxes, material (plastic/haybale/tire), soft 1–2

## Plugins (live telemetry route)

- plugins/proxy64.dlo, proxy_udp64.dlo (DLLs), xinput64.dli; proxy_udp.ini enable=0 port 30000
- proxy_udp64.dlo sha256 9a094258…, Ghidra overview ev_67b8c689, exports ev_99ed6c69, strings ev_93d2d903.
- Decompile ev_490af6f1: GetModID → "mxbikes"; GetModDataVersion → 8; GetInterfaceVersion → 9;
  RunInit @0x180001fd0 memcpy 0x70 (session block); RunTelemetry @0x1800020c0 memcpy 0xBC (188 bytes).
- Decompile ev_12e8b9e0: sender FUN_180001030 builds "data"+state+time_ms+47 dwords = 0xC9 bytes → UDP;
  FUN_1800015b0 sends "evnt" (3×char[100], 11 dwords, 3×char[100], 2 dwords), "sesn", "lap ", "splt".
- External doc (official): https://mx-bikes.com/?page=downloads → downloads/mxb_example.c. Field list of
  SPluginsBikeData_t = 47 four-byte fields = 188 bytes → matches 0xBC exactly. Session 4+4+4+100 = 0x70 ✓.
- Decompile ev_75e74954… (procedures ev_7274e086…), 2026-10-15:
  - `Startup` @0x180001c30 reads `proxy_udp.ini` [params] enable/ip/port/delay/**info** and returns 0 →
    OBSERVED: asks for RunTelemetry at **100 Hz** (official doc: 0 = 100 Hz, the fastest option).
  - `ip` = destination (default 127.0.0.1:30001); `port` = the plugin's own bound port (30000).
  - Sender thread FUN_180001030 sends the latest state every `delay×10` ms (absolute timeGetTime schedule), not
    once per RunTelemetry → packets can repeat or skip samples. State 0 → 9-byte packet; 1 (RunStop) / 2
    (RunTelemetry) → 201 bytes. `time_ms = (int)(fTime*1000)`, float fTime → whole-ms truncation.
  - Info thread FUN_1800015b0 runs only if `info = 1` (default 0): evnt + sesn every 1 s, `lap ` + `splt` every
    0.2 s (last values repeated). Strings are NUL-terminated, unpadded. splt starts with a "last event was a split"
    flag (RunSplit sets 1, RunLap sets 0).
- Recorder/analyzer: `tools/record_telemetry.js`, `tools/analyze_telemetry.js`, `tools/README.md`. Checked
  end-to-end with `tools/fake_mxb_sender.js` (synthetic, known answers).

## Live telemetry — MEASURED (2026-10-15, 350xf, Winchester, default setup)

Recording `recordings/mxb_20261015-180824_350xf_winchester_data.csv` (sha256 d4e8fcc0…, 32,157 rows, ~318 s riding,
7 crashes), raw `_raw.bin` (sha256 f7b324a5…), analysis `_analysis.md` / `.json` (run with `--cfg` 350xf.cfg).
- Time: exact 10.000 ms steps on the game clock (all 10 stretches fit 9.9986–10.0007 ms); game time = real time.
  Plugin timer drops ~14% (4,517 skips) and repeats some (4,502). Physics step: fixed, divides 10 ms.
- Frames: world +Y up; rotation-matrix COLUMNS = chassis axes (col 2 forward 0.995, col 1 up).
- Velocity = position reference point (0.013 m/s median vs position change), NOT CG. Speedometer = |velocity|.
- Acceleration: kinematic (0 at rest), chassis axes, acts as a point ~0.62 m up (0.61–0.71 by axis) = chassis CG.
- Suspension: `susp_len` = travel left (0 = bottomed); top-out = max travel − preload (0.291 = 0.300 − 0.009,
  0.108 = 0.120 − 0.012); `susp_vel` = d/dt (r 0.997), compression negative. Damper: 3-stage beats 1-stage by 9.9%;
  knee scan best at cfg 1.1 (fork bump) and 0.4 (shock bump), weak; coefficients not identifiable (rider body).
- Gears: step ratios = cfg (driven/driving) within 0.2% (g1–4); implied wheel-speed radius 0.310 m (cfg Radius 0.325).
- Slip on dirt, full throttle median: 15 / 7 / 4 / 2.3 / 2.6 % (gears 1–5); front braking median −2.8%.
- Idle 2305 (cfg 2300); limiter peak 13,485 (cfg 13,400); steer p99 ±42.03° (lock 42); stalls at standstill in gear.
- Brake-pressure fields (44, 45) are NOT filled by this build: random leftover memory / ~3 kPa. Unusable.
- Wheel material index on Winchester dirt = 8.

## mxbikes.exe (DRM) — ev_69244e04, strings ev_01e7976c

- sha256 9e792d7a…, 4,624 "functions", 5,019 strings, sections incl. `.bind` (Steam DRM stub).
- .text bytes high-entropy (ev_bbb6fdca); zero xrefs to physics strings (ev_3a1d6d41, ev_508a3d5c, ev_0e6204d4).
  → recorded unknown unk_80a2febd. DECISION: no unpacking/decryption.
- 1,367 slash-path setting names saved to `evidence/mxbikes_exe_strings.tsv`. Highlights: rider Legs/PitchSpring/
  stability/jump/wheelie/stoppie; ECU TCS/AntiWheeling/EngineBraking/LaunchControl; detachable parts;
  track_deformation, dynamicsurface, track_groove, track_wet, .grv/.wet session files; %s/%s/compacting_factor.

## Derived

- Torque curve x axis = rev/s (`tools/check_torque_units.js`): computed peak kW vs .ini max_power —
  250x 35.9/36.1, 250xf 29.4/31.2, 350xf 37.2/37.4, 450xf 39.6/37.4; alternatives off by 6–10×.
  Brake curve last x = 300 = 18,000 rpm = BreakingRPM (4-strokes).
- Gear pair = (driving, driven): 450xf 4th-gear limiter speed ≈ 39 m/s (142 km/h).
- Bike comparison (`tools/compare_bikes.js`): steering, geometry, aero, brakes identical across the 5 bikes; engine,
  gearing, chassis mass and spring ranges differ.
- Tyre coefficient set includes p_Cy2, p_Ky6, p_Ey5 → INFERRED: motorcycle Magic Formula variant (camber thrust).

## Derived (build phase, 2026-10-15)

- Engine torque blend T = θ·Tfull + (1−θ)·Tbrake with θ = IdleThrottle balances at: 250xf 2185 rpm, 350xf 2230,
  450xf 2240, 450sm 2240 vs IdleRPM 2300 (`tools/check_idle_balance.js`). Each 4-stroke has a different
  IdleThrottle (0.079 / 0.077 / 0.073) that lands it ≈ IdleRPM → strong support for the blend formula.
  250x (2-stroke) never balances below 8000 rpm → its idle uses another mechanism (exe names IdleElectronic,
  AutoIdle/*). RoBikes fades the idle floor out above IdleRPM [DESIGN].
- Rear linkage check: motion ratio 3.0 → 2.2 over 0.31 m wheel travel gives 0.120 m shock stroke
  (= geom rear_length 0.12) and 105 mm static sag with spring 57000 N/m + 12 mm preload + 80 kg rider.
