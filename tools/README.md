# MX Bikes telemetry recorder

Records the live physics data that MX Bikes **officially** shares with plugins, then measures how the bike
behaves. It uses only the game's own plugin `plugins/proxy_udp64.dlo` (made by PiBoSo and shipped with the game).
Nothing touches `mxbikes.exe`, the Steam DRM, or `rider.prm`.

```
MX Bikes ──RunTelemetry 100x/s──► proxy_udp64.dlo ──UDP 127.0.0.1:30001──► record_telemetry.js ──► CSV
                                                                                     │
                                                              analyze_telemetry.js ◄─┘ ──► _analysis.md/.json
```

## Files

| File | What it does |
|---|---|
| `record_telemetry.js` | Listens on UDP 127.0.0.1:30001 and writes the CSV files (below) |
| `analyze_telemetry.js` | Measures rates, conventions, suspension/damper, gears, slip, brakes from a recording |
| `mxb_packets.js` | Decodes (and, for tests, encodes) the plugin's packets |
| `fake_mxb_sender.js` | **Test only**: pretends to be the game so you can try everything without riding |

## 1. Turn the plugin on (one time)

Open `C:\Program Files (x86)\Steam\steamapps\common\MX Bikes\proxy_udp.ini`. It ships like this:

```
[params]
enable = 0
port = 30000
ip = 127.0.0.1:30001
delay = 1
```

Change `enable = 0` to `enable = 1` and add a line `info = 1` (this adds bike, track, lap and session packets).
Keep the other lines. `ip` is where the data goes (our recorder). `port` is the plugin's own sending port.
`delay = 1` means one packet every 10 ms. To turn it off again, set `enable = 0`.

## 2. Record

```bash
node tools/record_telemetry.js --name 450f_testtrack
```

Start it **before** you go on track. Every second it prints packets/s, gear, RPM and speed. Stop with **Ctrl+C**,
or add `--duration 180` to stop by itself. Recordings go to `recordings/`:

| File | Contents |
|---|---|
| `mxb_<time>_<name>_data.csv` | one row per data packet: `recv_ms, dup, state, time_ms` + the 47 official fields |
| `mxb_<time>_<name>_laps.csv` | lap and split times |
| `mxb_<time>_<name>_event.json` | bike, track, max suspension travel, steering lock, setup file name, conditions |
| `mxb_<time>_<name>_raw.bin` | every packet exactly as received (`--from-raw file` decodes it again) |

`state`: 0 = no bike on track (not written), 1 = paused, 2 = riding. `dup = 1` means the packet repeats the
previous one exactly. `time_ms` is the game's on-track time.

### What to ride (about 3 minutes, MXB Test Track, 450F, default setup)

Each part feeds one measurement:

1. **10 s idle in neutral**, not moving: idle RPM.
2. **2–3 full-throttle runs through all 4 gears**, clutch fully out: RPM vs speed per gear, wheelspin.
3. **5+ jumps of different sizes**, landing on both wheels: suspension and damper fit.
4. **A bumpy or whoops section**: more damper data (fast rebound).
5. **3 hard stops with the front brake**, then **3 with the rear brake**, using different lever amounts: brake pressure.
6. **A few slow full-lock turns**: steering lock.

Crashes are fine; crashed samples are ignored. If you change the setup, note the sprockets.

## 3. Analyze

```bash
node tools/analyze_telemetry.js recordings/mxb_<time>_450f_testtrack_data.csv
```

Options: `--cfg <path>/450xf.cfg` (read gears/dampers from an extracted bike file instead of the built-in 450F
numbers), `--fs 14 --rs 50` (sprockets, if you changed them), `--mass 154.8` (sprung mass for the damper fit).
It prints a report and writes `_analysis.md` and `_analysis.json` next to the CSV.

## What the plugin really does (REA decompile of proxy_udp64.dlo)

- `Startup` returns 0 = asks the game for telemetry at **100 Hz** (the fastest rate the interface offers).
  So the recorder can never see more than 100 states per second, even if the physics runs faster.
- A separate thread sends the **latest** state every `delay × 10` ms. Packets and game samples are not locked
  together: a late timer skips a sample and an early one repeats it. The analyzer keeps one row per `time_ms`.
- `time_ms = (int)(fTime × 1000)` with a float `fTime`, so time stamps are cut to whole milliseconds and a steady
  10 ms step shows up as 9/10/11 ms. The analyzer rebuilds the exact step with a line fit.
- `evnt`/`sesn` are sent every 1 s and `lap `/`splt` every 0.2 s (repeating the last values), only if `info = 1`.
  Their strings are NUL-terminated and not padded.

## What the game's numbers really mean (measured 2026-10-15, see REPORT.md §9)

Some of these differ from the comments in the official example:

- **Velocity is for the position reference point** (ground level), not the CG. Speedometer = its length.
- **Acceleration has no gravity in it** (0 standing still). It is in chassis axes and taken at the chassis CG,
  ~0.62 m above the reference point.
- **The rotation matrix's columns** are the chassis axes (side, up, forward). World +Y is up.
- **Suspension length is travel left** (0 = bottomed out). Its top is max travel − preload.
- **The brake-pressure fields are not filled** by this game build (random values). Ignore them.
- **After a crash the bike is teleported back.** The analyzer cuts the data there.

## Testing without the game

```bash
node tools/record_telemetry.js --out recordings/test --duration 15 --name synthetic
node tools/fake_mxb_sender.js --fast --seconds 120
node tools/analyze_telemetry.js recordings/test/<file>_data.csv --mass 153.5
```

Run the first command in one terminal and the second in another. The fake bike is a **made-up** model with known
answers (not MX Bikes physics). Its reports say "SYNTHETIC". On it, the analyzer recovers:

| Check | Known answer | Analyzer result |
|---|---|---|
| RPM per m/s, each gear | 498.5 / 415.4 / 348.9 / 294.5 | within 0.05% |
| Brake pressure at full lever (front / rear) | 2515 / 4209 kPa | exact |
| Accelerometer meaning | kinematic, chassis frame, 10 ms average | found (RMS error 0) |
| Damper knee speeds (fork 1.1, shock 0.4 m/s) | 1.1, 1.1, 0.4, 0.4 | all found exactly |
| Damper stages 2–3 (fork bump + rebound, shock rebound), shock bump stage 3 | known values | within 7% |
| Damper stage 1 (below 0.05 m/s) | known values | 13–28% off: rough |
| Shock bump stage 2 (0.05–0.4 m/s) | known value | 59% too high: rough |
| Spring rates (fork, shock) | 10000 / 20769 N/m at the wheel | within 11% |

Real game data is messier than this: the rider is a separate 80 kg body on springs, and the fork is raked.
So for the damper, trust the knee locations and "does 3-stage fit better than 1-stage" more than the exact
N·s/m values.
