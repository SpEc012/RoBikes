// Analyzes a recording made by record_telemetry.js and measures MX Bikes behavior:
//   1. how often new physics states arrive (telemetry rate, game clock)
//   2. conventions: world up axis, rotation-matrix layout, accelerometer meaning, speedometer source
//   3. suspension: travel, velocity sign, landings, and a fit of the 3-stage damper model
//   4. RPM vs rear wheel speed per gear, compared with the gear ratios from the bike .cfg
//   5. rear wheel slip (wheel speed vs ground speed) while accelerating, front slip while braking
//   6. quick checks: brake pressure, limiter, idle RPM, steering lock
// Writes <base>_analysis.json and <base>_analysis.md next to the CSV.
//
// Usage: node tools/analyze_telemetry.js recordings/mxb_..._data.csv [--cfg path/to/450xf.cfg] [--mass 186]
//        [--fs 14 --rs 50]   (front/rear sprocket teeth, if your setup changed them)
"use strict";
const fs = require("fs");
const path = require("path");

const G = 9.81;

// ---------- bike numbers (450xf stock, from bikes/450xf/450xf.cfg, ev_58e62a75; tyres ev_8f490ff3) ----------
const BIKE_450XF = {
  id: "450xf",
  primary: 76 / 32,
  gears: [[16, 32], [18, 30], [20, 28], [22, 26]],
  fs: 14, rs: 50, // FSprocketSetting 3, RSprocketSetting 6
  rearRadius: 0.325, frontRadius: 0.335,
  limiter: 11600, idleRPM: 2300,
  brakes: { front: { force: 40, lever: 11.1111, mc: 0.015, p2t: 0.156, dead: 0.01 },
            rear: { force: 40, lever: 10, mc: 0.011, p2t: 0.132, dead: 0.01 } },
  steerLock: 42,
  damper: {
    f: { bump: { t: [0.05, 1.1], c: [2360, 370, 1500] }, rebound: { t: [0.05, 1.1], c: [1500, 495, 1500] } },
    r: { bump: { t: [0.05, 0.4], c: [9000, 1800, 12000] }, rebound: { t: [0.05, 0.4], c: [6000, 4500, 12000] } },
  },
  mass: 64.31 + 10.5 + 80, // sprung mass: chassis + steering body (450xf.cfg) + rider (rider.cfg)
  preload: { f: 0.007, r: 0.012 }, // Preload settings 7 and 12 (x 0.001 m)
};

function bikeFromCfg(file, base) {
  const { parseFile } = require("./parse_piboso");
  const c = parseFile(file), b = JSON.parse(JSON.stringify(base));
  b.id = c.ID || path.basename(file, ".cfg");
  const [pa, pb] = c.engine.Ratio0; b.primary = pb / pa;
  b.gears = []; for (let i = 0; c.gearbox.gearing["ratio" + i]; i++) b.gears.push(c.gearbox.gearing["ratio" + i]);
  b.fs = c.driveline.FSprocket["gear" + c.driveline.FSprocketSetting];
  b.rs = c.driveline.RSprocket["gear" + c.driveline.RSprocketSetting];
  b.limiter = c.engine.Limiter0; b.idleRPM = c.engine.IdleRPM;
  b.steerLock = c.steer.Lock; b.mass = c.chassis.Mass + c.steer.Mass + 80; // sprung: chassis + steering + rider
  const val = (r) => r.range[0] + r.setting * r.range[1];
  b.preload = { f: val(c.front_suspension.Preload), r: val(c.rear_suspension.Preload) };
  for (const [w, key] of [["front", "wheel0"], ["rear", "wheel1"]]) {
    const br = c[key].Brake;
    b.brakes[w] = { force: br.RiderMaxForce, lever: br["Leverage" + br.leveragesetting].ratio,
      mc: br["MasterCylinder" + br.mastercylindersetting].Diameter, p2t: br["disc" + br.discsetting].PressureToTorque, dead: br.DeadZone };
  }
  const tab = (d, name) => d[name]["setting" + d[name + "Setting"]];
  const fd = c.front_suspension.Damper, rd = c.rear_suspension.Damper;
  b.damper.f.bump = { t: [-fd.BumpThreshold0, -fd.BumpThreshold1], c: tab(fd, "Bump") };
  b.damper.f.rebound = { t: [fd.ReboundThreshold0, fd.ReboundThreshold1], c: tab(fd, "Rebound") };
  const fast = tab(rd, "FastBump");
  b.damper.r.bump = { t: [-rd.BumpThreshold0, -rd.BumpThreshold1], c: [tab(rd, "Bump"), ...(Array.isArray(fast) ? fast : [fast])] };
  b.damper.r.rebound = { t: [rd.ReboundThreshold0, rd.ReboundThreshold1], c: tab(rd, "Rebound") };
  return b;
}

// ---------- small maths helpers ----------
const sum = (a) => a.reduce((s, x) => s + x, 0);
const mean = (a) => (a.length ? sum(a) / a.length : NaN);
function pct(a, p) { if (!a.length) return NaN; const s = [...a].sort((x, y) => x - y); const i = (s.length - 1) * p; const lo = Math.floor(i); return s[lo] + (s[Math.min(lo + 1, s.length - 1)] - s[lo]) * (i - lo); }
const median = (a) => pct(a, 0.5);
const rms = (a) => Math.sqrt(mean(a.map((x) => x * x)));
const r3 = (x, d = 3) => (Number.isFinite(x) ? Number(x.toFixed(d)) : null);
function corr(x, y) { const mx = mean(x), my = mean(y); let sxy = 0, sxx = 0, syy = 0; for (let i = 0; i < x.length; i++) { const a = x[i] - mx, b = y[i] - my; sxy += a * b; sxx += a * a; syy += b * b; } return sxy / Math.sqrt(sxx * syy); }
function linfit(x, y) { const mx = mean(x), my = mean(y); let sxy = 0, sxx = 0; for (let i = 0; i < x.length; i++) { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) ** 2; } if (!(sxx > 0)) return { slope: NaN, intercept: NaN, r: NaN, n: x.length }; const slope = sxy / sxx; return { slope, intercept: my - slope * mx, r: corr(x, y), n: x.length }; }
function fitThroughZero(x, y) { let sxy = 0, sxx = 0; for (let i = 0; i < x.length; i++) { sxy += x[i] * y[i]; sxx += x[i] * x[i]; } return sxy / sxx; }
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
// Rotation matrix with the chassis axes as columns (world = R * local), for either telemetry layout.
function rotOf(s, kind) {
  const c = [0, 1, 2].map((k) => (kind === "row" ? [s["rot" + k + "0"], s["rot" + k + "1"], s["rot" + k + "2"]] : [s["rot0" + k], s["rot1" + k], s["rot2" + k]]));
  return [0, 1, 2].map((i) => [c[0][i], c[1][i], c[2][i]]);
}
// World angular velocity (rad/s) that turns orientation a into b over dt.
function omegaWorld(a, b, kind, dt) {
  const A = rotOf(a, kind), B = rotOf(b, kind);
  const d = [0, 1, 2].map((i) => [0, 1, 2].map((j) => B[i][0] * A[j][0] + B[i][1] * A[j][1] + B[i][2] * A[j][2]));
  return [(d[2][1] - d[1][2]) / (2 * dt), (d[0][2] - d[2][0]) / (2 * dt), (d[1][0] - d[0][1]) / (2 * dt)];
}
function hist(values, step) { const h = new Map(); for (const v of values) { const k = Math.round(v / step) * step; h.set(k, (h.get(k) || 0) + 1); } return [...h.entries()].sort((a, b) => b[1] - a[1]); }

