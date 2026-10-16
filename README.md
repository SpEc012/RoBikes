# RoBikes

An original motocross game for Roblox with physics modeled on MX Bikes.

**Start here: [my-version/README.md](my-version/README.md)** covers how to play it, the controls, where the code lives and how to run the tests.

The current game code is in `my-version/src/`. The research behind it is in `REPORT.md`, `SPEC.md`, `FINDINGS.md` and `BRIEF-CORRECTIONS.md`, the telemetry tools are in `tools/`, and the MX Bikes recording used for calibration is in `recordings/`.

Studio place files (`*.rbxlx`) are not tracked; build the place from `my-version/src/` as described in the my-version README.

---

## Earlier starter project (`src/`)

An original motocross game for Roblox, reproducing the *feel* of MX Bikes from a reverse-engineered
model (see the docs in the parent folder). Clean reimplementation — no copied assets.

## What's here
```
robikes/
  default.project.json        -- Rojo mapping
  src/shared/                 -> ReplicatedStorage/RobikesShared
    RobikesConfig.lua         -- all bike/tyre/suspension/surface params (SI), tuning in one place
    Pacejka.lua               -- simplified Magic Formula tyre forces
    TerrainDeform.lua         -- dynamic rut + groove grid (the MX Bikes signature)
  src/client/                 -> StarterPlayer/StarterPlayerScripts/Robikes
    BikePhysics.lua           -- fixed-step rigid-body integrator (suspension/tyres/engine/balance)
    BikeController.lua        -- input (keyboard + mobile buttons)
    BikeRenderer.lua          -- builds a placeholder bike from parts, positions wheels/rider
    BikeClient.client.lua     -- bootstrap: spawns a bike, runs the loop, chase cam + HUD
```

## Install
**With Rojo (recommended):** put this folder in a Rojo project and `rojo serve`, connect from Studio.
**Manual:** in Studio, create a Folder `RobikesShared` in ReplicatedStorage and add `RobikesConfig`,
`Pacejka`, `TerrainDeform` as **ModuleScripts** (paste the files). Create a Folder `Robikes` in
StarterPlayer > StarterPlayerScripts and add `BikePhysics`/`BikeController`/`BikeRenderer` as
**ModuleScripts** and `BikeClient` as a **LocalScript**. Add a Baseplate. Press Play.

## Controls
- **W** throttle, **S** rear brake, **LeftShift**(+S) front brake
- **A/D** steer / lean, **Up/Down** rider weight fwd/back
- **Q/E** shift down/up, **Space** clutch, **R** reset, **C** camera
- Mobile: on-screen GAS/BRK/</>/+/- buttons appear automatically.

## How it maps to the reverse-engineered model
- **Physics:** a 1-body + 2 raycast-wheel approximation of the game's ODE multi-body bike
  (FINDINGS.md §3). Fixed 240 Hz step, SI units, custom integration.
- **Tyres:** Pacejka peaks/stiffness from the `.tyre` files (dirt vs tarmac) + per-surface grip.
- **Engine/drivetrain:** real torque curves, gear ratios, final drive, clutch cap, redline.
- **Suspension:** fork + rear spring/damper rates from `<bike>.cfg`.
- **Terrain deformation:** `TerrainDeform.lua` — wire it in by, each step, calling
  `deform(contactX, contactZ, latX, latZ, Fz, slip, surface.soft, dt)` and, in the suspension
  raycast, lowering the ground by `sample()` rut depth + adding a lateral force from
  `rutGradient()` (the "rut steers you" feel). See SYSTEMS_AND_DEFORMATION.md.

## Tuning first
Everything lives in `RobikesConfig.lua`. Likely first tweaks: `Balance.Kp/Kd/assist` (stability),
suspension `rate/bump/rebound`, tyre `muX/muY`, `STEP_HZ`, and torque curve scale. The engine
torque x-axis is an inferred RPM mapping — calibrate top speed / acceleration to taste.

## Roadmap (vertical slices)
M1 stand & roll → M2 powertrain → M3 steer/lean/corner → M4 jumps → M5 surfaces + ruts →
M6 game (cameras, HUD, bikes, gate-drop start + holeshot, mobile, multiplayer with deform sync).
See OPUS_5.5_PROMPT.md for the full build brief.

## Guardrails
Original/licensed art + audio only. The reverse-engineered numbers are behavioural reference, not
assets. Don't ship MX Bikes meshes/textures/track data.
