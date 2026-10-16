// TEST ONLY: pretends to be MX Bikes + proxy_udp64.dlo so the recorder and analyzer can be checked without
// the game. It runs a tiny made-up bike model (NOT MX Bikes physics) with known values (450xf gearing, a
// 3-stage damper using the 450xf click tables, 4209 kPa rear brake...) and sends packets with the exact
// byte layout of the real plugin. The event packet says rider "SYNTHETIC" so reports are labeled.
//
// Usage: node tools/fake_mxb_sender.js [--seconds 120] [--fast] [--port 30001]
//   default: real time, like the plugin (one packet per 10 ms of wall-clock time)
//   --fast : sends every 10 ms game sample as fast as possible (for quick analyzer tests)
"use strict";
const dgram = require("dgram");
const P = require("./mxb_packets");

const args = { seconds: 120, fast: false, port: 30001 };
for (let i = 2; i < process.argv.length; i++) {
  const k = process.argv[i];
  if (k === "--fast") args.fast = true;
  else if (k === "--seconds") args.seconds = Number(process.argv[++i]);
  else if (k === "--port") args.port = Number(process.argv[++i]);
}

// ----- made-up bike model -----
// m = sprung mass (chassis + rider, rigid here), mwf/mwr = wheel masses hanging on tyre springs.
const G = 9.81, m = 153.5, Ip = 40, a = 0.75, b = 0.70, MR = 2.6, rR = 0.325, Ie = 0.008, Iw = 1.2, mu = 1.1;
const mwf = 13.5, mwr = 19, kT = 105000, cT = 205, kTop = 2e5;
const primary = 76 / 32, gears = [32 / 16, 30 / 18, 28 / 20, 26 / 22], final = 50 / 14;
const LF0 = 0.60, LR0 = 0.45, HR0 = 0.61; // fork length, shock length, rear wheel hang below chassis
const damp = (u, t0, t1, c) => { const s = Math.sign(u), x = Math.abs(u); return s * (c[0] * Math.min(x, t0) + c[1] * Math.min(Math.max(x - t0, 0), t1 - t0) + c[2] * Math.max(x - t1, 0)); };
const dampF = (u) => (u >= 0 ? damp(u, 0.05, 1.1, [2360, 370, 1500]) : damp(u, 0.05, 1.1, [1500, 495, 1500]));
const dampR = (u) => (u >= 0 ? damp(u, 0.05, 0.4, [9000, 1800, 12000]) : damp(u, 0.05, 0.4, [6000, 4500, 12000]));
const torque = (rpm) => (rpm > 11600 ? 0 : Math.max(10, 45 * (1 - ((rpm - 8000) / 9000) ** 2)));
const ground = (s) => (s > 150 && s < 260 ? 0.05 * Math.sin((2 * Math.PI * s) / 3.5) : 0);
const groundSlope = (s) => (s > 150 && s < 260 ? 0.05 * ((2 * Math.PI) / 3.5) * Math.cos((2 * Math.PI * s) / 3.5) : 0);

const st = { t: 0, s: 0, px: 0, pz: 0, psi: 0, v: 3, w: 3 / rR, y: 0.87, yd: 0, th: 0, thd: 0, gear: 1, shift: 0, kicked: -1,
  zf: 0.335, zfd: 0, zr: 0.325, zrd: 0, df: 0, dfd: 0, dr: 0, drd: 0, Ff: 0, Frw: 0, accHist: [] };

function controls(t) {
  const c = t % 15, cyc = Math.floor(t / 15);
  let thr = 0, bf = 0, br = 0, turn = 0;
  if (c < 7) thr = 1; else if (c < 10) { thr = 0.25; turn = 0.12 * (cyc % 2 ? 1 : -1); }
  else if (c < 12.5) { bf = Math.min(1, (c - 10) * 2) * 0.9; br = 0.5; } else thr = 0.5;
  const kick = (c > 4 && c < 4.01) || (c > 8.5 && c < 8.51) ? 3 + (cyc % 4) * 1.0 : 0;
  return { thr, bf, br, turn, kick, cyc };
}