// Least squares with column scaling; drops columns with no variation. Returns coefficients and std errors.
function lstsq(X, y, names) {
  const n = X.length, p0 = names.length;
  const keep = [], scale = [];
  for (let j = 0; j < p0; j++) {
    let s = 0; for (let i = 0; i < n; i++) s += X[i][j] * X[i][j];
    s = Math.sqrt(s / n);
    if (s > 1e-9) { keep.push(j); scale.push(s); }
  }
  const p = keep.length;
  const A = Array.from({ length: p }, () => new Float64Array(p)), b = new Float64Array(p);
  for (let i = 0; i < n; i++) {
    const row = X[i];
    for (let a = 0; a < p; a++) {
      const xa = row[keep[a]] / scale[a];
      b[a] += xa * y[i];
      for (let c = a; c < p; c++) A[a][c] += xa * row[keep[c]] / scale[c];
    }
  }
  for (let a = 0; a < p; a++) for (let c = 0; c < a; c++) A[a][c] = A[c][a];
  for (let a = 0; a < p; a++) A[a][a] += 1e-9 * n;
  const inv = invert(A);
  const beta = new Float64Array(p);
  for (let a = 0; a < p; a++) for (let c = 0; c < p; c++) beta[a] += inv[a][c] * b[c];
  let rss = 0;
  const resid = new Float64Array(n);
  for (let i = 0; i < n; i++) { let f = 0; for (let a = 0; a < p; a++) f += beta[a] * X[i][keep[a]] / scale[a]; resid[i] = y[i] - f; rss += resid[i] ** 2; }
  const s2 = rss / Math.max(1, n - p);
  const coef = {}, se = {};
  for (const nm of names) { coef[nm] = null; se[nm] = null; }
  for (let a = 0; a < p; a++) { coef[names[keep[a]]] = beta[a] / scale[a]; se[names[keep[a]]] = Math.sqrt(s2 * inv[a][a]) / scale[a]; }
  const my = mean(y); let tss = 0; for (const v of y) tss += (v - my) ** 2;
  return { coef, se, rmsResidual: Math.sqrt(rss / n), r2: 1 - rss / tss, n };
}
function invert(M) {
  const n = M.length, A = M.map((r) => Float64Array.from(r)), I = Array.from({ length: n }, (_, i) => { const r = new Float64Array(n); r[i] = 1; return r; });
  for (let c = 0; c < n; c++) {
    let piv = c; for (let r = c + 1; r < n; r++) if (Math.abs(A[r][c]) > Math.abs(A[piv][c])) piv = r;
    [A[c], A[piv]] = [A[piv], A[c]]; [I[c], I[piv]] = [I[piv], I[c]];
    const d = A[c][c]; if (Math.abs(d) < 1e-300) throw new Error("singular matrix");
    for (let k = 0; k < n; k++) { A[c][k] /= d; I[c][k] /= d; }
    for (let r = 0; r < n; r++) if (r !== c) { const f = A[r][c]; if (f) for (let k = 0; k < n; k++) { A[r][k] -= f * A[c][k]; I[r][k] -= f * I[c][k]; } }
  }
  return I;
}

// ---------- loading ----------
function loadCsv(file) {
  const lines = fs.readFileSync(file, "utf8").split(/\r?\n/).filter(Boolean);
  const head = lines[0].split(",");
  return lines.slice(1).map((l) => { const v = l.split(","), o = {}; head.forEach((h, i) => (o[h] = Number(v[i]))); return o; });
}

// Keeps running samples, one per game time stamp, split into continuous segments.
// The plugin sends (int)(fTime * 1000) with a float fTime, so stamps are cut to whole ms and a steady
// 10 ms step shows up as 9/10/11. When the steps are regular we rebuild the exact time from a line fit.
function samplesOf(rows) {
  const out = [];
  for (const r of rows) {
    if (r.state !== 2 || r.dup === 1) continue;
    if (out.length && out[out.length - 1].time_ms === r.time_ms) continue;
    out.push(r);
  }
  let seg = 0, resets = 0;
  for (let i = 0; i < out.length; i++) {
    if (i > 0) {
      // A new segment starts after a time gap, a time reset, or a position jump the velocity can't explain
      // (the game puts the bike back on track after a crash).
      const a = out[i - 1], b = out[i], d = b.time_ms - a.time_ms, dt = d / 1000;
      const jump = Math.hypot(b.pos_x - a.pos_x - ((a.vel_x + b.vel_x) / 2) * dt, b.pos_y - a.pos_y - ((a.vel_y + b.vel_y) / 2) * dt,
        b.pos_z - a.pos_z - ((a.vel_z + b.vel_z) / 2) * dt);
      if (d <= 0 || d > 200 || jump > 0.3) { seg++; if (d > 0 && d <= 200) resets++; }
    }
    out[i].seg = seg;
    out[i].v = [out[i].vel_x, out[i].vel_y, out[i].vel_z];
    out[i].speed = Math.hypot(out[i].vel_x, out[i].vel_y, out[i].vel_z);
    out[i].air = out[i].wheel_mat_f === 0 && out[i].wheel_mat_r === 0;
  }
  const timing = { segments: seg + 1, position_resets: resets, rebuilt_segments: 0, step_ms: [], max_abs_residual_ms: 0 };
  for (let s = 0, i0 = 0; i0 < out.length; s++) {
    let i1 = i0; while (i1 < out.length && out[i1].seg === s) i1++;
    const part = out.slice(i0, i1);
    let rebuilt = false;
    if (part.length > 20) {
      const d = []; for (let k = 1; k < part.length; k++) d.push(part[k].time_ms - part[k - 1].time_ms);
      // Base step = the cluster of the smallest steps (skipped samples make 2x, 3x steps).
      const dMin = pct(d, 0.05), q = median(d.filter((x) => x <= dMin + 1.5));
      // Count base steps one gap at a time (robust to slow drift), then fit the exact step length.
      const n = [0]; for (let k = 1; k < part.length; k++) n.push(n[k - 1] + Math.max(1, Math.round(d[k - 1] / q)));
      const f = linfit(n, part.map((p) => p.time_ms));
      const res = part.map((p, k) => p.time_ms - (f.intercept + f.slope * n[k]));
      const worst = Math.max(...res.map(Math.abs));
      if (worst < 2) {
        part.forEach((p, k) => (p.t = (f.intercept + f.slope * n[k] + 0.5) / 1000));
        timing.rebuilt_segments++; timing.step_ms.push(r3(f.slope, 4));
        timing.max_abs_residual_ms = Math.max(timing.max_abs_residual_ms, r3(worst, 3));
        rebuilt = true;
      }
    }
    if (!rebuilt) part.forEach((p) => (p.t = (p.time_ms + 0.5) / 1000));
    i0 = i1;
  }
  out.timing = timing;
  return out;
}
// True when samples i-1 and i are one normal step apart (no skipped sample, same segment).
const oneStep = (S, i) => i > 0 && i < S.length && S[i].seg === S[i - 1].seg && S[i].t - S[i - 1].t < 0.015;
const sameSeg = (s, i, j) => j >= 0 && j < s.length && s[i].seg === s[j].seg;

