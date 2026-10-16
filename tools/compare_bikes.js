// Prints a side-by-side table of key physics values for every bike (analysis aid).
"use strict";
const path = require("path");
const { parseFile } = require("./parse_piboso");

const root = process.argv[2];
const bikes = ["250x", "250xf", "350xf", "450xf", "450sm"];
const get = (o, p) => p.split(".").reduce((a, k) => (a == null ? a : a[k]), o);
const fields = [
  "engine.Inertia", "engine.IdleRPM", "engine.Limiter0", "engine.MaxRPM", "engine.Ratio0", "engine.Clutch.MaxTorque",
  "gearbox.NumGears", "gearbox.gearing.ratio0", "gearbox.gearing.ratio1", "gearbox.gearing.ratio2", "gearbox.gearing.ratio3", "gearbox.gearing.ratio4",
  "driveline.Efficiency", "driveline.FSprocket.gear3", "driveline.RSprocket.gear6",
  "chassis.Mass", "chassis.Inertia", "steer.Mass", "steer.Lock", "steer.spg0", "steer.spg1", "steer.sdg0", "steer.sdg1",
  "front_suspension.Spring.range", "front_suspension.Spring.setting", "rear_suspension.Spring.range", "rear_suspension.Spring.setting",
  "front_suspension.Mass", "rear_suspension.Mass", "aero.Cx", "aero.MinCdA", "wheel0.Brake.RiderMaxForce", "wheel1.Brake.RiderMaxForce",
  "geom.rakeangle_min", "geom.chassis_mass", "geom.fwheel", "geom.rwheel_min", "geom.rsusp_type", "geom.rider_mass",
];
const rows = {};
for (const b of bikes) {
  const cfg = parseFile(path.join(root, b, b + ".cfg"));
  cfg.geom = parseFile(path.join(root, b, b + ".geom"));
  for (const f of fields) (rows[f] ||= []).push(JSON.stringify(get(cfg, f) ?? "-"));
}
console.log(["field", ...bikes].join(" | "));
for (const [f, vals] of Object.entries(rows)) console.log([f, ...vals].join(" | "));
