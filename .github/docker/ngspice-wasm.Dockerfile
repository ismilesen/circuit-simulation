FROM python:3.13-slim

ENV EMSDK_DIR=/opt/emsdk
ENV PYODIDE_RECIPES_DIR=/opt/pyodide-recipes
ENV PYODIDE_INSTALL_DIR=/opt/pyodide-install

SHELL ["/bin/bash", "-lc"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential git curl ca-certificates python3-venv python3-pip \
       autoconf automake libtool pkg-config cmake bison flex \
       libncurses5-dev libreadline-dev libx11-dev libxaw7-dev \
       wget unzip xz-utils zip \
    && rm -rf /var/lib/apt/lists/*

# Install pyodide-build from pyodide-recipes.
RUN git clone https://github.com/pyodide/pyodide-recipes.git "${PYODIDE_RECIPES_DIR}" \
    && cd "${PYODIDE_RECIPES_DIR}" \
    && git submodule update --init --recursive \
    && python3 -m pip install --no-cache-dir ./pyodide-build

# Install emsdk version pinned by pyodide.
RUN git clone https://github.com/emscripten-core/emsdk.git "${EMSDK_DIR}" \
    && cd "${EMSDK_DIR}" \
    && EMS_VERSION="$(pyodide config get emscripten_version)" \
    && ./emsdk install "${EMS_VERSION}" \
    && ./emsdk activate "${EMS_VERSION}"

# Keep the Pyodide libngspice recipe available for its compatibility patches.
# The ngspice source itself is downloaded by scripts/build_libngspice_wasm_docker.sh
# from the pinned GitHub mirror tag. Building the recipe here would repeat an
# unrelated source fetch and can break when Pyodide's upstream URL changes.
RUN cd "${PYODIDE_RECIPES_DIR}" \
    && test -f packages/libngspice/patches/0001-keep-alive-API-functions.patch \
    && test -f packages/libngspice/patches/0002-fix-hicum2-extern-c.patch \
    && test -f packages/libngspice/patches/0003-fix-verilog-install-hook.patch
