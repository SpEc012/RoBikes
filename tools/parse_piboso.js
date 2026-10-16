// Minimal reader for PiBoSo-style text config files ("key = value", "name { ... }", ";" comments).
// Our own tool: reads the user's extracted game files for analysis only; nothing is redistributed.
"use strict";
const fs = require("fs");

function parse(text) {
  const root = {};
  const stack = [root];
  let pendingName = null;
  for (let raw of text.split(/\r?\n/)) {
    const line = raw.replace(/;.*$/, "").trim();
    if (!line) continue;
    const cur = stack[stack.length - 1];
    if (line === "{") {
      const child = {};
      cur[pendingName] = child;
      stack.push(child);
      pendingName = null;
    } else if (line === "}") {
      stack.pop();
    } else if (line.includes("=")) {
      const i = line.indexOf("=");
      const key = line.slice(0, i).trim();
      const val = line.slice(i + 1).trim();
      const parts = val.split(",").map((s) => s.trim());
      const nums = parts.map(Number);
      const parsed = nums.every((n) => !Number.isNaN(n)) && val !== "" ? (nums.length === 1 ? nums[0] : nums) : val;
      // Some files reuse a block name as a plain key later (e.g. "compound0 { ... }" then "compound0 = Mid Soft");
      // keep the block and store the plain value beside it.
      const existing = cur[key];
      if (existing && typeof existing === "object" && !Array.isArray(existing)) cur[key + "_value"] = parsed;
      else cur[key] = parsed;
    } else {
      pendingName = line;
    }
  }
  return root;
}

function parseFile(path) {
  return parse(fs.readFileSync(path, "latin1"));
}

function curve(block) {
  const pts = [];
  for (let i = 0; i < block.numpoints; i++) pts.push(block["point" + i]);
  return pts;
}

module.exports = { parse, parseFile, curve };

if (require.main === module) {
  console.log(JSON.stringify(parseFile(process.argv[2]), null, 2));
}
