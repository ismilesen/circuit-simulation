extends Node3D

## Main orchestrator. Responsibilities:
##   1. Parse + render the .sch schematic.
##   2. On spice_paired signal: remember that a netlist is staged.
##   3. On signal_names_ready: build net→column-index map.
##   4. On simulation_data_ready: update wire emission brightness live.

const _SIM_SCRIPT_PATH := "res://simulator/circuit_simulator.gd"
const _PDK_MANIFEST_LOADER_SCRIPT_PATH := "res://pdk/pdk_manifest_loader.gd"

@export var scale_factor: float = 0.01

# ---------- Shared state (read by helper scripts) ----------

## Symbol definition cache: symbol_name → SymbolDefinition.
var _sym_cache: Dictionary = {}

## Shared materials: component_type → StandardMaterial3D.
var _materials: Dictionary = {}

## Search paths for .sym files.
var _sym_search_paths: Array[String] = [
	"user://pdk_symbols/",
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
var _pdk_manifest_loader: Node = null
var _pdk_manifest: Variant = null

# Voltage scale (sky130 VDD)
const VMAX: float = 1.8


func _ready() -> void:
	_materials = VisMaterialFactory.build_materials()
	_floor = VisMaterialFactory.create_floor(self)
	_scene_builder = VisSceneBuilder.new(self)
	_setup_ui()
	_setup_pdk_manifest_loader()


# ---------- Schematic loading ----------

func load_schematic(path: String) -> bool:
	var parser := SchParser.new()
	if not parser.parse_file(path):
		push_error("Failed to parse: " + path)
		return false
	await _wait_for_pdk_manifest_if_needed()
	await _ensure_schematic_symbols_cached(parser)
	_scene_builder.draw_circuit(parser, _floor)
	print("Loaded schematic: %s  (%d components, %d wires)" % [
		path, parser.components.size(), parser.wires.size()])
	return true


func _wait_for_pdk_manifest_if_needed() -> void:
	if not OS.has_feature("web") or _pdk_manifest != null or _pdk_manifest_loader == null:
		return

	for _i: int in range(180):
		if _pdk_manifest != null:
			return
		await get_tree().process_frame


func _ensure_schematic_symbols_cached(parser: Variant) -> void:
	if _pdk_manifest_loader == null:
		return

	var requested: Dictionary = {}
	for comp: Dictionary in parser.components:
		var symbol_name := str(comp.get("symbol", ""))
		var basename := symbol_name.get_file()
		if basename == "" or requested.has(basename):
			continue
		requested[basename] = true

		var sym_def: Variant = await _load_symbol_definition_for_name(symbol_name, basename)
		if sym_def == null:
			continue
		_sym_cache[symbol_name] = sym_def
		_sym_cache[basename] = sym_def


func _load_symbol_definition_for_name(symbol_name: String, basename: String) -> Variant:
	if _pdk_manifest != null and _pdk_manifest.has_method("get_symbol_for_file") and _pdk_manifest_loader.has_method("get_symbol_text"):
		var symbol: Dictionary = _pdk_manifest.get_symbol_for_file(basename)
		if not symbol.is_empty():
			var text: String = await _pdk_manifest_loader.get_symbol_text(symbol)
			if text != "":
				var sym_def := SymParser.parse_string(text)
				_sym_cache[str(symbol.get("symbol_path", ""))] = sym_def
				_sym_cache[str(symbol.get("symbol_path", "")).get_file()] = sym_def
				_sym_cache[str(symbol.get("id", "")) + ".sym"] = sym_def
				if _pdk_manifest_loader.has_method("ensure_symbol_cached"):
					_pdk_manifest_loader.ensure_symbol_cached(symbol)
				return sym_def

	for search_path: String in _sym_search_paths:
		var candidate := search_path + symbol_name
		if FileAccess.file_exists(candidate):
			return SymParser.parse(candidate)
		candidate = search_path + basename
		if FileAccess.file_exists(candidate):
			return SymParser.parse(candidate)

	return null


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
	_sidebar.pdk_component_selected.connect(_on_pdk_component_selected)

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


func _setup_pdk_manifest_loader() -> void:
	var script: Resource = load(_PDK_MANIFEST_LOADER_SCRIPT_PATH)
	if not (script is GDScript):
		push_warning("Visualizer: could not load PDK manifest loader.")
		return

	var obj: Variant = (script as GDScript).new()
	if not (obj is Node):
		push_warning("Visualizer: PDK manifest loader script did not instantiate.")
		return

	_pdk_manifest_loader = obj as Node
	_pdk_manifest_loader.name = "PdkManifestLoader"
	add_child(_pdk_manifest_loader)
	_pdk_manifest_loader.manifest_loaded.connect(_on_pdk_manifest_loaded)
	_pdk_manifest_loader.manifest_failed.connect(_on_pdk_manifest_failed)
	_pdk_manifest_loader.symbol_loaded.connect(_on_pdk_symbol_loaded)
	_pdk_manifest_loader.symbol_failed.connect(_on_pdk_symbol_failed)
	_pdk_manifest_loader.symbols_cached.connect(_on_pdk_symbols_cached)
	if OS.has_feature("web"):
		_pdk_manifest_loader.load_sky130_manifest()


# ---------- Signal handlers ----------

func _on_schematic_requested(path: String) -> void:
	await load_schematic(path)


func _on_spice_paired(path: String) -> void:
	print("Visualizer: netlist staged, waiting for Run Simulation: " + path)


func _on_simulation_started() -> void:
	# Reset index map; it will be rebuilt when signal_names_ready fires.
	_net_index.clear()
	_time_index = -1
	_reset_wire_brightness()
	print("Visualizer: simulation running.")


func _on_simulation_finished() -> void:
	print("Visualizer: simulation stopped.")


func _on_pdk_manifest_loaded(manifest: Variant) -> void:
	_pdk_manifest = manifest
	if _sidebar != null:
		_sidebar.set_pdk_manifest(manifest)
	print("Visualizer: loaded %s PDK manifest (%d symbols, %d files)." % [
		manifest.pdk_family,
		manifest.get_symbol_count(),
		manifest.get_file_count(),
	])
	_pdk_manifest_loader.cache_manifest_symbols(manifest)


func _on_pdk_manifest_failed(message: String) -> void:
	if OS.has_feature("web"):
		push_warning("Visualizer: " + message)
	else:
		print("Visualizer: " + message)


func _on_pdk_component_selected(component: Dictionary) -> void:
	if _pdk_manifest_loader == null:
		return
	print("Visualizer: loading PDK symbol: %s" % str(component.get("id", "")))
	_pdk_manifest_loader.load_symbol(component)


func _on_pdk_symbol_loaded(symbol: Dictionary, text: String, cached_path: String) -> void:
	if cached_path != "" and FileAccess.file_exists(cached_path):
		var sym_def := SymParser.parse(cached_path)
		_sym_cache[str(symbol.get("symbol_path", ""))] = sym_def
		_sym_cache[str(symbol.get("id", "")) + ".sym"] = sym_def
	print("Visualizer: loaded PDK symbol %s (%d chars, cached: %s)." % [
		str(symbol.get("id", "")),
		text.length(),
		cached_path,
	])


func _on_pdk_symbol_failed(symbol: Dictionary, message: String) -> void:
	push_warning("Visualizer: failed to load PDK symbol %s: %s" % [
		str(symbol.get("id", "")),
		message,
	])


func _on_pdk_symbols_cached(count: int) -> void:
	print("Visualizer: cached %d PDK symbol files for schematic rendering." % count)


## Receives the ordered vector-name list emitted once before the first data point.
## Builds the net_label → column-index map used by _on_simulation_data_ready.
func _on_signal_names_ready(names: PackedStringArray) -> void:
	_net_index.clear()
	_time_index = -1
	_reset_wire_brightness()
	print("Visualizer: received %d signal names." % names.size())
	for i: int in range(names.size()):
		var raw: String = str(names[i])
		var norm: String = VisGeomUtils.normalize_vec_name(raw)
		if norm == "time":
			_time_index = i
		else:
			_net_index[norm] = i
	print("Visualizer: mapped %d nets. time_index=%d" % [_net_index.size(), _time_index])


## Called periodically from CircuitSimulator with a flat sample array.
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