// ---------- 1. rates ----------
function analyzeRates(rows, S) {
  const run = rows.filter((r) => r.state === 2);
  const res = { packets_running: run.length, exact_duplicate_packets: run.filter((r) => r.dup === 1).length };
  if (run.length < 10) return { ...res, note: "too few running packets" };
  // Real time spent riding = sum of stretches of running packets (gaps over 1 s are pits/menus/pause).
  let ridingSpan = 0;
  for (let i = 1; i < run.length; i++) { const g = run[i].recv_ms - run[i - 1].recv_ms; if (g < 1000) ridingSpan += g; }
  ridingSpan /= 1000;
  res.recording_seconds = r3((run[run.length - 1].recv_ms - run[0].recv_ms) / 1000, 1);
  res.riding_seconds = r3(ridingSpan, 1);
  res.packets_per_second = r3(run.length / ridingSpan, 1);
  const deltas = [];
  let gameSpan = 0, realSpan = 0, segStart = 0;
  for (let i = 1; i <= S.length; i++) {
    if (i === S.length || S[i].seg !== S[i - 1].seg) {
      gameSpan += S[i - 1].t - S[segStart].t; realSpan += (S[i - 1].recv_ms - S[segStart].recv_ms) / 1000; segStart = i; continue;
    }
    deltas.push(S[i].time_ms - S[i - 1].time_ms);
  }
  res.distinct_game_samples = S.length;
  res.new_samples_per_game_second = r3(deltas.length / gameSpan, 2);
  res.game_seconds_per_real_second = r3(gameSpan / realSpan, 4);
  res.game_time_step_histogram_ms = hist(deltas, 1).slice(0, 8).map(([k, n]) => ({ ms: k, count: n }));
  const mode = res.game_time_step_histogram_ms[0].ms;
  res.typical_step_ms = mode;
  res.fraction_steps_multiple_of_10ms = r3(deltas.filter((d) => Math.abs(d - 10 * Math.round(d / 10)) <= 1).length / deltas.length, 4);
  res.skipped_samples = deltas.filter((d) => d >= 1.5 * mode).reduce((s, d) => s + Math.round(d / mode) - 1, 0);
  res.rebuilt_time = { ...S.timing, note: "time_ms is truncated to whole ms; when steps are regular the exact step is fitted (step_ms per segment)" };
  const arrivals = []; for (let i = 1; i < run.length; i++) arrivals.push(run[i].recv_ms - run[i - 1].recv_ms);
  res.packet_arrival_gap_ms = { median: r3(median(arrivals), 2), p05: r3(pct(arrivals, 0.05), 2), p95: r3(pct(arrivals, 0.95), 2) };
  // Does the time stamp match the physics state? Position change vs average velocity over each step.
  const err = [], mv = [];
  for (let i = 1; i < S.length; i++) {
    if (!oneStep(S, i) || S[i].crashed) continue;
    const dt = S[i].t - S[i - 1].t;
    for (const [p, v] of [["pos_x", "vel_x"], ["pos_y", "vel_y"], ["pos_z", "vel_z"]]) {
      err.push((S[i][p] - S[i - 1][p]) / dt - (S[i][v] + S[i - 1][v]) / 2); mv.push(Math.abs(S[i][v]));
    }
  }
  res.position_vs_velocity_rms_error_mps = r3(rms(err), 4);
  res.mean_abs_velocity_mps = r3(mean(mv), 2);
  return res;
}

