/**
 * server.js — dev server for Godot 4 web exports.
 *
 * Run from the export folder: node server.js
 * Then open http://localhost:8080
 *
 * Requires Cross-Origin headers for SharedArrayBuffer (threads + GDExtensions).
 */

const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = 8080;
const SERVE_DIR = __dirname;
const NGSPICE_SIDE_MODULE_REL_PATH = "ngspice/libngspice.so";

const MIME_TYPES = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".mjs": "application/javascript",
  ".wasm": "application/wasm",
  ".so": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".css": "text/css",
  ".json": "application/json",
  ".sch": "text/plain",
  ".spice": "text/plain",
  ".cir": "text/plain",
  ".net": "text/plain",
};

const server = http.createServer((req, res) => {
  let urlPath = req.url.split("?")[0];
  if (urlPath === "/" || urlPath === "") urlPath = "/index.html";

  const filePath = path.join(SERVE_DIR, urlPath);

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("404 Not Found: " + urlPath);
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    const contentType = MIME_TYPES[ext] || "application/octet-stream";

    res.writeHead(200, {
      "Content-Type": contentType,
      // Required for SharedArrayBuffer (threads, GDExtensions with dlink_enabled).
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
      // Prevent caching during dev so refreshes pick up new builds.
      "Cache-Control": "no-cache, no-store, must-revalidate",
    });
    res.end(data);
  });
});

function checkNgspiceWebSetup() {
  const ngspiceLibPath = path.join(SERVE_DIR, "ngspice", "libngspice.so");
  if (!fs.existsSync(ngspiceLibPath)) {
    console.warn(
      "WARNING: Missing ngspice side module at " + ngspiceLibPath +
      ". Web simulation will fail to initialize until this file is present."
    );
  }

  const indexHtmlPath = path.join(SERVE_DIR, "index.html");
  if (!fs.existsSync(indexHtmlPath)) {
    return;
  }

  let html = "";
  try {
    html = fs.readFileSync(indexHtmlPath, "utf8");
  } catch (err) {
    console.warn("WARNING: Could not read index.html to validate ngspice preload setup:", err.message);
    return;
  }

  const hasNgspicePreload = html.includes(`"${NGSPICE_SIDE_MODULE_REL_PATH}"`) ||
    html.includes(`'${NGSPICE_SIDE_MODULE_REL_PATH}'`);
  if (!hasNgspicePreload) {
    console.warn(
      "WARNING: index.html does not preload " + NGSPICE_SIDE_MODULE_REL_PATH +
      " in GODOT_CONFIG.gdextensionLibs. Browser dlopen will fail with " +
      "'synchronous loading of external files is not available'."
    );
  }
}

server.listen(PORT, () => {
  console.log("Serving from:", SERVE_DIR);
  console.log("Open http://localhost:" + PORT);
  console.log("COOP/COEP headers active (required for threads + GDExtensions)");
  checkNgspiceWebSetup();
});
