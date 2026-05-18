#!/usr/bin/env python
import os
import zipfile


def find_web_ngspice_library():
    configured = ARGUMENTS.get("ngspice_lib") or os.environ.get("NGSPICE_LIB")
    candidates = [
        configured,
        "src/libngspice.so",
        ".tmp/libngspice-package/ngspice/libngspice.so",
        ".tmp/web-link/ngspice/libngspice.so",
    ]

    for candidate in candidates:
        if candidate and os.path.isfile(candidate):
            return candidate

    archive = ARGUMENTS.get("ngspice_zip") or os.environ.get("NGSPICE_ZIP") or "libngspice-44.2.zip"
    if os.path.isfile(archive):
        with zipfile.ZipFile(archive) as package:
            matches = [name for name in package.namelist() if name.endswith("/libngspice.so") or name == "libngspice.so"]
            if matches:
                output = ".tmp/web-link/ngspice/libngspice.so"
                os.makedirs(os.path.dirname(output), exist_ok=True)
                with package.open(matches[0]) as source, open(output, "wb") as target:
                    target.write(source.read())
                return output

    raise ValueError(
        "Web builds need an Emscripten-built libngspice.so. "
        "Set ngspice_lib=/path/to/libngspice.so, or keep libngspice-44.2.zip at the repo root."
    )


env = SConscript("godot-cpp/SConstruct")

# Our C++ source + xschem2spice public headers.
env.Append(CPPPATH=["src/", "src/xschem2spice/src/"])

# ngspice headers - uncomment and adjust if you have ngspice installed locally:
# env.Append(CPPPATH=["path/to/ngspice/include/"])

# Web-specific flags required for GDExtension side module.
if env["platform"] == "web":
    ngspice_lib = find_web_ngspice_library()
    env.Append(LINKFLAGS=[
        "-sSIDE_MODULE=1",
        ngspice_lib,
    ])
    env.Append(CCFLAGS=["-sSIDE_MODULE=1"])

# Build the xschem2spice library sources from the submodule, but do not compile
# its demo CLI because it defines main().
xschem2spice_sources = [
    "src/xschem2spice/src/parser.c",
    "src/xschem2spice/src/netlist.c",
    "src/xschem2spice/src/hash.c",
    "src/xschem2spice/src/strutil.c",
    "src/xschem2spice/src/xschemrc.c",
]
sources = Glob("src/*.cpp") + xschem2spice_sources

# Build the shared library into project/bin/
library = env.SharedLibrary(
    "project/bin/libcircuit_sim{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)
Default(library)