// ---------- 2. conventions ----------
function analyzeConventions(S) {
  const res = {};
  // World up axis: average acceleration while both wheels are off the ground (mostly gravity).
  const airAcc = [0, 0, 0]; let nAir = 0;
  for (let i = 1; i < S.length - 1; i++) {
    if (!S[i].air || !S[i - 1].air || !S[i + 1].air || S[i].crashed || !sameSeg(S, i, i - 1) || !sameSeg(S, i, i + 1)) continue;
    const dt = S[i + 1].t - S[i - 1].t;
    for (let k = 0; k < 3; k++) airAcc[k] += (S[i + 1].v[k] - S[i - 1].v[k]) / dt;
    nAir++;
  }
  let up = [0, 1, 0];
  if (nAir >= 10) {
    const a = airAcc.map((x) => x / nAir), k = a.map(Math.abs).indexOf(Math.max(...a.map(Math.abs)));
    up = [0, 0, 0]; up[k] = -Math.sign(a[k]);
    res.airborne_samples = nAir;
    res.airborne_mean_accel_world_mps2 = a.map((x) => r3(x, 2));
    res.world_up_axis = `${up[k] > 0 ? "+" : "-"}${"XYZ"[k]}`;
  } else {
    res.world_up_axis = "+Y (assumed: not enough airtime to measure)";
  }
  // Rotation matrix layout: which row/column of m_aafRot points along the velocity (forward) and up.
  const vec = (s, kind, k) => (kind === "row" ? [s["rot" + k + "0"], s["rot" + k + "1"], s["rot" + k + "2"]] : [s["rot0" + k], s["rot1" + k], s["rot2" + k]]);
  const moving = S.filter((s) => !s.crashed && s.wheel_mat_f > 0 && s.wheel_mat_r > 0 && Math.hypot(...s.v) > 5);
  let best = null;
  for (const kind of ["row", "col"]) for (let k = 0; k < 3; k++) {
    const m = mean(moving.map((s) => { const u = vec(s, kind, k), sp = Math.hypot(...s.v); return dot(u, s.v) / sp; }));
    if (!best || Math.abs(m) > Math.abs(best.m)) best = { kind, k, m };
  }
  let layout = { kind: "row", fwd: 2, fwdSign: 1, up: 1, upSign: 1 };
  if (best && moving.length > 20) {
    let bestUp = null;
    for (let k = 0; k < 3; k++) {
      if (k === best.k) continue;
      const m = mean(moving.map((s) => dot(vec(s, best.kind, k), up)));
      if (!bestUp || Math.abs(m) > Math.abs(bestUp.m)) bestUp = { k, m };
    }
    layout = { kind: best.kind, fwd: best.k, fwdSign: Math.sign(best.m), up: bestUp.k, upSign: Math.sign(bestUp.m) };
    res.rotation_matrix = {
      forward_axis: `${layout.fwdSign > 0 ? "+" : "-"}${best.kind} ${best.k}`, forward_alignment_with_velocity: r3(best.m, 3),
      up_axis: `${layout.upSign > 0 ? "+" : "-"}${best.kind} ${bestUp.k}`, up_alignment_with_world_up: r3(bestUp.m, 3),
      samples: moving.length,
    };
  } else res.rotation_matrix = "not enough moving samples (need > 5 m/s with both wheels down)";
  // Accelerometer: compare acc_x/y/z with velocity changes turned into the chassis frame.
  const cands = [];
  for (const kind of ["row", "col"]) for (const grav of ["kinematic", "specific_force"]) for (const diff of ["backward_10ms", "central"]) {
    const e = [];
    for (let i = 1; i < S.length - 1; i++) {
      if (S[i].crashed || !oneStep(S, i) || !oneStep(S, i + 1)) continue;
      const a0 = i - 1, a1 = diff === "central" ? i + 1 : i;
      const dt = S[a1].t - S[a0].t;
      const aw = [0, 1, 2].map((k) => (S[a1].v[k] - S[a0].v[k]) / dt - (grav === "specific_force" ? -G * up[k] : 0));
      const rep = [S[i].acc_x, S[i].acc_y, S[i].acc_z];
      for (let k = 0; k < 3; k++) e.push(rep[k] - dot(vec(S[i], kind, k), aw) / G);
    }
    cands.push({ layout: kind, gravity: grav, derivative: diff, rms_error_G: r3(rms(e), 4) });
  }
  cands.sort((a, b) => a.rms_error_G - b.rms_error_G);
  res.accelerometer_best_match = cands[0];
  res.accelerometer_candidates = cands;
  // Gravity in the accelerometer? Standing still a real accelerometer reads +1 G up; a kinematic one reads 0.
  const still = S.filter((s) => !s.crashed && s.speed < 0.05 && s.wheel_mat_f > 0 && s.wheel_mat_r > 0);
  let accSpecific = cands[0].gravity === "specific_force";
  if (still.length >= 50) {
    const m = ["acc_x", "acc_y", "acc_z"].map((k) => mean(still.map((s) => s[k])));
    accSpecific = Math.abs(m[layout.up] * layout.upSign - 1) < Math.abs(m[layout.up] * layout.upSign);
    res.accelerometer_at_rest_G = { samples: still.length, mean_xyz: m.map((x) => r3(x, 3)), meaning: accSpecific ? "includes gravity (+1 G up at rest)" : "kinematic: no gravity (0 at rest)" };
  }
  // Which point do velocity and acceleration belong to? Velocity: compare with position changes, allowing the
  // velocity to belong to a point h metres up the chassis axis (v_point = v_ref + w x r). Acceleration: allow
  // the accelerometer to sit h metres up (a_point = a_ref + dw/dt x r + w x (w x r)).
  const hs = [-0.6, -0.3, -0.15, 0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9], velErr = hs.map(() => []);
  const accRows = [];
  for (let i = 2; i < S.length; i++) {
    if (S[i].crashed || S[i - 1].crashed || !oneStep(S, i)) continue;
    const a = S[i - 1], b = S[i], dt = b.t - a.t, w1 = omegaWorld(a, b, layout.kind, dt);
    const u = vec(b, layout.kind, layout.up).map((x) => x * layout.upSign);
    const dp = ["pos_x", "pos_y", "pos_z"].map((k) => (b[k] - a[k]) / dt), vavg = [0, 1, 2].map((k) => (a.v[k] + b.v[k]) / 2);
    hs.forEach((h, j) => { const wr = cross(w1, u.map((x) => x * h)); velErr[j].push(Math.hypot(...[0, 1, 2].map((k) => dp[k] - (vavg[k] - wr[k])))); });
    if (!oneStep(S, i - 1) || !oneStep(S, i + 1) || S[i - 2].crashed || S[i + 1].crashed) continue;
    // Spin rate at samples i-1 and i (central differences), so dw/dt covers the same window as the
    // accelerometer's average, [t(i-1), t(i)].
    const wPrev = omegaWorld(S[i - 2], b, layout.kind, b.t - S[i - 2].t), wNow = omegaWorld(a, S[i + 1], layout.kind, S[i + 1].t - a.t);
    const wd = [0, 1, 2].map((k) => (wNow[k] - wPrev[k]) / dt);
    const q = cross(wd, u).map((x, k) => x + cross(w1, cross(w1, u))[k]);
    const aw = [0, 1, 2].map((k) => (b.v[k] - a.v[k]) / dt + (accSpecific ? G * up[k] : 0));
    const rep = [b.acc_x, b.acc_y, b.acc_z];
    accRows.push([0, 1, 2].map((k) => { const ax = vec(b, layout.kind, k); return { e: rep[k] * G - dot(ax, aw), q: dot(ax, q) }; }));
  }
  if (accRows.length > 100) {
    const vm = velErr.map((e) => median(e)), jb = vm.indexOf(Math.min(...vm));
    res.velocity_reference_point = { best_h_m: hs[jb], median_error_mps_at_best: r3(vm[jb], 4), median_error_mps_at_h0: r3(vm[hs.indexOf(0)], 4),
      meaning: "h = height up the chassis axis, above the position point, of the point whose velocity is reported" };
    const fitH = (ks) => { let sq = 0, se = 0; for (const r of accRows) for (const k of ks) { sq += r[k].q * r[k].q; se += r[k].q * r[k].e; } return se / sq; };
    const hAll = fitH([0, 1, 2]);
    res.accelerometer_point = { h_m_all_axes: r3(hAll, 3), h_m_per_axis: [0, 1, 2].map((k) => r3(fitH([k]), 3)),
      rms_error_mps2_before: [0, 1, 2].map((k) => r3(rms(accRows.map((r) => r[k].e)), 3)),
      rms_error_mps2_after: [0, 1, 2].map((k) => r3(rms(accRows.map((r) => r[k].e - hAll * r[k].q)), 3)),
      meaning: "the accelerometer behaves like a point h metres up the chassis axis from the velocity point" };
  }
  // Speedometer source.
  const sp = S.filter((s) => !s.crashed && Math.hypot(...s.v) > 2);
  const fwdSpeed = (s) => dot(vec(s, layout.kind, layout.fwd), s.v) * layout.fwdSign;
  res.speedometer_rms_difference_mps = {
    vs_speed_3d: r3(rms(sp.map((s) => s.speedometer - Math.hypot(...s.v))), 3),
    vs_forward_speed: r3(rms(sp.map((s) => s.speedometer - fwdSpeed(s))), 3),
    vs_front_wheel_speed: r3(rms(sp.map((s) => s.speedometer - s.wheel_speed_f)), 3),
    vs_rear_wheel_speed: r3(rms(sp.map((s) => s.speedometer - s.wheel_speed_r)), 3),
  };
  return { res, up, layout, vec, accSpecific, fwdSpeed };
}

// ---------- 3. suspension and damper fit ----------
function damperBasis(u, t0, t1) { return [Math.min(u, t0), Math.min(Math.max(u - t0, 0), t1 - t0), Math.max(u - t1, 0)]; }

