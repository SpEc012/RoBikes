// Local-only file server so Roblox Studio can pull the Robikes source from disk (127.0.0.1 only).
// GET /manifest -> JSON list of { path, size }   GET /file?path=<relative> -> file text
// usage: node serve_src.js <srcDir> [port]
"use strict";
const http = require("http");
const fs = require("fs");
const path = require("path");

const root = path.resolve(process.argv[2]);
const port = Number(process.argv[3] || 34875);

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (/\.luau?$/.test(e.name)) out.push(path.relative(root, p).split(path.sep).join("/"));
  }
  return out;
}

http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  try {
    if (url.pathname === "/manifest") {
      const files = walk(root).map((p) => ({ path: p, size: fs.statSync(path.join(root, p)).size }));
      res.writeHead(200, { "Content-Type": "application/json" });
      return res.end(JSON.stringify(files));
    }
    if (url.pathname === "/file") {
      const rel = url.searchParams.get("path") || "";
      const full = path.resolve(root, rel);
      if (!full.startsWith(root + path.sep)) { res.writeHead(403); return res.end("forbidden"); }
      res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
      return res.end(fs.readFileSync(full, "utf8"));
    }
    res.writeHead(404); res.end("not found");
  } catch (err) {
    res.writeHead(500); res.end(String(err));
  }
}).listen(port, "127.0.0.1", () => console.log(`serving ${root} on http://127.0.0.1:${port}`));
