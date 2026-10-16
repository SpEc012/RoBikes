# MX Bikes physics — reverse-engineering report (Step 5)

Target: MX Bikes (PiBoSo), Steam install `C:\Program Files (x86)\Steam\steamapps\common\MX Bikes`
(read only). Tooling: REA `rea-agents@6.5.0` with Ghidra 12.1.4. Date: 2026-10-15.

**How to read this:**
- **CONFIRMED** means it was seen directly in shipped files or decompiled code, with a REA Evidence ID.
- **DERIVED** means it was calculated from confirmed data and cross-checked by an independent route.
- **MEASURED** means it was seen in a live recording through the official telemetry plugin
  (`recordings/mxb_20261015-180824_350xf_winchester_data.csv`, analysis in `..._analysis.md`; see §9).
- **INFERRED** is a reasonable reading of confirmed data that isn't proven by code.
- **UNKNOWN** is still open.

Full Evidence IDs are in `FINDINGS.md`; short prefixes are used below.

---

## 0. The big picture (plain English)

MX Bikes is a **data-driven** simulator. The program (`mxbikes.exe`) is a general vehicle physics engine.
Every bike, tyre and track is described in **plain-text settings files** packed into ZIP archives (`.pkz`).
So "how the physics work" splits in two:

1. **The numbers.** Fully readable. We extracted them all.
2. **The formulas** that use those numbers. These live in the `.exe` code, and that code is
   **scrambled by Steam DRM**, so we did not read it. Instead we used:
   - the engine's own **setting-name list**: 1,367 names left readable in the `.exe`;
   - the **official plugin interface**, the live physics data the game intentionally shares;
   - **maths cross-checks**, for example power from the torque curve compared with the declared power.

```
   bikes.pkz / tyres.pkz / tracks.pkz  (text + binary data, ZIP)
                 │  parsed by
                 ▼
   mxbikes.exe  ── physics engine (code DRM-scrambled; names readable)
                 │  every physics step
                 ▼
   RunTelemetry(188-byte state)  ──►  plugins/*.dlo  (official, readable)
```

---

## 1. Bike setup numbers — the foundation

**Plain English:** each bike is a folder with a main setup file (`.cfg`), an engine curve file (`.engn`),
a shape file (`.geom`), an info file (`.ini`) and sound/graphics files. The bike is modeled as several
connected bodies: chassis, steering, front suspension, rear swingarm, two wheels, plus the rider.

| Fact | Status | Evidence |
|---|---|---|
| `.pkz` files are normal ZIP archives | CONFIRMED | open_binary format=zip; inventory ev_7fe9c2c1 (bikes), ev_390d9e19 (tyres) |
| 5 bikes: 250x (2-stroke), 250xf, 350xf, 450xf, 450sm | CONFIRMED | extract ev_58e62a75 |
| Chassis mass 55–64 kg, 3-axis inertia, frame-flex stiffness/damping | CONFIRMED | `bikes/450xf/450xf.cfg` lines 252–261 |
| Steering body mass 10.5 kg, lock 42°, steering gains spg/sdg/sig, KYaw, KDamping | CONFIRMED | `450xf.cfg` lines 286–310 |
| Geometry: rake 26.5°, CoM, steering head, wheel positions, linkage shock points | CONFIRMED | `450xf.geom` lines 4–50 |
| Collision shape = spheres + boxes per body | CONFIRMED | `450xf.geom` lines 51–110 |
| `range = min, step, max` + `setting = n` means value = min + n·step | INFERRED (consistent with every range seen; e.g. fork spring 4400+3·200 = 5000) |
| The bike body list (chassis/steer/fsusp/rsusp/wheels) matches `.hrc` graphics parts | CONFIRMED | `chassis.hrc`, `steer.hrc`, `fsusp.hrc`, `rsusp.hrc` (ev_58e62a75) |
| Engine reads keys like `Chassis/FrontLatStiffness`, `Steer/KYaw` | CONFIRMED | exe strings ev_01e7976c (`evidence/mxbikes_exe_strings.tsv`) |

## 2. Engine & drivetrain (throttle → rear wheel)

