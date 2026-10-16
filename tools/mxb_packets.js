// Decoder for the UDP packets sent by MX Bikes' official plugin plugins/proxy_udp64.dlo.
// Layout verified with REA (Ghidra decompile of the plugin, see FINDINGS.md "Plugins") and the
// official field list in https://mx-bikes.com/downloads/mxb_example.c (SPluginsBikeData_t etc.).
// All numbers are little-endian. Strings in 'evnt'/'sesn' are NUL-terminated and NOT padded.
"use strict";

// SPluginsBikeData_t, 47 four-byte fields = 188 bytes, in struct order. "i" = int32, "f" = float32.
const DATA_FIELDS = [
  ["rpm", "i"], ["engine_temp", "f"], ["water_temp", "f"], ["gear", "i"], ["fuel", "f"], ["speedometer", "f"],
  ["pos_x", "f"], ["pos_y", "f"], ["pos_z", "f"],
  ["vel_x", "f"], ["vel_y", "f"], ["vel_z", "f"],
  ["acc_x", "f"], ["acc_y", "f"], ["acc_z", "f"],
  ["rot00", "f"], ["rot01", "f"], ["rot02", "f"],
  ["rot10", "f"], ["rot11", "f"], ["rot12", "f"],
  ["rot20", "f"], ["rot21", "f"], ["rot22", "f"],
  ["yaw", "f"], ["pitch", "f"], ["roll", "f"],
  ["yaw_vel", "f"], ["pitch_vel", "f"], ["roll_vel", "f"],
  ["susp_len_f", "f"], ["susp_len_r", "f"],
  ["susp_vel_f", "f"], ["susp_vel_r", "f"],
  ["crashed", "i"],
  ["steer", "f"], ["throttle", "f"], ["brake_f", "f"], ["brake_r", "f"], ["clutch", "f"],
  ["wheel_speed_f", "f"], ["wheel_speed_r", "f"],
  ["wheel_mat_f", "i"], ["wheel_mat_r", "i"],
  ["brake_press_f", "f"], ["brake_press_r", "f"],
  ["steer_torque", "f"],
];
const BIKE_DATA_SIZE = DATA_FIELDS.length * 4; // 188
const DATA_PACKET_SIZE = 5 + 4 + 4 + BIKE_DATA_SIZE; // 201
const STATE_NAMES = { 0: "no bike on track", 1: "paused", 2: "running" };

class Reader {
  constructor(buf, off) { this.buf = buf; this.off = off; }
  left() { return this.buf.length - this.off; }
  i32() { const v = this.buf.readInt32LE(this.off); this.off += 4; return v; }
  f32() { const v = this.buf.readFloatLE(this.off); this.off += 4; return v; }
  str() {
    const end = this.buf.indexOf(0, this.off);
    if (end < 0) throw new Error("unterminated string");
    const s = this.buf.toString("latin1", this.off, end);
    this.off = end + 1;
    return s;
  }
}

function tagOf(buf) {
  if (buf.length < 5 || buf[4] !== 0) return null;
  return buf.toString("latin1", 0, 4);
}

// Returns { type, ...fields } or { type: "unknown" | "bad", reason }.
function decode(buf) {
  const tag = tagOf(buf);
  try {
    const r = new Reader(buf, 5);
    switch (tag) {
      case "data": {
        const state = r.i32();
        if (buf.length === 9) return { type: "data", state, hasBike: false };
        if (buf.length !== DATA_PACKET_SIZE) return { type: "bad", reason: `data packet is ${buf.length} bytes, expected 9 or ${DATA_PACKET_SIZE}` };
        const time_ms = r.i32();
        const d = { type: "data", state, hasBike: true, time_ms };
        for (const [name, t] of DATA_FIELDS) d[name] = t === "i" ? r.i32() : r.f32();
        return d;
      }
      case "evnt": {
        const e = { type: "evnt" };
        e.rider_name = r.str(); e.bike_id = r.str(); e.bike_name = r.str();
        e.num_gears = r.i32(); e.max_rpm = r.i32(); e.limiter = r.i32(); e.shift_rpm = r.i32();
        e.engine_opt_temp = r.f32(); e.temp_alarm_low = r.f32(); e.temp_alarm_high = r.f32();
        e.max_fuel = r.f32(); e.susp_max_travel_f = r.f32(); e.susp_max_travel_r = r.f32(); e.steer_lock = r.f32();
        e.category = r.str(); e.track_id = r.str(); e.track_name = r.str();
        e.track_length = r.f32(); e.event_type = r.i32(); // 1 testing, 2 race, 4 straight rhythm
        return e;
      }
      case "sesn": {
        return { type: "sesn", session: r.i32(), conditions: r.i32(), air_temp: r.f32(), setup_file: r.str() };
      }
      case "lap ": {
        return { type: "lap", lap_num: r.i32(), invalid: r.i32(), lap_time_ms: r.i32(), best: r.i32() };
      }
      case "splt": {
        return { type: "splt", last_was_split: r.i32(), split: r.i32(), split_time_ms: r.i32(), best_diff_ms: r.i32() };
      }
      default:
        return { type: "unknown", reason: `tag ${JSON.stringify(buf.toString("latin1", 0, 4))}, ${buf.length} bytes` };
    }
  } catch (err) {
    return { type: "bad", reason: `${tag}: ${err.message} (${buf.length} bytes)` };
  }
}

// --- Encoders: used only by the fake sender (tests). They mirror what the plugin sends. ---
function cstr(s) { return Buffer.concat([Buffer.from(s, "latin1"), Buffer.from([0])]); }
function tagBuf(tag) { return cstr(tag); }
function i32(v) { const b = Buffer.alloc(4); b.writeInt32LE(v | 0); return b; }
function f32(v) { const b = Buffer.alloc(4); b.writeFloatLE(v); return b; }

function encodeData(state, timeMs, d) {
  if (!d) return Buffer.concat([tagBuf("data"), i32(state)]);
  return Buffer.concat([tagBuf("data"), i32(state), i32(timeMs),
    ...DATA_FIELDS.map(([name, t]) => (t === "i" ? i32(d[name] || 0) : f32(d[name] || 0)))]);
}
function encodeEvent(e) {
  return Buffer.concat([tagBuf("evnt"), cstr(e.rider_name), cstr(e.bike_id), cstr(e.bike_name),
    i32(e.num_gears), i32(e.max_rpm), i32(e.limiter), i32(e.shift_rpm),
    f32(e.engine_opt_temp), f32(e.temp_alarm_low), f32(e.temp_alarm_high), f32(e.max_fuel),
    f32(e.susp_max_travel_f), f32(e.susp_max_travel_r), f32(e.steer_lock),
    cstr(e.category), cstr(e.track_id), cstr(e.track_name), f32(e.track_length), i32(e.event_type)]);
}
function encodeSession(s) {
  return Buffer.concat([tagBuf("sesn"), i32(s.session), i32(s.conditions), f32(s.air_temp), cstr(s.setup_file)]);
}
function encodeLap(l) { return Buffer.concat([tagBuf("lap "), i32(l.lap_num), i32(l.invalid), i32(l.lap_time_ms), i32(l.best)]); }
function encodeSplit(s) { return Buffer.concat([tagBuf("splt"), i32(s.last_was_split), i32(s.split), i32(s.split_time_ms), i32(s.best_diff_ms)]); }

module.exports = {
  DATA_FIELDS, BIKE_DATA_SIZE, DATA_PACKET_SIZE, STATE_NAMES, decode,
  encodeData, encodeEvent, encodeSession, encodeLap, encodeSplit,
};