function analyzeSuspension(S, conv, bike, info, mass) {
  const res = {}, ends = { f: {}, r: {} };
  for (const e of ["f", "r"]) {
    const L = "susp_len_" + e, V = "susp_vel_" + e, M = "wheel_mat_" + e;
    const all = S.filter((s) => !s.crashed).map((s) => s[L]);
    // Length while this wheel has been in the air for a while (fully extended).
    const airL = [], groundL = [];
    let airRun = 0;
    for (let i = 0; i < S.length; i++) {
      if (S[i].crashed) { airRun = 0; continue; }
      airRun = S[i][M] === 0 && sameSeg(S, i, i - 1) ? airRun + 1 : 0;
      if (airRun >= 15) airL.push(S[i][L]); else if (S[i][M] > 0) groundL.push(S[i][L]);
    }
    const Lair = airL.length > 5 ? median(airL) : Math.max(...all);
    const sc = airL.length > 5 ? (median(groundL) < Lair ? -1 : 1) : -1; // -1: length gets shorter when compressed
    // Is susp_vel the time derivative of susp_len? (length change over one step vs mean of the two velocities)
    const dl = [], vv = [];
    for (let i = 1; i < S.length; i++) {
      if (S[i].crashed || !oneStep(S, i)) continue;
      dl.push((S[i][L] - S[i - 1][L]) / (S[i].t - S[i - 1].t)); vv.push((S[i][V] + S[i - 1][V]) / 2);
    }
    const vfit = linfit(dl, vv);
    const sv = Math.sign(vfit.slope) || 1;
    ends[e] = { L, V, M, Lair, sc, sv };
    const comp = S.filter((s) => !s.crashed).map((s) => sc * sv * s[V]).filter((u) => u > 0);
    const t = bike.damper[e].bump.t;
    res[e === "f" ? "front" : "rear"] = {
      length_min_m: r3(Math.min(...all), 4), length_max_m: r3(Math.max(...all), 4),
      length_fully_extended_m: r3(Lair, 4), fully_extended_from: airL.length > 5 ? `${airL.length} airborne samples` : "maximum (no long airtime)",
      travel_used_m: r3(Math.abs(Lair - (sc < 0 ? Math.min(...all) : Math.max(...all))), 4),
      max_travel_reported_by_game_m: info && info.evnt ? r3(info.evnt["susp_max_travel_" + e], 4) : null,
      max_travel_minus_cfg_preload_m: info && info.evnt ? r3(info.evnt["susp_max_travel_" + e] - bike.preload[e], 4) : null,
      compression_makes_length: sc < 0 ? "shorter" : "longer",
      susp_vel_vs_dlen_dt: { slope: r3(vfit.slope, 3), r: r3(vfit.r, 4), n: vfit.n },
      compression_velocity_sign: sc * sv < 0 ? "negative" : "positive",
      compression_speed_percentiles_mps: { p50: r3(pct(comp, 0.5)), p90: r3(pct(comp, 0.9)), p99: r3(pct(comp, 0.99)), max: r3(Math.max(...comp, 0)) },
      fraction_of_compression_samples_above_threshold0: r3(comp.filter((u) => u > t[0]).length / comp.length, 3),
      fraction_of_compression_samples_above_threshold1: r3(comp.filter((u) => u > t[1]).length / comp.length, 3),
    };
  }
  // Landings: both wheels airborne for >= 0.25 s, then touchdown.
  const landings = [];
  for (let i = 1; i < S.length; i++) {
    if (S[i].air || !S[i - 1].air || S[i].crashed) continue;
    let j = i - 1; while (j > 0 && S[j - 1].air && sameSeg(S, j, j - 1)) j--;
    const air = S[i].t - S[j].t;
    if (air < 0.25) continue;
    const win = S.slice(i, i + 60).filter((s) => s.seg === S[i].seg && s.t - S[i].t <= 0.6);
    const ef = ends.f, er = ends.r;
    landings.push({
      t: r3(S[i].t, 2), airtime_s: r3(air, 2), vertical_speed_at_touchdown_mps: r3(dot(S[i - 1].v, conv.up), 2),
      first_contact: S[i].wheel_mat_f > 0 && S[i].wheel_mat_r > 0 ? "both" : S[i].wheel_mat_f > 0 ? "front" : "rear",
      peak_compression_front_m: r3(Math.max(...win.map((s) => ef.sc * (s[ef.L] - ef.Lair))), 3),
      peak_compression_rear_m: r3(Math.max(...win.map((s) => er.sc * (s[er.L] - er.Lair))), 3),
      peak_comp_speed_front_mps: r3(Math.max(...win.map((s) => ef.sc * ef.sv * s[ef.V])), 2),
      peak_comp_speed_rear_mps: r3(Math.max(...win.map((s) => er.sc * er.sv * s[er.V])), 2),
      peak_accel_G: r3(Math.max(...win.map((s) => Math.hypot(s.acc_x, s.acc_y, s.acc_z))), 2),
      crashed_after: win.some((s) => s.crashed) ? 1 : 0,
    });
  }
  res.landings = landings;

  // Damper fit. Target: chassis "up" specific force times an assumed sprung mass (N) =
  //   const + sum over ends [ preload*inContact + k*x + k2*x^2 + 3-stage bump(c1,c2,c3) - 3-stage rebound(c1,c2,c3) ]
  // x = compression and u = compression speed of the shock itself (shaft), as the telemetry reports them.
  // The game's acceleration is the average over the last 10 ms, so each feature is averaged over the same
  // window (mean of this sample and the previous one).
  // NOT modeled: rider leg forces (the 80 kg rider is a separate body on springs), tyre compliance, wheel mass,
  // and the linkage/rake geometry (rear coefficients come out as c / motion ratio). So absolute numbers are
  // rough; the useful outputs are the shape (ratios between stages) and whether 3 stages beat 1.
  const { layout, vec, up, accSpecific } = conv;
  const featureIdx = [], landingIdx = [];
  const landT = landings.map((l) => l.t);
  for (let i = 1; i < S.length; i++) {
    const s = S[i];
    if (s.crashed || S[i - 1].crashed || !oneStep(S, i) || Math.hypot(s.acc_x, s.acc_y, s.acc_z) > 8) continue;
    // A wheel touching down or lifting off inside the 10 ms window can't be averaged from two samples.
    if ((s.wheel_mat_f > 0) !== (S[i - 1].wheel_mat_f > 0) || (s.wheel_mat_r > 0) !== (S[i - 1].wheel_mat_r > 0)) continue;
    featureIdx.push(i);
    if (landT.some((t) => s.t >= t - 0.02 && s.t <= t + 0.6)) landingIdx.push(i);
  }
  const targetOf = (s) => {
    const acc = [s.acc_x, s.acc_y, s.acc_z][layout.up] * layout.upSign;
    const fUp = accSpecific ? acc : acc + dot(vec(s, layout.kind, layout.up), up) * layout.upSign;
    return fUp * G * mass;
  };
  const rowOf = (s, thr, stages) => {
    const row = [1];
    for (const e of ["f", "r"]) {
      const en = ends[e], x = Math.max(0, en.sc * (s[en.L] - en.Lair)), u = en.sc * en.sv * s[en.V];
      row.push(x > 0.003 ? 1 : 0, x, x * x);
      const tb = thr[e].bump, tr = thr[e].rebound;
      if (stages === 3) row.push(...damperBasis(Math.max(u, 0), tb[0], tb[1]), ...damperBasis(Math.max(-u, 0), tr[0], tr[1]).map((q) => -q));
      else row.push(Math.max(u, 0), -Math.max(-u, 0));
    }
    return row;
  };
  const names = (stages) => {
    const n = ["const"];
    for (const e of ["f", "r"]) {
      n.push(`${e}_preload`, `${e}_k`, `${e}_k2`);
      if (stages === 3) n.push(`${e}_bump_c1`, `${e}_bump_c2`, `${e}_bump_c3`, `${e}_reb_c1`, `${e}_reb_c2`, `${e}_reb_c3`);
      else n.push(`${e}_bump_c`, `${e}_reb_c`);
    }
    return n;
  };
  const solve = (idx, thr, stages) => {
    const X = idx.map((i) => { const a = rowOf(S[i], thr, stages), b = rowOf(S[i - 1], thr, stages); return a.map((v, k) => (v + b[k]) / 2); });
    return lstsq(X, idx.map((i) => targetOf(S[i])), names(stages));
  };
  const cfgThr = { f: { bump: bike.damper.f.bump.t, rebound: bike.damper.f.rebound.t }, r: { bump: bike.damper.r.bump.t, rebound: bike.damper.r.rebound.t } };
  const fitSet = (idx, withScans) => {
    const out = { samples: idx.length, assumed_mass_kg: mass };
    if (idx.length < 200) return { ...out, note: "not enough samples" };
    const m1 = solve(idx, cfgThr, 1), m3 = solve(idx, cfgThr, 3);
    out.one_stage = { rms_residual_N: r3(m1.rmsResidual, 1), r2: r3(m1.r2, 4) };
    out.three_stage = { rms_residual_N: r3(m3.rmsResidual, 1), r2: r3(m3.r2, 4) };
    out.improvement_three_vs_one_percent = r3(100 * (1 - m3.rmsResidual / m1.rmsResidual), 2);
    out.coefficients = {};
    for (const e of ["f", "r"]) for (const [dir, short] of [["bump", "bump"], ["rebound", "reb"]]) {
      const c = [1, 2, 3].map((k) => m3.coef[`${e}_${short}_c${k}`]), se = [1, 2, 3].map((k) => m3.se[`${e}_${short}_c${k}`]);
      const cfg = bike.damper[e][dir].c;
      out.coefficients[`${e === "f" ? "front" : "rear"}_${dir}`] = {
        fitted_N_s_per_m: c.map((x) => r3(x, 0)), std_error: se.map((x) => r3(x, 0)),
        fitted_ratio_c2_c1: r3(c[1] / c[0], 3), fitted_ratio_c3_c1: r3(c[2] / c[0], 3),
        cfg_values: cfg, cfg_ratio_c2_c1: r3(cfg[1] / cfg[0], 3), cfg_ratio_c3_c1: r3(cfg[2] / cfg[0], 3),
        // Same law as the cfg (times one geometry factor, e.g. 1/linkage ratio at the rear) => these 3 are equal.
        fitted_over_cfg_per_stage: c.map((x, k) => r3(x / cfg[k], 3)),
      };
    }
    out.springs = {};
    for (const e of ["f", "r"]) out.springs[e === "f" ? "front" : "rear"] = { preload_N: r3(m3.coef[`${e}_preload`], 0), k_N_per_m: r3(m3.coef[`${e}_k`], 0), k2_N_per_m2: r3(m3.coef[`${e}_k2`], 0) };
    if (!withScans) return out;
    // Threshold scan: move one threshold at a time and see where the fit is best.
    const scans = {};
    const grid1 = [0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0, 1.1, 1.3, 1.6, 2.0], grid0 = [0.01, 0.02, 0.03, 0.05, 0.08, 0.12, 0.2];
    for (const e of ["f", "r"]) for (const dir of ["bump", "rebound"]) for (const [ti, grid] of [[0, grid0], [1, grid1]]) {
      const curve = [];
      for (const g of grid) {
        const thr = JSON.parse(JSON.stringify(cfgThr));
        thr[e][dir][ti] = g;
        if (thr[e][dir][0] >= thr[e][dir][1]) continue;
        curve.push({ threshold: g, rms_N: r3(solve(idx, thr, 3).rmsResidual, 2) });
      }
      const bestPt = curve.reduce((a, b) => (b.rms_N < a.rms_N ? b : a));
      const worst = Math.max(...curve.map((c) => c.rms_N));
      scans[`${e === "f" ? "front" : "rear"}_${dir}_threshold${ti}`] = {
        cfg: cfgThr[e][dir][ti], best: bestPt.threshold, contrast_percent: r3(100 * (worst - bestPt.rms_N) / worst, 2), curve,
      };
    }
    out.threshold_scans = scans;
    return out;
  };
  res.damper_fit = fitSet(featureIdx, true);
  res.damper_fit_landings_only = fitSet(landingIdx, false);
  return { res, ends };
}