**Plain English:** throttle picks a point on a **torque curve** (how hard the engine twists at each speed).
Torque goes through the **primary gears**, a **clutch** that can slip, the **gearbox**, the **chain
sprockets** and finally the rear wheel. When you close the throttle, a second curve gives **engine
braking**. Engine spin inertia, a rev limiter, stall RPM, idle and a starter are all simulated, plus
engine temperature with a thermostat.

| Fact | Status | Evidence |
|---|---|---|
| Torque curve: 12 points; engine-brake curve: 8 points | CONFIRMED | `450xf.engn` lines 2–29 |
| Curve x axis = engine **revolutions per second** (x·60 = RPM), y = N·m | DERIVED | `tools/check_torque_units.js`: peak T·2πx matches each `.ini` max_power (kW) within ~6% for all 5 bikes; other units are off by 6–10×. Brake curve ends at x=300 = 18,000 RPM = `BreakingRPM` |
| Primary ratio, clutch (MaxTorque 140, DeadZone 0.25, Mapping 2), stall, idle, limiter 11,600 | CONFIRMED | `450xf.cfg` lines 9–71 |
| Gear pairs written `driving, driven` (ratio = driven/driving) | MEASURED | 350xf live: RPM ÷ rear wheel speed changes between gears by 1.2304 / 1.2214 / 1.1670 (cfg 1.2307 / 1.2188 / 1.1667) for gears 1→4; 4→5 1.2096 vs 1.1973 (few samples) |
| Total ratio = primary × gear × rear/front sprocket, and wheel speed = wheel spin × **0.31 m** | MEASURED | RPM per m/s of rear wheel speed is 4.7–5.0% above the cfg ratio with the tyre's `Radius` 0.325 m in gears 1–4; i.e. the implied radius is 0.3096–0.3103 m (5th: 0.313). The free-rolling front wheel reads within 1% of ground speed, so use ~0.31 m as the effective rolling radius |
| Idle RPM and limiter work as configured | MEASURED | idle median 2305 rpm (cfg 2300); RPM never above 13,485 (cfg limiter 13,400 → ~85 rpm overshoot) |
| Engine can stall | MEASURED | RPM reads −2…−3 when stopped in gear (engine off) |
| Gearbox shift/engage/disengage timing, autoshift tables | CONFIRMED | `450xf.cfg` lines 81–133 |
| Driveline: axle inertias, efficiency 0.92, sprocket choices | CONFIRMED | `450xf.cfg` lines 135–165 |
| Engine also supports centrifugal/slipper clutch, oil pressure, carburation, turbo | CONFIRMED (names only) | exe strings `engine/Clutch/Slipper`, `engine/turbo/*` (ev_01e7976c) |
| ECU helpers: traction control, anti-wheelie, engine-brake control, launch control | CONFIRMED (names only) | exe strings `ECU/*` (ev_01e7976c) |
| Rider helpers: auto-clutch 2500–3000 rpm, shift help, wheelie help | CONFIRMED | `450xf.cfg` lines 505–528 |
| Exact clutch slip law, the "Mapping" curve shape | UNKNOWN | code DRM-protected (unk_80a2febd) |

## 3. Tyres & grip

**Plain English:** each tyre file contains coefficients of the **"Magic Formula"** used by real tyre
engineers. It turns *how much the tyre slips* (spinning or sliding sideways) into *grip force*. Grip
rises with slip up to a peak, then drops off, which is what lets you slide. Each **surface** multiplies grip
(`dry_grip`/`wet_grip`) and adds **rolling resistance**. Soft ground has **compacting** and
**bulldozing** factors, so the tyre sinks and pushes dirt. The tyre is also a **spring + damper**
(carcass stiffness depends on pressure), with mass, radius, width and knob behavior.

