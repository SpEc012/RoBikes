# Robikes — original motocross game for Roblox (physics modeled on MX Bikes)

Original code and art. Physics numbers come from the user's own MX Bikes data and a live telemetry recording
(see `../REPORT.md`, `../SPEC.md`, `../BRIEF-CORRECTIONS.md`). No MX Bikes meshes, textures, sounds, tracks or code.

## Play it

1. Open `Robikes.rbxlx` in Roblox Studio (it already contains the scripts and the test track).
2. Press **Play** (F5). You spawn on the start pad of the test track.
3. Press **H** for the controls.

| Key | Action |
|---|---|
| W | throttle |
| S | brakes (front + rear) · Left Shift = rear only |
| A / D | steer (lean the bike) |
| Space | clutch |
| Q / E | shift down / up (auto-shift is on by default, T toggles) |
| Arrow Up / Down | rider weight forward / back (also pitches the bike in the air) |
| Arrow Left / Right | rider weight left / right |
| R | respawn · C camera (chase / far / helmet) · 1–5 bike · P setup · G balance assist |

Gamepad: RT throttle, LT front brake, LB rear brake, left stick steer, right stick rider, X/Y shift. Touch devices get
on-screen pads.

## Where things are (in Studio's Explorer)

- `ReplicatedStorage › Robikes` — all modules: `RobikesConfig` (every number, SI units), `BikePhysics` (the 300 Hz
  simulation), `Tyre`, `Drivetrain`, `Ruts`, `BikeController` (input), `BikeRenderer`, `Camera`, `HUD`,
  `TrackBuilder`, `Tests`, `BikeData` (generated physics numbers)
- `StarterPlayer › StarterPlayerScripts › RobikesClient` — runs your bike (client-authoritative)
- `ServerScriptService › RobikesServer` — relays bikes between players
- `Workspace › RobikesTrack` + Terrain — the test track

## Run the tests (Studio command bar, Edit mode)

```lua
print((require(game.ReplicatedStorage.Robikes.Tests).run()))
print(require(game.ReplicatedStorage.Robikes.Tests).calibrate())   -- RoBikes vs the MX Bikes recording
```

## Edit the code

Source of truth is `src/` (Rojo-style layout). While developing, `node ../tools/serve_src.js src` serves it on
127.0.0.1 and `require(game.ServerStorage.RobikesDevSync)()` pulls it into the open place (HTTP is enabled only
during the sync).