// ---------- 4. gears ----------
function steady(S, i, key, n) { for (let k = -n; k <= n; k++) { const j = i + k; if (!sameSeg(S, i, j) || S[j][key] !== S[i][key]) return false; } return true; }

function analyzeGears(S, conv, bike, fs_, rs_) {
  const final = rs_ / fs_;
  const out = { primary: r3(bike.primary, 4), final_drive: `${rs_}/${fs_} = ${r3(final, 4)}`, rear_radius_m: bike.rearRadius, per_gear: [] };
  const byGear = {};
  for (let i = 0; i < S.length; i++) {
    const s = S[i];
    if (s.crashed || s.gear < 1 || s.clutch > 0.05 || s.wheel_mat_r === 0 || s.wheel_speed_r < 4 || s.rpm < 3000 || s.rpm > bike.limiter - 100) continue;
    if (!steady(S, i, "gear", 3)) continue;
    (byGear[s.gear] = byGear[s.gear] || []).push(s);
  }
  for (let g = 1; g <= bike.gears.length; g++) {
    const [a, b] = bike.gears[g - 1], R = bike.primary * (b / a) * final;
    const predicted = (R * 60) / (2 * Math.PI * bike.rearRadius);
    const rows = byGear[g] || [];
    const entry = { gear: g, pair: `${a}:${b}`, total_ratio: r3(R, 3), predicted_rpm_per_mps: r3(predicted, 1), samples: rows.length };
    if (rows.length >= 10) {
      const k = rows.map((s) => s.rpm / s.wheel_speed_r), kg = rows.map((s) => s.rpm / Math.max(1, s.speed));
      const m = median(k);
      Object.assign(entry, {
        measured_rpm_per_mps_rear_wheel: r3(m, 1), spread_p10_p90: [r3(pct(k, 0.1), 1), r3(pct(k, 0.9), 1)],
        error_percent: r3(100 * (m / predicted - 1), 2),
        implied_wheel_radius_m: r3((R * 60) / (2 * Math.PI * m), 4),
        measured_rpm_per_mps_ground: r3(median(kg), 1),
        speed_at_limiter_kmh: r3((bike.limiter / m) * 3.6, 1),
      });
    }
    out.per_gear.push(entry);
  }
  const g = out.per_gear;
  out.gear_step_ratios = [];
  for (let i = 0; i + 1 < g.length; i++) {
    if (!g[i].measured_rpm_per_mps_rear_wheel || !g[i + 1].measured_rpm_per_mps_rear_wheel) continue;
    out.gear_step_ratios.push({ from: g[i].gear, to: g[i + 1].gear, measured: r3(g[i].measured_rpm_per_mps_rear_wheel / g[i + 1].measured_rpm_per_mps_rear_wheel, 4), cfg: r3(g[i].total_ratio / g[i + 1].total_ratio, 4) });
  }
  return out;
}

