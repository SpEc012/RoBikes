// For each bike: find the rpm where T = IdleThrottle*Tfull + (1-IdleThrottle)*Tbrake crosses zero,
// and compare with the bike's IdleRPM. Supports the torque-blend inference (REPORT §2).
"use strict";
const path = require("path");
const { parseFile, curve } = require("./parse_piboso");
const root = process.argv[2];
const interp = (pts, x) => {
  if (x <= pts[0][0]) return pts[0][1];
  for (let i = 1; i < pts.length; i++) if (x <= pts[i][0]) {
    const [x0, y0] = pts[i - 1], [x1, y1] = pts[i];
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
  }
  return pts[pts.length - 1][1];
};
for (const b of ["250x", "250xf", "350xf", "450xf", "450sm"]) {
  const cfg = parseFile(path.join(root, b, b + ".cfg"));
  const engn = parseFile(path.join(root, b, b + ".engn"));
  const tq = curve(engn.torque), br = curve(engn.brake);
  const th = cfg.engine.IdleThrottle, idle = cfg.engine.IdleRPM;
  let eq = null, prev = null;
  for (let rpm = 300; rpm <= 8000; rpm += 5) {
    const rps = rpm / 60;
    const T = th * interp(tq, rps) + (1 - th) * interp(br, rps);
    if (prev !== null && prev > 0 && T <= 0) { eq = rpm; break; }
    prev = T;
  }
  console.log(`${b}: IdleThrottle=${th} IdleRPM=${idle} balance=${eq} rpm  diff=${eq === null ? "n/a" : eq - idle}`);
}