function step(dt) {
  const c = controls(st.t);
  // vertical: chassis (heave + pitch) on a fork and a linkage shock, each carrying a wheel mass on a tyre spring
  const yF = st.y + a * st.th, yR = st.y - b * st.th, ydF = st.yd + a * st.thd, ydR = st.yd - b * st.thd;
  const df = st.zf - (yF - LF0), dfd = st.zfd - ydF; // fork compression and its speed
  const drw = st.zr - (yR - HR0), drwd = st.zrd - ydR; // rear wheel travel; the shock moves 1/MR of it
  st.df = df; st.dfd = dfd; st.dr = drw / MR; st.drd = drwd / MR;
  const sF = df > 0 ? 70 + 10000 * df + 1.5e5 * df * df : kTop * df; // spring + preload, top-out spring below 0
  const sR = st.dr > 0 ? 648 + 54000 * st.dr : kTop * st.dr;
  st.Fs = sF + dampF(st.dfd); // force on the chassis from the fork (up = +)
  st.Fsr = (sR + dampR(st.drd)) / MR; // vertical force at the rear axle from the shock
  const penF = ground(st.s + a) + 0.335 - st.zf, penR = ground(st.s - b) + rR - st.zr;
  st.Ff = penF > 0 ? Math.max(0, kT * penF + cT * (groundSlope(st.s + a) * st.v - st.zfd)) : 0; // tyre loads
  st.Frw = penR > 0 ? Math.max(0, kT * penR + cT * (groundSlope(st.s - b) * st.v - st.zrd)) : 0;
  st.zfd += ((st.Ff - st.Fs) / mwf - G) * dt; st.zf += st.zfd * dt;
  st.zrd += ((st.Frw - st.Fsr) / mwr - G) * dt; st.zr += st.zrd * dt;
  const ydd = (st.Fs + st.Fsr) / m - G, thdd = (a * st.Fs - b * st.Fsr) / Ip;
  // longitudinal: engine locked to rear wheel, simple Magic-Formula-like rear tyre
  const R = primary * gears[st.gear - 1] * final;
  const rpm = (st.w * R * 60) / (2 * Math.PI);
  if (st.shift > 0) st.shift -= dt;
  if (rpm > 9700 && st.gear < 4 && st.shift <= 0) { st.gear++; st.shift = 0.04; }
  if (rpm < 4000 && st.gear > 1 && c.thr < 0.3) st.gear--;
  const Te = st.shift > 0 ? 0 : torque(rpm) * c.thr - (1 - c.thr) * 4;
  const kappa = (st.w * rR - st.v) / Math.max(st.v, 3);
  const Fx = mu * st.Frw * Math.sin(1.65 * Math.atan(8 * kappa));
  const Pr = c.br * 4209, Tbr = Pr * 0.132 * Math.sign(st.w);
  const IEff = Iw + Ie * R * R;
  const Ffb = st.Ff > 0 ? -mu * st.Ff * c.bf * 0.8 : 0;
  const drag = 0.5 * 1.2 * 0.6 * st.v * st.v;
  st.w = Math.max(0, st.w + ((Te * R * 0.92 - Fx * rR - Tbr) / IEff) * dt);
  const vdot = (Fx + Ffb - drag) / m;
  const vPrev = [st.v * Math.sin(st.psi), st.yd, st.v * Math.cos(st.psi)];
  st.v = Math.max(0.5, st.v + vdot * dt);
  st.psi += c.turn * dt * Math.min(1, st.v / 10);
  if (c.kick && st.kicked !== Math.floor(st.t * 10) && st.Ff > 0 && st.Frw > 0) { st.yd += c.kick; st.zfd += c.kick; st.zrd += c.kick; st.kicked = Math.floor(st.t * 10); }
  st.yd += ydd * dt; st.y += st.yd * dt; st.thd += thdd * dt; st.th += st.thd * dt;
  st.px += st.v * Math.sin(st.psi) * dt; st.pz += st.v * Math.cos(st.psi) * dt; st.s += st.v * dt;
  st.t += dt;
  const vNow = [st.v * Math.sin(st.psi), st.yd, st.v * Math.cos(st.psi)];
  st.accHist.push(vNow.map((x, k) => x - vPrev[k]));
  if (st.accHist.length > 10) st.accHist.shift();
  st.c = c; st.rpm = rpm; st.kappa = kappa;
}