// ---------- 5. slip ----------
// Ground speed = 3D speed of the CG (the chassis "forward" axis is pitched, so it under-reads).
// Slip = (wheel speed - ground speed) / ground speed; positive = wheel spinning faster than the ground.
function analyzeSlip(S, conv) {
  const out = {};
  const q3 = (a) => [r3(pct(a, 0.1), 4), r3(pct(a, 0.5), 4), r3(pct(a, 0.9), 4)];
  const ok = S.filter((s) => !s.crashed && s.wheel_mat_f > 0 && s.wheel_mat_r > 0);
  const kapR = (s) => (s.wheel_speed_r - s.speed) / Math.max(1, s.speed);
  const kapF = (s) => (s.wheel_speed_f - s.speed) / Math.max(1, s.speed);
  const fwdAcc = (s) => [s.acc_x, s.acc_y, s.acc_z][conv.layout.fwd] * conv.layout.fwdSign;
  const roll = ok.filter((s) => s.brake_f < 0.02 && s.speed > 5);
  out.front_free_rolling = { samples: roll.length, wheel_slip_p10_p50_p90: q3(roll.map(kapF)) };
  const cruise = ok.filter((s) => s.throttle < 0.3 && s.brake_r < 0.02 && s.brake_f < 0.02 && Math.abs(fwdAcc(s)) < 0.1 && s.speed > 5);
  out.rear_cruise = { samples: cruise.length, slip_p10_p50_p90: q3(cruise.map(kapR)) };
  const accel = ok.filter((s) => s.throttle > 0.8 && s.clutch < 0.05 && s.gear >= 1 && s.speed > 3);
  out.rear_full_throttle = { samples: accel.length, slip_p10_p50_p90: q3(accel.map(kapR)) };
  const perGear = {};
  for (const s of accel) (perGear[s.gear] = perGear[s.gear] || []).push(s);
  out.rear_full_throttle.per_gear = Object.entries(perGear).map(([g, a]) => ({ gear: Number(g), samples: a.length, slip_p10_p50_p90: q3(a.map(kapR)), median_forward_accel_G: r3(median(a.map(fwdAcc)), 3) }));
  // Forward acceleration vs slip, per gear (different gears give different drive force, so never mix them).
  out.accel_vs_slip_per_gear = {};
  const onThr = ok.filter((s) => s.throttle > 0.3 && s.clutch < 0.05 && s.gear >= 1 && s.speed > 3);
  for (let g = 1; g <= 6; g++) {
    const inGear = onThr.filter((s) => s.gear === g), bins = [];
    for (let lo = -0.05; lo < 0.8; lo += 0.025) {
      const inBin = inGear.filter((s) => { const k = kapR(s); return k >= lo && k < lo + 0.025; });
      if (inBin.length >= 15) bins.push({ slip_from: r3(lo, 3), samples: inBin.length, mean_forward_accel_G: r3(mean(inBin.map(fwdAcc)), 3) });
    }
    if (bins.length >= 3) {
      const b = bins.reduce((x, y) => (y.mean_forward_accel_G > x.mean_forward_accel_G ? y : x));
      out.accel_vs_slip_per_gear[g] = { slip_bin_with_highest_mean_accel: r3(b.slip_from + 0.0125, 4), bins };
    }
  }
  const brake = ok.filter((s) => s.brake_f > 0.7 && s.speed > 4);
  out.front_hard_braking = { samples: brake.length, slip_p10_p50_p90: q3(brake.map(kapF)) };
  const mats = {};
  for (const s of S) for (const m of [s.wheel_mat_f, s.wheel_mat_r]) mats[m] = (mats[m] || 0) + 1;
  out.wheel_material_counts = mats;
  return out;
}

// ---------- 6. quick checks ----------
function analyzeExtras(S, bike) {
  const out = {};
  for (const [w, inKey, pKey] of [["front", "brake_f", "brake_press_f"], ["rear", "brake_r", "brake_press_r"]]) {
    const b = bike.brakes[w], predicted = (b.force * b.lever) / (Math.PI * (b.mc / 2) ** 2) / 1000;
    const on = S.filter((s) => s[inKey] > 0.05);
    // Some game builds leave these fields unfilled: leftover memory shows up as absurd floats.
    const weird = S.filter((s) => { const p = s[pKey]; return !Number.isFinite(p) || Math.abs(p) > 1e5 || (p !== 0 && Math.abs(p) < 1e-6); }).length;
    if (weird > 0.01 * S.length || (on.length >= 10 && Math.max(...on.map((s) => s[pKey])) < 0.05 * predicted)) {
      out[`${w}_brake`] = { samples: on.length, field_usable: false, implausible_values: weird,
        note: "pressure does not follow the lever: the game does not fill this field in this build", predicted_full_lever_kPa: r3(predicted, 0) };
      continue;
    }
    const zeroP = S.filter((s) => s[pKey] < 1 && s[inKey] > 0).map((s) => s[inKey]);
    if (on.length < 10) { out[`${w}_brake`] = { samples: on.length, predicted_full_lever_kPa: r3(predicted, 0) }; continue; }
    const k = fitThroughZero(on.map((s) => s[inKey]), on.map((s) => s[pKey]));
    const lf = linfit(on.map((s) => s[inKey]), on.map((s) => s[pKey]));
    out[`${w}_brake`] = { samples: on.length, measured_full_lever_kPa: r3(k, 0), linear_fit: { slope: r3(lf.slope, 1), intercept: r3(lf.intercept, 1), r: r3(lf.r, 5) },
      predicted_full_lever_kPa: r3(predicted, 0), predicted_torque_at_full_Nm: r3(predicted * b.p2t, 0), max_input_with_zero_pressure: r3(zeroP.length ? Math.max(...zeroP) : 0, 4) };
  }
  const rpms = S.filter((s) => !s.crashed).map((s) => s.rpm);
  out.rpm = { max: Math.max(...rpms), p999: r3(pct(rpms, 0.999), 0), cfg_limiter: bike.limiter };
  const idle = S.filter((s) => s.throttle < 0.02 && s.speedometer < 0.5 && (s.gear === 0 || s.clutch > 0.9) && s.rpm > 0);
  out.idle = { samples: idle.length, median_rpm: idle.length ? r3(median(idle.map((s) => s.rpm)), 0) : null, cfg_idle_rpm: bike.idleRPM };
  out.steer = { max_abs_deg: r3(Math.max(...S.map((s) => Math.abs(s.steer))), 2), cfg_lock_deg: bike.steerLock };
  out.clutch_values = { p50: r3(median(S.map((s) => s.clutch)), 3), max: r3(Math.max(...S.map((s) => s.clutch)), 3) };
  out.engine_temp_c = { min: r3(Math.min(...S.map((s) => s.engine_temp)), 1), max: r3(Math.max(...S.map((s) => s.engine_temp)), 1) };
  out.crashes = S.filter((s, i) => s.crashed && !(i > 0 && S[i - 1].crashed)).length;
  return out;
}

