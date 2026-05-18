# Circuit Simulator

A Godot 4.5 GDExtension project for visualizing and simulating electronic circuits. Parses xschem `.sch` schematics and `.sym` symbol files, renders them in 2D/3D, and optionally runs SPICE simulations via ngspice.

## Setup

### 1. Clone with app submodules

```bash
git clone https://github.com/ismilesen/circuit-simulator.git
cd circuit-simulator
git submodule update --init godot-cpp src/xschem2spice
```

Do not use `--recursive` for the normal app build. The `xschem2spice`
repository contains large test-fixture submodules, and one nested test
dependency uses an SSH URL. Those tests are not needed to compile this project.

If you already cloned without submodules:

```bash
git submodule update --init godot-cpp src/xschem2spice
```

### 2. Build the GDExtension

```bash
scons
```

This compiles the C++ source in `src/`, including the `src/xschem2spice`
submodule library sources, and places the resulting shared library in
`project/bin/`.

For web exports, install and activate Emscripten before building:

```bash
scons platform=web target=template_debug threads=no
scons platform=web target=template_release threads=no
```

If SCons reports `Required toolchain not found for platform web`, Emscripten is
not active in the shell that is running the build.

### 3. ngspice (optional, for simulation)

The simulator dynamically loads ngspice at runtime. To enable simulation:

1. Download ngspice from https://ngspice.sourceforge.io/
2. Place `ngspice.dll` (Windows) or `libngspice.so` (Linux) and `sharedspice.h` in a new folder named `ngspice`.
3. If building with ngspice headers, uncomment and set the `CPPPATH` line in `SConstruct`.

### 4. Open in Godot

Open the `project/` folder as a Godot project (Godot 4.5+).

## Adding circuit files

- Place `.sch` schematic files in `project/schematics/`.
- Place supporting `.sym` symbol files in `project/symbols/sym/`, or upload them alongside the schematic.
- You can also drag-and-drop files into the running application via the upload panel. A `.sch` upload is converted to a generated `.spice` netlist with `xschem2spice`; uploading a separate netlist is optional.

## Project structure

```
circuit-simulator/
├── godot-cpp/          # Git submodule (Godot C++ bindings)
├── src/                # C++ GDExtension source (CircuitSimulator, SchParser)
├── project/            # Godot project
│   ├── bin/            # Built shared libraries + .gdextension
│   ├── camera/         # 3D camera controller
│   ├── parser/         # GDScript .sym parser
│   ├── scripts/        # 3D circuit visualizer script
│   ├── symbols/        # Circuit symbol GDScript + sym/ for .sym files
│   ├── schematics/     # Place .sch files here
│   └── ui/             # Upload panel and sidebar UI
│   └── visualizer/
│   └── simulator/
├── SConstruct          # Build configuration
└── README.md
```