function snapshot() {
  const c = st.c, ps = st.psi, th = st.th;
  const f = [Math.sin(ps) * Math.cos(th), Math.sin(th), Math.cos(ps) * Math.cos(th)];
  const x = [Math.cos(ps), 0, -Math.sin(ps)];
  const u = [f[1] * x[2] - f[2] * x[1], f[2] * x[0] - f[0] * x[2], f[0] * x[1] - f[1] * x[0]];
  const aw = [0, 1, 2].map((k) => st.accHist.reduce((s, d) => s + d[k], 0) / (st.accHist.length * 0.001)); // last 10 ms average
  const d3 = (p, q) => p[0] * q[0] + p[1] * q[1] + p[2] * q[2];
  const vel = [st.v * Math.sin(ps), st.yd, st.v * Math.cos(ps)];
  return {
    rpm: Math.round(st.rpm), engine_temp: 60, water_temp: 58, gear: st.gear, fuel: 7, speedometer: st.v,
    pos_x: st.px, pos_y: st.y, pos_z: st.pz, vel_x: vel[0], vel_y: vel[1], vel_z: vel[2],
    acc_x: d3(x, aw) / G, acc_y: d3(u, aw) / G, acc_z: d3(f, aw) / G,
    rot00: x[0], rot01: x[1], rot02: x[2], rot10: u[0], rot11: u[1], rot12: u[2], rot20: f[0], rot21: f[1], rot22: f[2],
    yaw: (ps * 180) / Math.PI, pitch: (th * 180) / Math.PI, roll: 0, yaw_vel: c.turn * 57.3, pitch_vel: st.thd * 57.3, roll_vel: 0,
    susp_len_f: LF0 - st.df, susp_len_r: LR0 - st.dr, susp_vel_f: -st.dfd, susp_vel_r: -st.drd,
    crashed: 0, steer: c.turn * 20, throttle: c.thr, brake_f: c.bf, brake_r: c.br, clutch: 0,
    wheel_speed_f: st.v * (1 - 0.05 * c.bf), wheel_speed_r: st.w * rR, wheel_mat_f: st.Ff > 0 ? 3 : 0, wheel_mat_r: st.Frw > 0 ? 3 : 0,
    brake_press_f: c.bf * 2515, brake_press_r: c.br * 4209, steer_torque: 0,
  };
}

const event = { rider_name: "SYNTHETIC", bike_id: "450xf", bike_name: "Synthetic test bike", num_gears: 4, max_rpm: 11600, limiter: 11600,
  shift_rpm: 9700, engine_opt_temp: 60, temp_alarm_low: 52, temp_alarm_high: 72, max_fuel: 7.5, susp_max_travel_f: 0.3,
  susp_max_travel_r: 0.12, steer_lock: 42, category: "Test", track_id: "synthetic", track_name: "Synthetic flat", track_length: 1000, event_type: 1 };
const session = { session: 1, conditions: 0, air_temp: 20, setup_file: "" };

const sock = dgram.createSocket("udp4");
const send = (buf) => new Promise((res) => sock.send(buf, args.port, "127.0.0.1", res));
const gameMs = () => Math.trunc(Math.fround(st.t) * 1000); // plugin sends (int)(fTime * 1000) with float fTime
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function run() {
  console.log(`Fake MX Bikes plugin -> 127.0.0.1:${args.port}, ${args.seconds} s of game time, ${args.fast ? "fast" : "real-time"} mode`);
  for (let i = 0; i < 20; i++) { await send(P.encodeData(0)); await sleep(args.fast ? 1 : 10); } // "no bike on track"
  await send(P.encodeEvent(event)); await send(P.encodeSession(session));
  let lap = { lap_num: 0, invalid: 0, lap_time_ms: 0, best: 0 }, split = { last_was_split: 0, split: 0, split_time_ms: 0, best_diff_ms: 0 };
  const total = Math.round(args.seconds * 100);
  const start = Date.now();
  let snap = null, sent = 0, k = 0;
  // One "RunTelemetry" call: 10 ms of game time (1 ms internal steps), plus the info thread's packets.
  const advance = async () => {
    for (let i = 0; i < 10; i++) step(0.001);
    snap = { ms: gameMs(), d: snapshot() };
    if (k === 3000) split = { last_was_split: 1, split: 0, split_time_ms: 30000, best_diff_ms: 0 };
    if (k === 6000) { lap = { lap_num: 0, invalid: 0, lap_time_ms: 60000, best: 1 }; split = { ...split, last_was_split: 0 }; }
    if (k % 20 === 0) { await send(P.encodeLap(lap)); await send(P.encodeSplit(split)); }
    if (k % 100 === 0) { await send(P.encodeEvent(event)); await send(P.encodeSession(session)); }
    k++;
  };
  if (args.fast) {
    while (k < total) { await advance(); await send(P.encodeData(2, snap.ms, snap.d)); sent++; if (k % 20 === 0) await sleep(1); }
  } else {
    // Like the plugin: the game clock and the 10 ms sender timer run independently, so a late timer
    // skips a sample and an early one repeats it.
    for (let n = 1; k < total; n++) {
      const due = start + n * 10;
      while (Date.now() < due) await sleep(Math.max(0, due - Date.now()));
      const target = Math.min(total, Math.floor((Date.now() - start) / 10));
      while (k < target) await advance();
      if (snap) { await send(P.encodeData(2, snap.ms, snap.d)); sent++; }
    }
  }
  for (let i = 0; i < 20; i++) { await send(P.encodeData(1, snap.ms, snap.d)); await sleep(args.fast ? 1 : 10); } // paused
  console.log(`Done: ${sent} running packets sent in ${((Date.now() - start) / 1000).toFixed(1)} s.`);
  sock.close();
}
run();