// ---------- report ----------
function markdown(file, A) {
  const L = [], j = (o) => (o === undefined ? "n/a" : "`" + JSON.stringify(o, (k, v) => (k === "bins" || k === "curve" ? undefined : v)) + "`");
  L.push(`# Telemetry analysis — ${path.basename(file)}`, "", `Generated by tools/analyze_telemetry.js on ${new Date().toISOString()}.`, "");
  if (A.info && A.info.evnt) L.push(`Bike: ${A.info.evnt.bike_name} (${A.info.evnt.bike_id}), track: ${A.info.evnt.track_name}, setup: ${A.info.sesn ? A.info.sesn.setup_file || "(default)" : "?"}`, "");
  if (A.synthetic) L.push("> **SYNTHETIC TEST DATA** from tools/fake_mxb_sender.js — not a game measurement.", "");
  const R = A.rates;
  L.push("## 1. Telemetry rate", "",
    `- ${R.packets_per_second} packets/s over ${R.riding_seconds} s of riding (${R.recording_seconds} s span); ${R.exact_duplicate_packets} exact duplicates; ${R.rebuilt_time.position_resets} position resets (crash recoveries) cut out.`,
    `- ${R.new_samples_per_game_second} new physics samples per game second; typical step ${R.typical_step_ms} ms; ` +
    `${(100 * R.fraction_steps_multiple_of_10ms).toFixed(1)}% of steps are multiples of 10 ms; ${R.skipped_samples} skipped.`,
    `- Game clock runs at ${R.game_seconds_per_real_second}× real time. Position vs velocity RMS error ${R.position_vs_velocity_rms_error_mps} m/s.`,
    `- Step histogram: ${j(R.game_time_step_histogram_ms)}`, "");
  const C = A.conventions;
  L.push("## 2. Conventions", "", `- World up axis: ${C.world_up_axis}.`, `- Rotation matrix: ${j(C.rotation_matrix)}`,
    `- Accelerometer best match (same point as velocity): ${j(C.accelerometer_best_match)}`,
    `- Accelerometer at rest: ${j(C.accelerometer_at_rest_G)}`,
    `- Velocity reference point: ${j(C.velocity_reference_point)}`,
    `- Accelerometer point: ${j(C.accelerometer_point)}`,
    `- Speedometer RMS difference (m/s): ${j(C.speedometer_rms_difference_mps)}`, "");
  const S = A.suspension;
  L.push("## 3. Suspension", "");
  for (const e of ["front", "rear"]) L.push(`- **${e}**: ${j(S[e])}`);
  L.push(`- Landings found: ${S.landings.length}`);
  for (const l of S.landings.slice(0, 15)) L.push(`  - ${j(l)}`);
  for (const [title, D] of [["Damper fit, all samples", S.damper_fit], ["Damper fit, landings only", S.damper_fit_landings_only]]) {
    if (!D) continue;
    L.push("", `**${title}** (${D.samples} samples, assumed sprung mass ${r3(D.assumed_mass_kg, 1)} kg).` +
      (D.note ? ` ${D.note}` : ` 1-stage ${j(D.one_stage)}, 3-stage ${j(D.three_stage)}, improvement ${D.improvement_three_vs_one_percent}%.`));
    if (D.coefficients) for (const [k, v] of Object.entries(D.coefficients)) L.push(`- ${k}: ${j(v)}`);
    if (D.springs) L.push(`- springs: ${j(D.springs)}`);
    if (D.threshold_scans) for (const [k, v] of Object.entries(D.threshold_scans)) L.push(`- scan ${k}: cfg ${v.cfg}, best ${v.best}, contrast ${v.contrast_percent}%`);
  }
  L.push("", "## 4. Gears (RPM vs rear wheel speed)", "", `Primary ${A.gears.primary}, final drive ${A.gears.final_drive}, rear radius ${A.gears.rear_radius_m} m.`, "",
    "| gear | pair | total ratio | predicted rpm per m/s | measured | error % | implied radius m | samples |", "|---|---|---|---|---|---|---|---|");
  for (const g of A.gears.per_gear) L.push(`| ${g.gear} | ${g.pair} | ${g.total_ratio} | ${g.predicted_rpm_per_mps} | ${g.measured_rpm_per_mps_rear_wheel ?? "-"} | ${g.error_percent ?? "-"} | ${g.implied_wheel_radius_m ?? "-"} | ${g.samples} |`);
  L.push("", `Gear step ratios: ${j(A.gears.gear_step_ratios)}`, "");
  L.push("## 5. Slip", "", ...Object.entries(A.slip).map(([k, v]) => `- ${k}: ${j(v)}`), "");
  L.push("## 6. Quick checks", "", ...Object.entries(A.extras).map(([k, v]) => `- ${k}: ${j(v)}`), "");
  return L.join("\n");
}

function main() {
  const argv = process.argv.slice(2);
  if (!argv[0] || argv[0] === "--help") { console.log("usage: node tools/analyze_telemetry.js <xxx_data.csv> [--cfg bike.cfg] [--mass kg] [--fs N --rs N]"); process.exit(1); }
  const file = argv[0], opt = {};
  for (let i = 1; i < argv.length; i += 2) opt[argv[i].replace(/^--/, "")] = argv[i + 1];
  const bike = opt.cfg ? bikeFromCfg(opt.cfg, BIKE_450XF) : BIKE_450XF;
  const base = file.replace(/_data\.csv$/, "");
  const info = fs.existsSync(base + "_event.json") ? JSON.parse(fs.readFileSync(base + "_event.json", "utf8")) : null;
  const rows = loadCsv(file), S = samplesOf(rows);
  if (S.length < 50) { console.error(`Only ${S.length} running samples in ${file}. Ride for longer (state must be 2 = running).`); process.exit(1); }
  const A = { file: path.basename(file), bike: bike.id, info, synthetic: info && info.evnt && info.evnt.rider_name === "SYNTHETIC" };
  if (info && info.evnt && info.evnt.bike_id && !String(info.evnt.bike_id).toLowerCase().includes(bike.id) && !opt.cfg)
    console.warn(`[warn] recording is for "${info.evnt.bike_id}" but gear/damper checks use ${bike.id} numbers. Pass --cfg <bike>.cfg.`);
  A.rates = analyzeRates(rows, S);
  const conv = analyzeConventions(S);
  A.conventions = conv.res;
  A.suspension = analyzeSuspension(S, conv, bike, info, Number(opt.mass) || bike.mass).res;
  A.gears = analyzeGears(S, conv, bike, Number(opt.fs) || bike.fs, Number(opt.rs) || bike.rs);
  A.slip = analyzeSlip(S, conv);
  A.extras = analyzeExtras(S, bike);
  fs.writeFileSync(base + "_analysis.json", JSON.stringify(A, null, 2));
  const md = markdown(file, A);
  fs.writeFileSync(base + "_analysis.md", md);
  console.log(md);
  console.log(`\nWrote ${base}_analysis.json and ${base}_analysis.md`);
}

main();
