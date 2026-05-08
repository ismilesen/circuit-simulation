extends Node3D

## Main orchestrator. Responsibilities:
##   1. Parse + render the .sch schematic.
##   2. On spice_paired signal: call sim.run_continuous(path).
##   3. On signal_names_ready: build net→column-index map.
##   4. On simulation_data_ready: update wire emission brightness live.

const _SIM_SCRIPT_PATH := "res://simulator/circuit_simulator.gd"

@export var scale_factor: float = 0.01

# ---------- Shared state (read by helper scripts) ----------

## Symbol definition cache: symbol_name → SymbolDefinition.
var _sym_cache: Dictionary = {}

## Shared materials: component_type → StandardMaterial3D.
var _materials: Dictionary = {}

## Search paths for .sym files.
var _sym_search_paths: Array[String] = [
	"res://symbols/sym/",
	"res://symbols/sym/sky130_fd_pr/",
	"res://symbols/",
	"res://symbols/sky130_fd_pr/",
]

## net_label_lower → StandardMaterial3D  (labeled wires only)
var _net_materials: Dictionary = {}

# ---------- Simulation state ----------

## net_label_lower → column index in each sample from simulation_data_ready.
var _net_index: Dictionary = {}

## Column index of the "time" vector (-1 = not found).
var _time_index: int = -1

# ---------- References ----------
var _sim: Node = null
var _sidebar: SidebarPanel = null
var _floor: MeshInstance3D = null
var _scene_builder: VisSceneBuilder

# Voltage scale (sky130 VDD)
const VMAX: float = 1.8


func _ready() -> void:
	_materials = VisMaterialFactory.build_materials()
	_floor = VisMaterialFactory.create_floor(self)
	_scene_builder = VisSceneBuilder.new(self)
	_setup_ui()


# ---------- Schematic loading ----------

func load_schematic(path: String) -> bool:
	var parser := SchParser.new()
	if not parser.parse_file(path):
		push_error("Failed to parse: " + path)
		return false
	_scene_builder.draw_circuit(parser, _floor)
	print("Loaded schematic: %s  (%d components, %d wires)" % [
		path, parser.components.size(), parser.wires.size()])
	return true


# ---------- UI setup ----------

func _setup_ui() -> void:
	# Locate or instantiate the simulator node.
	_sim = _find_or_create_sim()
	if _sim != null:
		if _sim.has_signal("signal_names_ready"):
			_sim.connect("signal_names_ready", Callable(self, "_on_signal_names_ready"))
		if _sim.has_signal("simulation_data_ready"):
			_sim.connect("simulation_data_ready", Callable(self, "_on_simulation_data_ready"))
		if _sim.has_signal("simulation_started"):
			_sim.connect("simulation_started", Callable(self, "_on_simulation_started"))
		if _sim.has_signal("simulation_finished"):
			_sim.connect("simulation_finished", Callable(self, "_on_simulation_finished"))

	_sidebar = SidebarPanel.new()
	_sidebar.name = "Sidebar"
	_sidebar.schematic_requested.connect(_on_schematic_requested)
	_sidebar.spice_paired.connect(_on_spice_paired)

	var ui_layer := CanvasLayer.new()
	ui_layer.layer = 10
	ui_layer.name = "UILayer"
	get_parent().add_child.call_deferred(ui_layer)
	ui_layer.add_child(_sidebar)


func _find_or_create_sim() -> Node:
	# 1. Search the existing tree.
	for c: Node in get_tree().root.find_children("*", "", true, false):
		if c.has_method("run_continuous"):
			return c
	# 2. Instantiate from GDScript (safe; does not re-register the GDExtension class).
	var script: Resource = load(_SIM_SCRIPT_PATH)
	if script is GDScript:
		var obj: Variant = (script as GDScript).new()
		if obj is Node:
			var node: Node = obj as Node
			node.name = "CircuitSimulator"
			get_parent().add_child.call_deferred(node)
			return node
	push_warning("Visualizer: could not find or create CircuitSimulator — simulation unavailable.")
	return null


# ---------- Signal handlers ----------

func _on_schematic_requested(path: String) -> void:
	load_schematic(path)


func _on_spice_paired(path: String) -> void:
	if _sim == null:
		push_warning("Visualizer: no simulator node — cannot run simulation.")
		return
	if not _sim.has_method("run_continuous"):
		push_warning("Visualizer: simulator lacks run_continuous().")
		return
	# Reset index map; it will be rebuilt when signal_names_ready fires.
	_net_index.clear()
	_time_index = -1
	_reset_wire_brightness()
	print("Visualizer: starting continuous simulation for: " + path)
	var ok: bool = _sim.call("run_continuous", path)
	if not ok:
		push_error("Visualizer: run_continuous() failed.")


func _on_simulation_started() -> void:
	print("Visualizer: simulation running.")


func _on_simulation_finished() -> void:
	print("Visualizer: simulation stopped.")


## Receives the ordered vector-name list emitted once before the first data point.
## Builds the net_label → column-index map used by _on_simulation_data_ready.
func _on_signal_names_ready(names: PackedStringArray) -> void:
	_net_index.clear()
	_time_index = -1
	print("Visualizer: received %d signal names." % names.size())
	for i: int in range(names.size()):
		var raw: String = str(names[i])
		var norm: String = VisGeomUtils.normalize_vec_name(raw)
		if norm == "time":
			_time_index = i
		else:
			_net_index[norm] = i
	print("Visualizer: mapped %d nets. time_index=%d" % [_net_index.size(), _time_index])


## Called every 64 ngspice time-steps with a flat sample array.
## Updates each labeled wire's emission brightness proportional to voltage (0–1.8 V).
func _on_simulation_data_ready(sample: PackedFloat64Array) -> void:
	for net: String in _net_index.keys():
		if not _net_materials.has(net):
			continue
		var col: int = int(_net_index[net])
		if col >= sample.size():
			continue
		var voltage: float = float(sample[col])
		var t: float = clamp(voltage / VMAX, 0.0, 1.0)
		var mat: StandardMaterial3D = _net_materials[net]
		# Emission color: warm yellow, brightness scaled 0 → full.
		mat.emission = Color(1.0, 0.95, 0.3)
		mat.emission_energy_multiplier = 0.05 + t * 2.5


# ---------- Helpers ----------

## Resets all labeled wires to dark (no emission) before a new simulation run.
func _reset_wire_brightness() -> void:
	for mat: StandardMaterial3D in _net_materials.values():
		mat.emission_energy_multiplier = 0.0
