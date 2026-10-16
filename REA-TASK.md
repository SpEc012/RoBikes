# REA-TASK — MX Bikes → RoBikes

next step: 6C continue — M3 lean tuning, run Tests.calibrate({antiWheelie=true}) vs recording, M4–M6
(build is playable: my-version/Robikes.rbxlx, 25/25 tests pass; see my-version/README.md)

## Answers (Step 1, 2026-10-15)

1. **What to reverse:** a game — native Windows .exe (C++), MX Bikes by PiBoSo
2. **Where:** `C:\Program Files (x86)\Steam\steamapps\common\MX Bikes` (read only — never modified)
3. **ONE feature:** Bike setup numbers — what numbers define a bike (mass, engine power curve,
   gears, suspension springs/damping, tyres) and how the game uses them
4. **End result:** C — explanation + SPEC.md + my own working Roblox (Luau) version ("RoBikes")
   built from the spec, with tests, in `./my-version`

## Ground rules

- Work folder: `C:\Users\pitts\Documents\RoBikes`
- No copied game code, models, tracks, textures or sounds go into RoBikes. Behavior only.
- Every claim needs REA evidence (Evidence IDs recorded below).

## Scope change (user, 2026-10-15): "I WANT ALL OTHER PHYSICS ANALYZED TOO"

Physics checklist (do in this order; mark answered / partial / unresolved with Evidence IDs):

- [ ] 1. Bike setup numbers (mass, inertia, geometry) — foundation
- [ ] 2. Engine & drivetrain (throttle → clutch → gears → rear wheel, rev limiter, engine braking)
- [ ] 3. Tyres & grip (slip, sliding, surface types)
- [ ] 4. Suspension (fork/shock springs, damping, preload, travel)
- [ ] 5. Brakes & steering
- [ ] 6. Rider (lean, weight shift, crash/bail)
- [ ] 7. Terrain & collisions (ruts/deformation, landings)
- [ ] 8. Simulation loop (timestep, integrator)

## Progress log

- Step 0: no REA-TASK.md existed → fresh start.
- Step 1: answers saved.
- Step 2: `rea-agents@6.5.0 doctor --client claude_code` → registration:claude_code ok (aligned,
  C:\Users\pitts\.claude.json). Node 24.19.0 ok. Ghidra 12.1.4 healthy (C:\Tools\ghidra_12.1.4_PUBLIC).
  Hopper/IDA/JADX missing — not needed. No restart required.
- Step 3: route = native .exe (Ghidra) for mxbikes.exe + archive route for .pkz data files.
- Step 4: all 8 systems investigated. Data fully readable (ZIP .pkz, text configs). mxbikes.exe code is
  Steam-DRM scrambled → NOT unpacked (unk_80a2febd); used exe string names (1,367 setting keys), the
  official plugin (proxy_udp64.dlo decompiled; 188-byte telemetry verified against mxb_example.c) and
  maths cross-checks (torque curve x = rev/s, DERIVED). rider.prm encrypted → left closed on purpose.
- Step 5: REPORT.md written (CONFIRMED / DERIVED / INFERRED / UNKNOWN + evidence chain).
- Step 6: SPEC.md written (behavior, inputs, outputs, edge cases, evidence, [OBS]/[INF]/[DESIGN] tags).
- Checklist status: 1 answered, 2 answered (clutch law unknown), 3 partial (formula inferred = motorcycle
  Magic Formula), 4 partial (damper law inferred), 5 answered/inferred, 6 partial (rider.prm closed),
  7 partial (deformation law unknown), 8 unresolved (step rate unknown).
- Roblox Studio: running; StudioMCP.exe + %LOCALAPPDATA%\Roblox\mcp.bat exist but NOT registered with
  Claude Code (only rea + unreal-mcp in ~/.claude.json).
- 2026-10-15 telemetry: official proxy_udp plugin enabled (user OK); `tools/record_telemetry.js` +
  `tools/analyze_telemetry.js`; one live ride recorded (350xf, Winchester). MEASURED items added to REPORT.md
  (§2–§5, §8, new §9), SPEC.md ([MEAS] tags) and FINDINGS.md. Checklist 8 (sim loop) → partial (fixed step,
  divides 10 ms). Pasted Roblox build brief checked → `BRIEF-CORRECTIONS.md`.
- 2026-10-15 (user approved): added user-scope MCP server `Roblox_Studio` to C:\Users\pitts\.claude.json
  → cmd.exe /d /c %LOCALAPPDATA%\Roblox\mcp.bat. Backup: C:\Users\pitts\.claude.json.bak-robikes-20261015-112943.
  Handshake test OK: server "RobloxStudio 1.0.0", 28 tools (execute_luau, multi_edit, script_read,
  start_stop_play, get_console_output, user_keyboard_input, screen_capture, generate_mesh, …).
- Side session "Record MX Bikes telemetry to validate SPEC" (local_015e3ac1…) is recording real game data
  via the official proxy_udp plugin; its results should update SPEC.md.

## RESUME HERE (after restarting Claude Code in C:\Users\pitts\Documents\RoBikes)

1. Check that `Roblox_Studio` tools are loaded (e.g. `get_studio_state`). Studio must be open.
2. Build RoBikes from SPEC.md:
   - pure-Luau physics core in ./my-version/src (ModuleScripts; no Roblox API inside the core)
   - Roblox glue: input, camera, rendering, raycast ground query, HUD (telemetry readout)
   - our own bike visuals (simple parts or generate_mesh), NOT MX Bikes assets
3. Write Luau tests from the SPEC behavior tests; run them in Studio with execute_luau until they pass.
4. Play-test in Studio (start_stop_play + user_keyboard_input + screen_capture), then show the user how to run it.
