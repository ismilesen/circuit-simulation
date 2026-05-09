#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ZIP_INPUT="${1:-$ROOT_DIR/libngspice-44.2.zip}"
if [[ "$OUT_ZIP_INPUT" = /* ]]; then
  OUT_ZIP="$OUT_ZIP_INPUT"
else
  OUT_ZIP="$PWD/$OUT_ZIP_INPUT"
fi
DOCKER_IMAGE="${DOCKER_IMAGE:-ngspice-wasm-build:latest}"
THREADS="${THREADS:-yes}"

docker run --rm \
  -v "$ROOT_DIR:/work" \
  -w /work \
  -e THREADS="$THREADS" \
  "$DOCKER_IMAGE" \
  bash -lc '
    set -euo pipefail
    source /opt/emsdk/emsdk_env.sh >/dev/null

    apply_patch_if_needed() {
      local patch_file="$1"
      if patch -N -p1 --dry-run < "$patch_file" >/dev/null 2>&1; then
        patch -N -p1 < "$patch_file"
      else
        echo "Skipping already-applied patch: $patch_file"
      fi
    }

    mkdir -p .tmp/ngspice-web-build
    cd .tmp/ngspice-web-build

    if [ ! -f ngspice-44.2.zip ]; then
      curl -L -o ngspice-44.2.zip https://github.com/danchitnis/ngspice-sf-mirror/archive/refs/tags/ngspice-44.2.zip
    fi

    if [ ! -d ngspice-sf-mirror-ngspice-44.2 ]; then
      unzip -q ngspice-44.2.zip
    fi

    cd ngspice-sf-mirror-ngspice-44.2

    apply_patch_if_needed /opt/pyodide-recipes/packages/libngspice/patches/0001-keep-alive-API-functions.patch
    apply_patch_if_needed /opt/pyodide-recipes/packages/libngspice/patches/0002-fix-hicum2-extern-c.patch
    apply_patch_if_needed /opt/pyodide-recipes/packages/libngspice/patches/0003-fix-verilog-install-hook.patch

    bash ./autogen.sh

    if [ ! -x build-native/src/xspice/cmpp/cmpp ]; then
      mkdir -p build-native
      cd build-native
      ../configure --enable-xspice --disable-debug --without-x --with-readline=no
      make -C src/xspice/cmpp -j ${PYODIDE_JOBS:-3}
      cd ..
    fi

    rm -rf release-lib /tmp/ng-install /work/.tmp/libngspice-package
    mkdir -p release-lib
    cd release-lib

    THREAD_FLAGS=""
    if [ "${THREADS:-yes}" = "yes" ] || [ "${THREADS:-yes}" = "true" ] || [ "${THREADS:-yes}" = "1" ]; then
      THREAD_FLAGS="-pthread"
    fi

    WASM_COMPILE_FLAGS="-O2 -fPIC -fwasm-exceptions -sSUPPORT_LONGJMP=wasm ${THREAD_FLAGS}"
    WASM_LINK_FLAGS="-fwasm-exceptions -sSIDE_MODULE=1 -sSUPPORT_LONGJMP=wasm ${THREAD_FLAGS}"

    ac_cv_func_queryperformancecounter=no emconfigure ../configure \
      --prefix=/tmp/ng-install \
      --enable-xspice \
      --disable-debug \
      --disable-dependency-tracking \
      --enable-cider \
      --with-readline=no \
      --disable-openmp \
      --with-ngshared \
      --host=wasm32-unknown-emscripten \
      CFLAGS="$WASM_COMPILE_FLAGS" \
      CXXFLAGS="$WASM_COMPILE_FLAGS" \
      LDFLAGS="$WASM_LINK_FLAGS"

    emmake make -j ${PYODIDE_JOBS:-3} -C src/xspice/cmpp \
      CFLAGS="$WASM_COMPILE_FLAGS" \
      CXXFLAGS="$WASM_COMPILE_FLAGS" \
      LDFLAGS="$WASM_LINK_FLAGS"
    cp ../build-native/src/xspice/cmpp/cmpp src/xspice/cmpp/cmpp
    touch src/xspice/cmpp/cmpp

    emmake make -j ${PYODIDE_JOBS:-3} \
      CFLAGS="$WASM_COMPILE_FLAGS" \
      CXXFLAGS="$WASM_COMPILE_FLAGS" \
      LDFLAGS="$WASM_LINK_FLAGS"
    emmake make install

    /opt/emsdk/upstream/bin/wasm-dis /tmp/ng-install/lib/libngspice.so -o /tmp/libngspice.wast
    python3 - <<'"'"'PY'"'"'
import re
import sys

s = open("/tmp/libngspice.wast", "r", errors="ignore").read()
imports = set(re.findall(r"\(import \"env\" \"([^\"]+)\"", s))
banned = sorted(
    name for name in imports
    if name == "emscripten_longjmp" or name.startswith("invoke_")
)
if banned:
    print("ERROR: libngspice.so has incompatible imports for Godot web runtime:", file=sys.stderr)
    for name in banned:
        print(f"  - {name}", file=sys.stderr)
    sys.exit(1)
if __import__("os").environ.get("THREADS", "yes") in {"yes", "true", "1"}:
    memory_import = re.search(r"\(import \"env\" \"memory\" \(memory[^\)]*\)", s)
    if not memory_import or " shared" not in memory_import.group(0):
        print("ERROR: threaded web exports need libngspice.so to import shared memory.", file=sys.stderr)
        print("Memory import:", memory_import.group(0) if memory_import else "<missing>", file=sys.stderr)
        sys.exit(1)
print("Verified libngspice.so imports are wasm-longjmp compatible.")
PY

    mkdir -p /work/.tmp/libngspice-package/ngspice/lib/ngspice
    cp /tmp/ng-install/lib/libngspice.so /work/.tmp/libngspice-package/ngspice/libngspice.so
    cp /tmp/ng-install/lib/ngspice/*.cm /work/.tmp/libngspice-package/ngspice/lib/ngspice/
  '

rm -f "$OUT_ZIP"
mkdir -p "$(dirname "$OUT_ZIP")"
(cd "$ROOT_DIR/.tmp/libngspice-package" && zip -qry "$OUT_ZIP" ngspice)

if command -v zipinfo >/dev/null 2>&1; then
  ZIP_ENTRIES="$(zipinfo -1 "$OUT_ZIP")"
else
  ZIP_ENTRIES="$(unzip -l "$OUT_ZIP" | awk 'NR > 3 && $0 !~ /^--------/ { print $4 }')"
fi
if ! printf "%s\n" "$ZIP_ENTRIES" | grep -Eq "(^|/)libngspice\\.so$"; then
  echo "ERROR: Built artifact is missing libngspice.so: $OUT_ZIP" >&2
  echo "Archive entries:" >&2
  printf "%s\n" "$ZIP_ENTRIES" | sed -n '1,80p' >&2
  exit 1
fi

echo "Built ngspice wasm package:"
echo "  $OUT_ZIP"
echo "Contained files:"
printf "%s\n" "$ZIP_ENTRIES" | sed -n '1,20p'
