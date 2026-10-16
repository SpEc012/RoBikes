// MX Bikes telemetry recorder. Listens for the UDP packets sent by the game's OFFICIAL plugin
// plugins/proxy_udp64.dlo (enable it in proxy_udp.ini, see tools/README.md) and writes:
//   <base>_data.csv    one row per 'data' packet (100 per second while riding)
//   <base>_laps.csv    lap and split times (only when they change)
//   <base>_event.json  bike/track/session info from 'evnt' and 'sesn' packets (needs info = 1)
//   <base>_raw.bin     every packet exactly as received, so it can be decoded again later
//
// Usage:
//   node tools/record_telemetry.js [--name 450f_test] [--duration 150] [--port 30001] [--host 127.0.0.1] [--out recordings]
//   node tools/record_telemetry.js --from-raw recordings/xxx_raw.bin     (re-decode a raw file to CSV)
// Stop recording with Ctrl+C (or let --duration seconds run out).
"use strict";
const dgram = require("dgram");
const fs = require("fs");
const path = require("path");
const { DATA_FIELDS, STATE_NAMES, decode } = require("./mxb_packets");

const RAW_MAGIC = Buffer.from("MXBRAW1\n", "latin1");

function parseArgs(argv) {
  const a = { host: "127.0.0.1", port: 30001, out: path.join(__dirname, "..", "recordings"), name: "", fromRaw: null, duration: 0 };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i], v = argv[i + 1];
    if (k === "--host") { a.host = v; i++; }
    else if (k === "--port") { a.port = Number(v); i++; }
    else if (k === "--out") { a.out = v; i++; }
    else if (k === "--name") { a.name = v.replace(/[^\w.-]+/g, "_"); i++; }
    else if (k === "--from-raw") { a.fromRaw = v; i++; }
    else if (k === "--duration") { a.duration = Number(v); i++; }
    else if (k === "--help" || k === "-h") { console.log(fs.readFileSync(__filename, "utf8").split("\n").slice(0, 12).join("\n")); process.exit(0); }
    else throw new Error(`unknown option ${k}`);
  }
  return a;
}

