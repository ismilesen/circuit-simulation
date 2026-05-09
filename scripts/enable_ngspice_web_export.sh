#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORT_DIR="${1:-$ROOT_DIR/project/build/web/release}"
NGSPICE_ZIP="${2:-$ROOT_DIR/libngspice-44.2.zip}"
INDEX_HTML="$EXPORT_DIR/index.html"
NGSPICE_DIR="$EXPORT_DIR/ngspice"
NGSPICE_LIB="$NGSPICE_DIR/libngspice.so"
NGSPICE_ROOT_LIB="$EXPORT_DIR/libngspice.so"
NGSPICE_PRELOAD_PATH="libngspice.so"

if [ ! -f "$INDEX_HTML" ]; then
  echo "ERROR: Export HTML not found: $INDEX_HTML" >&2
  echo "Run the Godot web export first, then rerun this script." >&2
  exit 1
fi

if [ ! -f "$NGSPICE_ZIP" ]; then
  echo "ERROR: ngspice package not found: $NGSPICE_ZIP" >&2
  exit 1
fi

find "$EXPORT_DIR" -maxdepth 1 -type f -name 'libcircuit_sim.web.*.nothreads.wasm' -delete

if command -v zipinfo >/dev/null 2>&1; then
  ZIP_ENTRIES="$(zipinfo -1 "$NGSPICE_ZIP")"
else
  ZIP_ENTRIES="$(unzip -l "$NGSPICE_ZIP" | awk 'NR > 3 && $0 !~ /^--------/ { print $4 }')"
fi

if ! printf "%s\n" "$ZIP_ENTRIES" | grep -Eq "(^|/)libngspice\\.so$"; then
  echo "ERROR: $NGSPICE_ZIP does not contain libngspice.so" >&2
  echo "Archive entries:" >&2
  printf "%s\n" "$ZIP_ENTRIES" | sed -n '1,80p' >&2
  exit 1
fi

tmp_unpack="$(mktemp -d "${TMPDIR:-/tmp}/ngspice_web_unpack.XXXXXX")"
trap 'rm -rf "$tmp_unpack"' EXIT

unzip -oq "$NGSPICE_ZIP" -d "$tmp_unpack"

mkdir -p "$NGSPICE_DIR"
found_lib="$(find "$tmp_unpack" -type f -name "libngspice.so" | head -n 1 || true)"
if [ -z "$found_lib" ]; then
  echo "ERROR: Could not locate libngspice.so after unpacking $NGSPICE_ZIP" >&2
  exit 1
fi
cp "$found_lib" "$NGSPICE_LIB"
cp "$found_lib" "$NGSPICE_ROOT_LIB"

mkdir -p "$NGSPICE_DIR/lib/ngspice"
while IFS= read -r cm_file; do
  cp "$cm_file" "$NGSPICE_DIR/lib/ngspice/"
done < <(find "$tmp_unpack" -type f -name "*.cm" | sort)

cp "$ROOT_DIR/project/web/upload_bridge.js" "$EXPORT_DIR/upload_bridge.js"
cp "$ROOT_DIR/project/web/server.js" "$EXPORT_DIR/server.js"

node "$ROOT_DIR/scripts/patch_web_export_config.js" "$INDEX_HTML" "$NGSPICE_PRELOAD_PATH"

if [ ! -f "$NGSPICE_LIB" ]; then
  echo "ERROR: ngspice side module copy failed: $NGSPICE_LIB" >&2
  exit 1
fi

if [ ! -f "$NGSPICE_ROOT_LIB" ]; then
  echo "ERROR: ngspice root side module copy failed: $NGSPICE_ROOT_LIB" >&2
  exit 1
fi

if ! grep -Eq "\"$NGSPICE_PRELOAD_PATH\"" "$INDEX_HTML"; then
  echo "ERROR: index.html was not patched with ngspice preload path" >&2
  exit 1
fi

echo "Web export ngspice setup complete."
echo "  Side module: $NGSPICE_ROOT_LIB"
echo "  Runtime files: $NGSPICE_DIR"
echo "  HTML preload: $NGSPICE_PRELOAD_PATH"
