#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function usageAndExit() {
  console.error("Usage: node scripts/patch_web_export_config.js <index.html> [side-module-path]");
  process.exit(1);
}

const indexHtmlPath = process.argv[2];
const sideModulePath = process.argv[3] || "libngspice.so";

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

config.gdextensionLibs = config.gdextensionLibs.filter((entry) => {
  return path.basename(entry) !== path.basename(sideModulePath);
});

if (!config.gdextensionLibs.includes(sideModulePath)) {
  config.gdextensionLibs.push(sideModulePath);
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

console.log("Updated GODOT_CONFIG.gdextensionLibs in", resolvedPath);
console.log("Ensured side module preload:", sideModulePath);
console.log("Ensured upload bridge script include: upload_bridge.js");