function stamp() {
  const d = new Date(), p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

// float32 has ~7 significant digits; printing more only makes the file bigger.
function num(v) { return Number.isInteger(v) ? String(v) : String(Number(v.toPrecision(7))); }

class Writer {
  constructor(base, writeRaw) {
    this.base = base;
    this.data = fs.createWriteStream(base + "_data.csv");
    this.data.write(["recv_ms", "dup", "state", "time_ms", ...DATA_FIELDS.map((f) => f[0])].join(",") + "\n");
    this.laps = fs.createWriteStream(base + "_laps.csv");
    this.laps.write("recv_ms,kind,lap_num,invalid,lap_time_ms,best,last_was_split,split,split_time_ms,best_diff_ms\n");
    this.raw = writeRaw ? fs.createWriteStream(base + "_raw.bin") : null;
    if (this.raw) this.raw.write(RAW_MAGIC);
    this.info = { evnt: null, sesn: null };
    this.lastData = null; this.lastLap = ""; this.lastSplit = "";
    this.counts = { data: 0, dataRows: 0, noBike: 0, dup: 0, evnt: 0, sesn: 0, lap: 0, splt: 0, bad: 0, unknown: 0 };
    this.latest = null; this.warned = new Set();
  }

  packet(buf, recvMs) {
    if (this.raw) {
      const h = Buffer.alloc(10);
      h.writeDoubleLE(recvMs, 0); h.writeUInt16LE(buf.length, 8);
      this.raw.write(Buffer.concat([h, buf]));
    }
    const p = decode(buf);
    const t = num(Math.round(recvMs * 1000) / 1000);
    switch (p.type) {
      case "data": {
        this.counts.data++;
        if (!p.hasBike) { this.counts.noBike++; this.latest = p; return; }
        const dup = this.lastData && this.lastData.equals(buf) ? 1 : 0;
        this.lastData = buf; this.counts.dup += dup; this.counts.dataRows++; this.latest = p;
        this.data.write([t, dup, p.state, p.time_ms, ...DATA_FIELDS.map(([n]) => num(p[n]))].join(",") + "\n");
        return;
      }
      case "lap": {
        this.counts.lap++;
        const key = [p.lap_num, p.invalid, p.lap_time_ms, p.best].join(",");
        if (key !== this.lastLap) { this.lastLap = key; if (p.lap_time_ms) this.laps.write(`${t},lap,${key},,,,\n`); }
        return;
      }
      case "splt": {
        this.counts.splt++;
        const key = [p.last_was_split, p.split, p.split_time_ms, p.best_diff_ms].join(",");
        if (key !== this.lastSplit) { this.lastSplit = key; if (p.split_time_ms) this.laps.write(`${t},split,,,,,${key}\n`); }
        return;
      }
      case "evnt": case "sesn": {
        this.counts[p.type]++;
        const { type, ...fields } = p;
        if (JSON.stringify(this.info[type]) !== JSON.stringify(fields)) {
          this.info[type] = fields;
          fs.writeFileSync(this.base + "_event.json", JSON.stringify(this.info, null, 2));
        }
        return;
      }
      default: {
        this.counts[p.type]++;
        if (!this.warned.has(p.reason)) { this.warned.add(p.reason); console.warn(`\n[warn] ${p.type} packet: ${p.reason}`); }
      }
    }
  }

  close(cb) {
    let n = this.raw ? 3 : 2;
    const done = () => { if (--n === 0) cb(); };
    this.data.end(done); this.laps.end(done); if (this.raw) this.raw.end(done);
  }
}

function fromRaw(file, outDir) {
  const buf = fs.readFileSync(file);
  if (!buf.subarray(0, RAW_MAGIC.length).equals(RAW_MAGIC)) throw new Error("not a recorder _raw.bin file");
  const base = path.join(outDir, path.basename(file).replace(/_raw\.bin$/, "") + "_redecoded");
  const w = new Writer(base, false);
  let off = RAW_MAGIC.length;
  while (off + 10 <= buf.length) {
    const recvMs = buf.readDoubleLE(off), len = buf.readUInt16LE(off + 8);
    w.packet(buf.subarray(off + 10, off + 10 + len), recvMs);
    off += 10 + len;
  }
  w.close(() => console.log(`Re-decoded ${w.counts.data} data packets -> ${base}_data.csv`));
}

function live(args) {
  fs.mkdirSync(args.out, { recursive: true });
  const base = path.join(args.out, `mxb_${stamp()}${args.name ? "_" + args.name : ""}`);
  const w = new Writer(base, true);
  const t0 = process.hrtime.bigint();
  const sock = dgram.createSocket("udp4");
  let lastCount = 0, lastTime = -1, distinct = 0;

  sock.on("message", (msg) => {
    const recvMs = Number(process.hrtime.bigint() - t0) / 1e6;
    w.packet(msg, recvMs);
    if (w.latest && w.latest.hasBike && w.latest.time_ms !== lastTime) { lastTime = w.latest.time_ms; distinct++; }
  });
  sock.on("error", (err) => {
    console.error(`UDP error: ${err.message}`);
    if (err.code === "EADDRINUSE") console.error(`Port ${args.port} is busy. Is another recorder (or telemetry app) already running?`);
    process.exit(1);
  });
  sock.bind(args.port, args.host, () => {
    console.log(`Listening on ${args.host}:${args.port}. Writing ${base}_*.csv`);
    console.log("Waiting for MX Bikes... (Ctrl+C to stop)");
  });

  const timer = setInterval(() => {
    const c = w.counts, rate = c.data - lastCount; lastCount = c.data;
    const p = w.latest;
    let line;
    if (!p) line = "no packets yet - is the plugin enabled and the game running?";
    else if (!p.hasBike) line = `${rate} pkt/s | state 0 (${STATE_NAMES[0]})`;
    else line = `${rate} pkt/s, ${distinct} new samples/s | ${STATE_NAMES[p.state] || p.state} | t=${(p.time_ms / 1000).toFixed(1)} s` +
      ` | gear ${p.gear} | ${p.rpm} rpm | ${(p.speedometer * 3.6).toFixed(0)} km/h | rows ${c.dataRows}`;
    distinct = 0;
    process.stdout.write("\r" + line.padEnd(110));
  }, 1000);

  const stop = () => {
    clearInterval(timer);
    sock.close();
    w.close(() => {
      const c = w.counts;
      console.log(`\n\nStopped. ${c.dataRows} data rows (${c.dup} exact duplicates), ${c.noBike} 'no bike' packets,` +
        ` ${c.evnt} evnt, ${c.sesn} sesn, ${c.lap} lap, ${c.splt} splt, ${c.bad + c.unknown} bad/unknown.`);
      if (!c.evnt) console.log("No 'evnt'/'sesn' packets: add  info = 1  to proxy_udp.ini to get bike/track/session info.");
      console.log(`Files: ${base}_data.csv, _laps.csv, _raw.bin${c.evnt || c.sesn ? ", _event.json" : ""}`);
      console.log(`Analyze with:  node tools/analyze_telemetry.js "${base}_data.csv"`);
      process.exit(0);
    });
  };
  process.on("SIGINT", stop);
  if (args.duration > 0) setTimeout(stop, args.duration * 1000);
}

const args = parseArgs(process.argv.slice(2));
if (args.fromRaw) fromRaw(args.fromRaw, path.dirname(args.fromRaw));
else live(args);
