#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_IMAGE="${DOCKER_IMAGE:-ngspice-wasm-build:latest}"
TARGET="${TARGET:-template_release}"
THREADS="${THREADS:-yes}"
JOBS="${JOBS:-4}"

if [[ "$THREADS" == "yes" || "$THREADS" == "true" || "$THREADS" == "1" ]]; then
  find "$ROOT_DIR/project/bin" -maxdepth 1 -type f -name 'libcircuit_sim.web.*.nothreads.wasm' -delete
fi

docker run --rm \
  -v "$ROOT_DIR:/work" \
  -w /work \
  "$DOCKER_IMAGE" \
  bash -lc "
    set -euo pipefail
    source /opt/emsdk/emsdk_env.sh >/dev/null
    python3 -m pip install --quiet scons
    mkdir -p project/bin
    scons platform=web target=${TARGET} threads=${THREADS} -j${JOBS}
  "