| Fact | Status | Evidence |
|---|---|---|
| Coefficient names p_Cx1, p_Dx1/2, p_Ex1–4, p_Kx1–3, r_Bx1–3, r_Cx1, p_Cy1/2, p_Dy1–3, p_Ey1–5, p_Ky1–7, r_By1–3, r_Cy1, r_Hy1, q_Bz1, q_Cz1, q_Dz1, q_Dz8, q_Ez1, s_Sz1, q_sy1, R0, Fz0 | CONFIRMED | `tyres/p_mx/p_mx_r_midsoft.tyre` lines 3–47 (ev_8f490ff3) |
| These are Pacejka Magic Formula (MF-Tyre-style) coefficients: longitudinal (x), lateral (y), aligning moment (z), combined-slip weighting (r_), rolling resistance (q_sy1) | INFERRED (naming matches the public MF convention; formula code not readable) |
| 13 surfaces with dry/wet grip and resistance; soft soils add compacting/bulldozing | CONFIRMED | `.tyre` lines 61–161; engine reads `%s/%s/bulldozing_factor` etc. (exe 0x140328940–0x1403289e0, ev_01e7976c) |
| Carcass: springBase 60000, springFactor 500 (per pressure), damper 205, mass 10 kg, R 0.325 m, torus radius 0.075, width 75 mm, pressure 70–90 kPa | CONFIRMED | `.tyre` lines 166–184 |
| SlipSinkage, MaxDrainage, KnobsFactor, KnobsMaxVelocity are read by the engine | CONFIRMED | exe strings 0x140328750–0x140328788 |
| Temperature/wear model exists but is switched off for the stock tyres (heating 0, wear 0) | CONFIRMED | `.tyre` lines 51–60 |
| Exact combined-slip method, how sinkage/knobs change force | UNKNOWN | code DRM-protected |
| How much the rear wheel spins on dirt | MEASURED | full throttle on Winchester dirt, median slip (wheel ÷ ground − 1): 1st 15% (p90 85%), 2nd 7%, 3rd 4%, 4th 2.3%, 5th 2.6%; coasting −1.4%; free-rolling front −0.8%; hard front braking median −2.8% (p10 −13.5%) |
| Wheel surface index | MEASURED | Winchester dirt reports material 8 on both wheels; 0 = in the air. Which surface name 8 is: UNKNOWN |

## 4. Suspension

**Plain English:** the **fork** is a coil spring (4,400–5,600 N/m), plus an **air spring** (air trapped
above the oil, which gets stiffer near bottom-out), plus a **3-stage damper**. The damper resists slow
moves with one rate, medium moves with another and very fast hits with a third. The **rear shock** works
through a **linkage** (rocker and rod), so the wheel rate changes through the stroke. It has separate
slow and fast bump adjusters, a rebound adjuster, a progressive **bump stop** and preload. Each adjuster
has 15 clicks.

| Fact | Status | Evidence |
|---|---|---|
| Fork spring range, air spring (Area, AirPressure 100 kPa, AirLengthBase), oil level 0.08–0.13 | CONFIRMED | `450xf.cfg` lines 312–330 |
| 3-stage damper: thresholds ±0.05 and ±1.1 (fork), ±0.05 and ±0.4 (shock); click tables of 3 numbers | CONFIRMED | `450xf.cfg` lines 332–379, 407–474 |
| Damper force is piecewise linear in shaft speed: slope 1 below threshold0, slope 2 up to threshold1, slope 3 beyond | INFERRED, knees partly MEASURED | live fit: 3-stage with cfg knees beats 1-stage (residual −9.9%); scanning the knee speed, the best fit is at the cfg values for front bump (1.1 m/s) and rear bump (0.4 m/s), but the effect is weak (3–4%). Rebound knees and the N·s/m values could not be pinned down (the rider is a separate sprung body). Method checked on synthetic data (`tools/README.md`) |
| Telemetry `susp_len` = travel left before bottom-out; top-out = max travel − preload | MEASURED | in the air the fork reads 0.291 = 0.300 − 0.009 and the shock 0.108 = 0.120 − 0.012 (350xf Preload settings 9 and 12 mm); 0 = bottomed out (reached on big landings) |
| Telemetry `susp_vel` = d(`susp_len`)/dt; compression is negative | MEASURED | slope 0.99, r = 0.997 (front), 0.98 / 0.99 (rear). Matches the negative `BumpThreshold` signs in the cfg |
| Static sag (rider on, stopped, neutral) | MEASURED | 350xf default setup: fork 0.063 m of 0.291 (22%), shock shaft 0.028 m of 0.108 (26%). While riding the median compression is fork 0.076 m, shock 0.036 m |
| Shaft speeds reached while riding | MEASURED | compression p90 / p99 / max: fork 0.45 / 2.0 / 4.3 m/s, shock 0.22 / 0.98 / 4.0 m/s. 46% (fork) and 38% (shock) of compression is above the first knee (0.05); 3.3% / 4.9% above the second |
| Rear: spring 48–60 kN/m, BumpStop (base + rising rate), RodLength, linkage "Linkage Rod Chassis" | CONFIRMED | `450xf.cfg` lines 394–498, `450xf.geom` lines 34–41 |
| Fork spring value is per fork leg (two legs) | INFERRED (5 N/mm ≈ real 0.50 kg/mm MX fork spring per leg) |
| Engine also supports top-out springs, twin shock, mono-shock | CONFIRMED (names only) | exe strings `*_Suspension/TopOutSpring/K`, `TwinShock`, `MonoShock` |

