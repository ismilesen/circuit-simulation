#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

function usageAndExit() {
  console.error("Usage: node scripts/patch_web_export_config.js <index.html> [side-module-path ...]");
  process.exit(1);
}

const indexHtmlPath = process.argv[2];
const sideModulePaths = process.argv.slice(3);
if (sideModulePaths.length === 0) {
  sideModulePaths.push("libngspice.so");
}

if (!indexHtmlPath) {
  usageAndExit();
}

const resolvedPath = path.resolve(indexHtmlPath);
if (!fs.existsSync(resolvedPath)) {
  console.error("ERROR: index.html not found at:", resolvedPath);
  process.exit(1);
}

let html = fs.readFileSync(resolvedPath, "utf8");
const configRegex = /const GODOT_CONFIG = (\{[\s\S]*?\});/;
const match = html.match(configRegex);

if (!match) {
  console.error("ERROR: Could not find GODOT_CONFIG in:", resolvedPath);
  process.exit(1);
}

let config;
try {
  config = JSON.parse(match[1]);
} catch (err) {
  console.error("ERROR: Failed to parse GODOT_CONFIG JSON:", err.message);
  process.exit(1);
}

if (!Array.isArray(config.gdextensionLibs)) {
  config.gdextensionLibs = [];
}

if (sideModulePaths.some((entry) => path.basename(entry).startsWith("libcircuit_sim.web."))) {
  config.gdextensionLibs = config.gdextensionLibs.filter((entry) => {
    return !path.basename(entry).startsWith("libcircuit_sim.web.");
  });
}

for (const sideModulePath of sideModulePaths) {
  config.gdextensionLibs = config.gdextensionLibs.filter((entry) => {
    return path.basename(entry) !== path.basename(sideModulePath);
  });

  if (!config.gdextensionLibs.includes(sideModulePath)) {
    config.gdextensionLibs.push(sideModulePath);
  }
}

const replacement = `const GODOT_CONFIG = ${JSON.stringify(config)};`;
html = html.replace(configRegex, replacement);

const bridgeScript = '<script src="upload_bridge.js"></script>';
if (!html.includes('src="upload_bridge.js"') && !html.includes("src='upload_bridge.js'")) {
  if (html.includes("</head>")) {
    html = html.replace("</head>", `\t\t${bridgeScript}\n\t</head>`);
  } else {
    html = `${bridgeScript}\n${html}`;
  }
}

fs.writeFileSync(resolvedPath, html);

const exportDir = path.dirname(resolvedPath);
const serviceWorkerPath = path.join(exportDir, "index.service.worker.js");
if (fs.existsSync(serviceWorkerPath)) {
  const hash = crypto.createHash("sha256");
  for (const file of ["index.html", "index.pck", ...sideModulePaths.map((entry) => path.basename(entry))]) {
    const filePath = path.join(exportDir, file);
    if (fs.existsSync(filePath)) {
      hash.update(file);
      hash.update(fs.readFileSync(filePath));
    }
  }

  let worker = fs.readFileSync(serviceWorkerPath, "utf8");
  const cacheVersion = `codex-${hash.digest("hex").slice(0, 16)}`;
  worker = worker.replace(
    /const CACHE_VERSION = ['"][^'"]+['"];/,
    `const CACHE_VERSION = '${cacheVersion}';`
  );
  worker = worker.replace(
    "const crossOriginIsolatedHeaders = new Headers(response.headers);\n",
    "const crossOriginIsolatedHeaders = new Headers(response.headers);\n\tcrossOriginIsolatedHeaders.delete('Content-Encoding');\n\tcrossOriginIsolatedHeaders.delete('Content-Length');\n"
  );
  fs.writeFileSync(serviceWorkerPath, worker);
  console.log("Updated service worker CACHE_VERSION:", cacheVersion);
}

console.log("Updated GODOT_CONFIG.gdextensionLibs in", resolvedPath);
console.log("Ensured side module preload:", sideModulePaths.join(", "));
console.log("Ensured upload bridge script include: upload_bridge.js");
