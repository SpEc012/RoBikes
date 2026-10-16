// Tests which unit the .engn torque-curve x axis uses, by comparing computed peak power
// against the max_power value each bike's .ini declares.
"use strict";
const path = require("path");
const { parseFile, curve } = require("./parse_piboso");

const root = process.argv[2]; // .../bikes
const bikes = ["250x", "250xf", "350xf", "450xf", "450sm"];
const candidates = {
  "rev/s (x*60 = rpm)": (x) => x * 2 * Math.PI,
  "rad/s": (x) => x,
  "rpm/100": (x) => (x * 100 * 2 * Math.PI) / 60,
};

for (const b of bikes) {
  const dir = path.join(root, b);
  const engn = parseFile(path.join(dir, b + ".engn"));
  const cfg = parseFile(path.join(dir, b + ".cfg"));
  const iniText = require("fs").readFileSync(path.join(dir, b + ".ini"), "latin1");
  const maxPower = Number((iniText.match(/max_power\s*=\s*([\d.]+)/) || [])[1]);
  const tq = curve(engn.torque);
  const br = curve(engn.brake);
  const row = { bike: b, ini_max_power: maxPower, limiter: cfg.engine.Limiter0, breakingRPM: cfg.engine.BreakingRPM,
    curve_last_x: tq[tq.length - 1][0], brake_last_x: br[br.length - 1][0] };
  for (const [name, toRad] of Object.entries(candidates)) {
    let best = 0, bestX = 0;
    for (const [x, t] of tq) { const p = t * toRad(x); if (p > best) { best = p; bestX = x; } }
    row[name] = `${(best / 1000).toFixed(1)} kW @ x=${bestX}`;
  }
  console.log(JSON.stringify(row));
}