## 5. Brakes & steering

**Plain English:** the brake lever force (max 40 N) times the lever ratio, divided over the master cylinder
area, gives **hydraulic pressure**. Pressure × `PressureToTorque` gives **brake torque** on the disc. Discs
heat up and cool down. Steering is a separate body (10.5 kg) on the 26.5° steering head with a 42° lock.
The rider steers it using gains `spg`/`sdg`/`sig`, which look like a **P / D / I controller**. *Inference:*
like a real rider, the game turns the bars to reach the lean you ask for, which is countersteering.

| Fact | Status | Evidence |
|---|---|---|
| Brake chain: RiderMaxForce, Leverage ratio, MasterCylinder diameter, disc PressureToTorque, heating/cooling | CONFIRMED | `450xf.cfg` lines 172–250 |
| Telemetry reports brake **pressure in kPa** per wheel | CONFIRMED | official example (mx-bikes.com) + plugin copies 188 bytes (ev_490af6f1) |
| spg/sdg/sig = proportional/derivative/integral gains of a steering controller | INFERRED (naming pattern p/d/i + "g"ain; values negative = corrective) |
| Telemetry reports **steering torque (N·m)** and steer angle (negative = right) | CONFIRMED | official example; size check 47×4 = 188 bytes |
| Steering lock 42° | MEASURED | live steer angle p99 ±42.03°, max 43.7° (in a crash) |
| Telemetry brake-pressure fields are NOT filled by this game build | MEASURED | the front field holds random leftover memory (±1e38, denormals) and the rear field sits near 3 kPa while the levers move 0→1. Brake pressure can't be measured this way; the brake chain stays DERIVED from the cfg |

## 6. Rider

**Plain English:** the rider is a **real 80 kg physical body**, not just an animation. The engine settings
include rider **legs as springs** (sitting vs standing), a **pitch spring** for leaning forward and back,
maximum pitch angles for jumps, wheelies and stoppies, and "stability" helpers. When the rider separates
from the bike, the game marks a crash. Bike parts can also break off above a set force.

| Fact | Status | Evidence |
|---|---|---|
| Rider mass 80 kg, fall reference point, detach blend 0.333 | CONFIRMED | `rider/rider.cfg` (ev_225ba7a8) |
| Max visual lean 55°, head turn limits | CONFIRMED | `rider/animations/mx/gfx.cfg` |
| Rider parameter names: Legs/SeatSpring, StandSpring, CompDamping, ExtDamping; PitchSpring/*; sitting/standing pitch limits; jump/wheelie/stoppie pitch; stability/pitch,roll,yaw | CONFIRMED (names only) | exe strings (ev_01e7976c) |
| The values for those names live in `rider.prm` | INFERRED (rider.cfg says `params = rider.prm`) |
| `rider.prm` is **encrypted** (random bytes, trailer "PYRC") | CONFIRMED | file content (ev_225ba7a8). **Not decrypted on purpose.** |
| Crash flag = "rider detached from bike" | CONFIRMED | official example field `m_iCrashed` |
| Breakable parts: break_force, damage forces, mass | CONFIRMED (names only) | exe strings `detachable/part%d/*` |

## 7. Terrain, surfaces & collisions

**Plain English:** each track has a **height grid** (`.trh`, 2049×2049 points) for the ground shape, a large
`.map` file, and race lines (`.tl`). The ground is **alive**. The engine has options for
`track_deformation` and a `dynamicsurface`, and it **saves ruts ("groove") and wetness maps** per session
(`.grv`, `.wet`). Under each wheel the game knows the **surface material** (it reports it to plugins).
Track objects such as hay bales and tyre walls are simple boxes with a material and a softness.

| Fact | Status | Evidence |
|---|---|---|
| `.trh` header "TRH", then 2049 and 2049 | CONFIRMED | first bytes of `mxb_test_track.trh` (extract ev_34c0eca7) |
| `.trh` holds a 2049×2049 height grid stored as 16-bit half-floats | INFERRED (values decode to ~2.4 m plausible heights; file is larger than one grid, so more layers exist) |
| `.map` header "MP2"; `.tl` header "TL" + point count | CONFIRMED (headers); contents UNKNOWN / INFERRED (race lines) |
| Deformation, groove and wet maps exist and are saved per session | CONFIRMED (names) | exe strings `track_deformation`, `dynamicsurface`, `track_groove`, `%s…-%s.grv`, `.wet` (ev_01e7976c) |
| Per-wheel surface material index in telemetry (0 = no contact) | CONFIRMED | official example `m_aiWheelMaterial` |
| Track objects: collision boxes, material, soft | CONFIRMED | `misc/objs/objs.cfg` (ev_1edc496d) |
| `.rdf` = finish line/splits/start gates; `.tsc` = TV cameras; `.scr` = scenery; `.amb`/`.env` = light/reverb | CONFIRMED (not physics) | ev_34c0eca7 |
| Deformation algorithm (how deep ruts get, how fast) | UNKNOWN | code DRM-protected |

## 8. Simulation loop

| Fact | Status | Evidence |
|---|---|---|
| The game calls `RunTelemetry(data, size, time, pos)` with a 188-byte state | CONFIRMED | plugin decompile `RunTelemetry` @0x1800020c0 copies 0xBC bytes (ev_490af6f1); official example signature |
| `proxy_udp64.dlo` asks for telemetry at 100 Hz, the interface's fastest rate, so recordings top out at 100 states/s | CONFIRMED | `Startup` @0x180001c30 returns 0 (ev_75e74954); official doc: 0 = 100 Hz |
| The plugin sends the latest state on its own 10 ms timer; time stamps are cut to whole ms | CONFIRMED | sender FUN_180001030, `(int)(fTime*1000)` (ev_75e74954). The analyzer de-duplicates and rebuilds exact time |
| Acceleration in telemetry is "averaged over the last 10 ms" | CONFIRMED (doc) | official example comment (paraphrased) |
| Telemetry states come on an exact 10.000 ms game-time grid, and the game clock runs at real time | MEASURED | all 10 riding stretches fit a 10.000 ms step (9.9986–10.0007); game ÷ real time 1.0005; 99.7% of steps are whole multiples of 10 ms |
| Physics uses a fixed step that divides 10 ms (≥ 100 Hz) | MEASURED (bound) | states land exactly on the 10 ms grid, so the step can't be e.g. 1/240 s. The interface tops out at 100 Hz, so faster rates can't be seen |
| Exact physics step rate and integrator | UNKNOWN | code DRM-protected; can only be bounded through the official interface |

## 9. Live telemetry (MEASURED)

**Plain English:** the game's own plugin shares the bike's state 100 times a second. We recorded about 5 minutes of
riding (350XF, Winchester, default setup, 7 crashes) and checked what each number really means. Some of it differs
from the official comments, and that matters for matching the feel in RoBikes.

Evidence: `recordings/mxb_20261015-180824_350xf_winchester_data.csv` (sha256 d4e8fcc0…, 32,157 rows) and
`_raw.bin` (sha256 f7b324a5…); analysis `recordings/mxb_20261015-180824_350xf_winchester_analysis.md`, made by
`node tools/analyze_telemetry.js <csv> --cfg <extracted>/bikes/350xf/350xf.cfg`.

| What | Measured |
|---|---|
| World axes | +Y is up (gravity found on that axis while airborne) |
| Rotation matrix `m_aafRot` | its **columns** are the chassis axes in world space: column 2 = forward (lines up with velocity, 0.995), column 1 = up, column 0 = side |
| Velocity | belongs to the **position reference point**, not the CG (position changes match it to 0.013 m/s median; any other point fits worse) |
| Speedometer | exactly the length of that velocity |
| Acceleration | **no gravity** (reads 0 standing still, about −0.86 G along bike-up in the air), in chassis axes, and it behaves like a point ~0.62 m (0.6–0.7) up the chassis from the reference point, i.e. the chassis CG (geom `chassis_mass` y = 0.624) |
| Time | exact 10.000 ms steps on the game clock; the plugin's own timer drops ~14% of them (4,502 repeats, 4,517 skips), so de-duplicate by `time_ms` |
| Crash recovery | the bike is teleported back (6 position jumps); cut the data there |
| Suspension, gears, slip, engine, steering, brake fields | see the MEASURED rows in §2–§5 |

---

## Chain of evidence (file → function/line/offset → Evidence)

1. `bikes.pkz` → ZIP → `bikes/450xf/450xf.cfg` (engine 9–71, gearbox 81–133, driveline 135–165, brakes 172–250,
   chassis 252–261, aero 263–284, steer 286–310, fork 312–392, shock 394–498, helpers 500–528) → ev_58e62a75
2. `bikes/450xf/450xf.engn` torque 2–17, brake 18–29 → ev_58e62a75 → units DERIVED by `tools/check_torque_units.js`
3. `bikes/450xf/450xf.geom` points 4–50, collision 51–110 → ev_58e62a75
4. `tyres.pkz` → `tyres/p_mx/p_mx_r_midsoft.tyre` MF 3–47, compound+surfaces 48–162, carcass 166–184 → ev_8f490ff3
5. `rider.pkz` → `rider/rider.cfg`, `rider/rider.prm` (encrypted) → ev_225ba7a8
6. `tracks.pkz` → `tracks/motocross/mxb_test_track/*.trh|.map|.tl|.rdf` → ev_fb11c6d9, ev_34c0eca7
7. `mxbikes.exe` → .text high-entropy @0x140001000 (ev_bbb6fdca); zero xrefs to `springBase` @0x140329990 (ev_3a1d6d41),
   `Rear_Suspension/Damper/BumpThreshold0` @0x1403259f8 (ev_508a3d5c), `Rear_Suspension/BumpStop/SpringBase` @0x140325780
   (ev_0e6204d4) → DRM; recorded as unknown unk_80a2febd. Strings inventory ev_01e7976c.
8. `plugins/proxy_udp64.dlo` → exports @0x180001000–0x1800020c0; `RunInit` copies 0x70, `RunTelemetry` copies 0xBC,
   sender `FUN_180001030` packs `"data"`+state+time+47 dwords = 0xC9 bytes (ev_490af6f1, ev_12e8b9e0)

## Biggest UNKNOWNS and the next question for each

| Unknown | Why open | Next question / probe |
|---|---|---|
| Exact tyre formula and combined slip | code DRM-scrambled | Use the public Magic Formula and tune RoBikes until its slip matches the MEASURED targets (§3): ~15% rear slip at full throttle in 1st on dirt, ~2–4% in 3rd–5th |
| Damper N·s/m values in use, air-spring law | code DRM-scrambled; live fit is blurred by the sprung rider | Knees at the cfg speeds are supported. Next probe: a recording standing still on the pegs vs seated, or a slow-speed bump section, to separate rider and damper |
| Rider body values | `rider.prm` encrypted (left closed on purpose) | Design our own rider springs; tune by feel |
| Terrain deformation law | code DRM-scrambled | Design our own rut model (SPEC §7) |
| Physics step rate | interface tops out at 100 Hz | MEASURED bound: fixed step dividing 10 ms. The exact rate can't be seen through the official interface |
| Why wheel speed implies a 0.31 m radius, not 0.325 | tyre code DRM-scrambled | Likely the loaded rolling radius (carcass squash plus knobs). Check: record a slow roll on asphalt with a different tyre pressure |

**Live probe (done once, repeatable):** the official `proxy_udp` plugin is switched on (`proxy_udp.ini`: `enable = 1`,
`info = 1`). Run `node tools/record_telemetry.js`, ride, then `node tools/analyze_telemetry.js <file>_data.csv`
(see `tools/README.md`). This measures real behavior through the official interface without touching DRM.
