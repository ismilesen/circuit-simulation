extends Node3D

<<<<<<< HEAD
@export var scale_factor: float = 0.01

var parser: SchParser
var _sidebar: SidebarPanel = null

## Cached SymbolDefinition objects keyed by symbol name.
var _sym_cache: Dictionary = {}

## Cached materials keyed by component type.
var _materials: Dictionary = {}

## Search paths for resolving symbol file names.
=======
## Preloaded once at class level so every wire shares the same Shader object.
const _WIRE_FILL_SHADER = preload("res://visualizer/wire_fill.gdshader")

@export var scale_factor: float = 0.01

## Real seconds over which the full simulation period plays back (loop).
@export var anim_playback_duration: float = 5.0

## Real seconds it takes for a flow cursor to travel one wire segment.
@export var cursor_traverse_seconds: float = 1.5

## Minimum |ΔV| / Vmax that triggers a cursor (lower = more sensitive).
@export var dv_anim_threshold: float = 0.04

var parser: SchParser
var _sidebar: SidebarPanel = null
var _floor: MeshInstance3D = null

# ---------- Shared state (read/written by helper scripts) ----------

## Symbol definition cache: symbol_name → SymbolDefinition.
var _sym_cache: Dictionary = {}

## Shared materials: component_type → StandardMaterial3D.
var _materials: Dictionary = {}

## Search paths for .sym files.
>>>>>>> cd7f9eb (visualization and simulation addition)
var _sym_search_paths: Array[String] = [
	"res://symbols/sym/",
	"res://symbols/sym/sky130_fd_pr/",
	"res://symbols/",
	"res://symbols/sky130_fd_pr/",
]

<<<<<<< HEAD

var _floor: MeshInstance3D = null
=======
## net_label_lower → Array[MeshInstance3D]
var _net_nodes: Dictionary = {}
## net_label_lower → StandardMaterial3D
var _net_materials: Dictionary = {}

var _sim_time: Array = []
var _sim_vectors: Dictionary = {}   # normalized_name → Array[float]
var _anim_active: bool = false
var _anim_sim_elapsed: float = 0.0
var _real_elapsed: float = 0.0      # monotonic real-time counter

## Wire flow cursors: one per labeled segment.
var _wire_cursors: Array[Dictionary] = []

## Transistor connectivity from paired SPICE: comp_name → {d,g,s,b,type}.
var _transistor_data: Dictionary = {}
## Per-transistor duplicated material for independent conductance animation.
var _transistor_materials: Dictionary = {}
## CircuitSymbol nodes keyed by comp_name for pin position lookup.
var _transistor_nodes: Dictionary = {}

## Channel cursors: one per transistor, travels D→S through the body.
var _transistor_cursors: Array[Dictionary] = []
var _transistor_cursor_map: Dictionary = {}   # comp_name → index

## Gate cursors + flash/fill: one per transistor.
var _gate_cursors: Array[Dictionary] = []
var _gate_cursor_map: Dictionary = {}

## World positions of input-pin components for cascade BFS seeding.
var _input_positions: Array[Vector3] = []

## Per-net cascade state: net_label → {trigger_t, max_hop, color_old/new, energy_old/new}.
var _net_cascade: Dictionary = {}

## gate_net (lower) → Array[String] comp_names whose gate is that net.
var _gate_to_transistors: Dictionary = {}
## upstream_net → Array[String] comp_names whose inlet (D) is that net.
var _upstream_to_transistors: Dictionary = {}

## Edge-detection trackers (true = was idle last frame).
var _net_was_done: Dictionary = {}
var _tc_was_done: Array[bool] = []
var _gc_was_done: Array[bool] = []

## Nets directly reachable from input pins through wire connections (hop_dist < 999).
## Only these nets self-trigger their cascades from voltage-transition detection.
## All other nets (behind transistors) are triggered only via cascade_net_from_pin.
var _seed_nets: Dictionary = {}

# ---------- Helper instances ----------
var _scene_builder:  VisSceneBuilder
var _cursor_builder: VisCursorBuilder
var _anim_player:    VisAnimPlayer
>>>>>>> cd7f9eb (visualization and simulation addition)


func _ready() -> void:
	parser = SchParser.new()
<<<<<<< HEAD
	_build_materials()
	_create_floor()
	_setup_upload_ui()


=======
	_materials = VisMaterialFactory.build_materials()
	_floor = VisMaterialFactory.create_floor(self)
	_scene_builder  = VisSceneBuilder.new(self)
	_cursor_builder = VisCursorBuilder.new(self)
	_anim_player    = VisAnimPlayer.new(self)
	_setup_upload_ui()


func _process(delta: float) -> void:
	_anim_player.process_frame(delta)


# ---------- Schematic loading ----------

>>>>>>> cd7f9eb (visualization and simulation addition)
func load_schematic(path: String) -> bool:
	if not parser.parse_file(path):
		push_error("Failed to parse: " + path)
		return false

<<<<<<< HEAD
	_draw_circuit()

	# Print summary
=======
	_scene_builder.draw_circuit(parser, _floor)

>>>>>>> cd7f9eb (visualization and simulation addition)
	var type_counts: Dictionary = {}
	for comp in parser.components:
		var t: String = comp.get("type", "unknown")
		type_counts[t] = type_counts.get(t, 0) + 1
	print("=== Loaded: %s ===" % path)
	print("  Components: %d" % parser.components.size())
	for t in type_counts:
		print("    %s: %d" % [t, type_counts[t]])
	print("  Wires: %d" % parser.wires.size())
	print("  Scene nodes: %d" % get_child_count())

	return true


<<<<<<< HEAD
func _build_materials() -> void:
	_materials.clear()
	var defs = {
		"pmos": Color(1.0, 0.2, 0.8),
		"nmos": Color(0.2, 0.8, 1.0),
		"input_pin": Color(0.2, 1.0, 0.3),
		"ipin": Color(0.2, 1.0, 0.3),
		"output_pin": Color(1.0, 0.2, 0.2),
		"opin": Color(1.0, 0.2, 0.2),
		"label": Color(1.0, 1.0, 0.3),
		"resistor": Color(1.0, 0.6, 0.1),
		"capacitor": Color(0.4, 0.6, 1.0),
		"poly_resistor": Color(1.0, 0.6, 0.1),
		"unknown": Color(0.5, 0.5, 0.5),
		"wire": Color(0.9, 0.9, 0.9),
	}
	for type in defs:
		var mat = StandardMaterial3D.new()
		mat.albedo_color = defs[type]
		mat.emission_enabled = true
		mat.emission = defs[type]
		mat.emission_energy_multiplier = 0.3
		_materials[type] = mat


func _create_floor() -> void:
	_floor = MeshInstance3D.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(50, 50)
	_floor.mesh = plane
	_floor.position = Vector3(0, -0.01, 0)

	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.08, 0.12)
	mat.metallic = 0.2
	mat.roughness = 0.8
	_floor.material_override = mat
	_floor.name = "Floor"
	add_child(_floor)


func _setup_upload_ui() -> void:
	_sidebar = SidebarPanel.new()
	_sidebar.name = "Sidebar"
	_sidebar.schematic_requested.connect(_on_schematic_requested)

	var ui_layer = CanvasLayer.new()
=======
# ---------- UI setup ----------

func _setup_upload_ui() -> void:
	var sim_packed = load("res://circuit_simulator.tscn")
	if sim_packed != null:
		var sim := (sim_packed as PackedScene).instantiate()
		sim.name = "CircuitSimulator"
		sim.simulation_finished.connect(_on_simulation_finished)
		get_parent().add_child.call_deferred(sim)
	else:
		push_warning("Could not load res://circuit_simulator.tscn — simulation will be unavailable.")

	_sidebar = SidebarPanel.new()
	_sidebar.name = "Sidebar"
	_sidebar.schematic_requested.connect(_on_schematic_requested)
	_sidebar.spice_paired.connect(_on_spice_paired)

	var ui_layer := CanvasLayer.new()
>>>>>>> cd7f9eb (visualization and simulation addition)
	ui_layer.layer = 10
	ui_layer.name = "UILayer"
	get_parent().add_child.call_deferred(ui_layer)
	ui_layer.add_child(_sidebar)


<<<<<<< HEAD
=======
# ---------- Signal handlers ----------

>>>>>>> cd7f9eb (visualization and simulation addition)
func _on_schematic_requested(path: String) -> void:
	print("Loading schematic from UI: " + path)
	load_schematic(path)


<<<<<<< HEAD
func _draw_circuit() -> void:
	# Clear previous children (keep the floor)
	for child in get_children():
		if child == _floor:
			continue
		child.queue_free()

	for wire in parser.wires:
		_draw_wire(wire)

	for comp in parser.components:
		_draw_component(comp)


# ---------- Wires ----------

func _draw_wire(wire: Dictionary) -> void:
	var p1 = Vector3(wire.x1, 0, -wire.y1) * scale_factor
	var p2 = Vector3(wire.x2, 0, -wire.y2) * scale_factor

	var midpoint = (p1 + p2) / 2.0
	var direction = p2 - p1
	var length = direction.length()

	if length < 0.001:
		return

	var mi = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(length, 0.015, 0.015)
	mi.mesh = box
	mi.material_override = _materials["wire"]
	mi.position = midpoint
	mi.rotation.y = -atan2(direction.z, direction.x)
	add_child(mi)

	# Connection dots at both endpoints
	_draw_connection_dot(p1)
	_draw_connection_dot(p2)

	# Wire label at midpoint
	var label_text: String = wire.get("label", "")
	if label_text != "":
		var label = Label3D.new()
		label.text = label_text
		label.position = midpoint + Vector3(0, 0.04, 0)
		label.font_size = 96
		label.pixel_size = 0.0005
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.modulate = Color(0.7, 0.7, 0.7)
		label.outline_size = 8
		label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		add_child(label)


func _draw_connection_dot(pos: Vector3) -> void:
	var mi = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.012
	sphere.height = 0.024
	mi.mesh = sphere
	mi.material_override = _materials["wire"]
	mi.position = pos
	add_child(mi)


# ---------- Components ----------

func _draw_component(comp: Dictionary) -> void:
	var pos = Vector3(comp.x, 0, -comp.y) * scale_factor
	var type: String = parser.get_component_type(comp.symbol)
	var rot: int = comp.get("rotation", 0)
	var mirror: int = comp.get("mirror", 0)

	# Get parsed SymbolDefinition (cached)
	var sym_def: SymbolDefinition = _get_sym_def(comp.symbol)

	# Determine material from the .sym type field, falling back to SchParser type
	var mat_type: String = sym_def.type if sym_def.type != "" else type
	var mat: StandardMaterial3D = _get_material(mat_type)

	# Create data-driven symbol
	var symbol = CircuitSymbol.new()
	symbol.setup(comp, sym_def, scale_factor, mat)
	symbol.position = pos
	symbol.rotation.y = deg_to_rad(rot * 90.0)
	if mirror:
		symbol.scale.x = -1.0
	add_child(symbol)

	# Label (added to self, not the rotated symbol, so text stays upright)
	var comp_label: String = comp.get("label", "")
	var label_text: String = comp_label if comp_label != "" else mat_type

	var label = Label3D.new()
	label.text = label_text
	label.position = pos + Vector3(0, _get_label_height(mat_type), 0)
	label.font_size = 96
	label.pixel_size = 0.0005
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = mat.albedo_color
	label.outline_size = 8
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	add_child(label)


# ---------- Symbol Resolution ----------

func _get_sym_def(symbol_name: String) -> SymbolDefinition:
	if _sym_cache.has(symbol_name):
		return _sym_cache[symbol_name]

	var path = _resolve_sym_path(symbol_name)
	var sym_def: SymbolDefinition
	if path == "":
		sym_def = SymbolDefinition.new()
	else:
		sym_def = SymParser.parse(path)

	_sym_cache[symbol_name] = sym_def
	return sym_def


func _resolve_sym_path(symbol_name: String) -> String:
	# symbol_name from .sch: e.g. "sky130_fd_pr/nfet_01v8.sym" or "ipin.sym"

	# Try direct path under symbols/sym/
	for search_path in _sym_search_paths:
		var candidate = search_path + symbol_name
		if FileAccess.file_exists(candidate):
			return candidate

	# Try just the filename in each search path
	var basename = symbol_name.get_file()
	for search_path in _sym_search_paths:
		var candidate = search_path + basename
		if FileAccess.file_exists(candidate):
			return candidate

	# Recursive fallback search (slower, handles unknown directory layouts)
	var found = _find_sym_recursive("res://symbols", basename)
	if found != "":
		return found

	push_warning("SymParser: .sym file not found for: " + symbol_name)
	return ""


func _find_sym_recursive(base_path: String, filename: String) -> String:
	var dir = DirAccess.open(base_path)
	if dir == null:
		return ""

	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		var full_path = base_path + "/" + file_name
		if dir.current_is_dir():
			if file_name != "." and file_name != "..":
				var result = _find_sym_recursive(full_path, filename)
				if result != "":
					dir.list_dir_end()
					return result
		else:
			if file_name == filename:
				dir.list_dir_end()
				return full_path
		file_name = dir.get_next()

	dir.list_dir_end()
	return ""


func _get_material(type: String) -> StandardMaterial3D:
	if _materials.has(type):
		return _materials[type]
	return _materials["unknown"]


func _get_label_height(type: String) -> float:
	match type:
		"pmos": return 0.08
		"nmos": return 0.08
		"resistor", "poly_resistor": return 0.08
		"label": return 0.04
		"ipin", "input_pin": return 0.06
		"opin", "output_pin": return 0.06
		_: return 0.07
=======
func _on_spice_paired(path: String) -> void:
	_transistor_data = VisGeomUtils.parse_spice_transistors(path)
	print("Visualizer: paired SPICE — %d transistors mapped for conductance animation" % _transistor_data.size())
	_cursor_builder.build_transistor_cursors()

	# Gate net map: straight-forward from SPICE.
	_gate_to_transistors.clear()
	for comp_name: String in _transistor_data.keys():
		var gate_net: String = str(_transistor_data[comp_name]["g"])
		if not _gate_to_transistors.has(gate_net):
			_gate_to_transistors[gate_net] = []
		(_gate_to_transistors[gate_net] as Array).append(comp_name)

	# Upstream net map: built from from_spice_pin stored in each cursor, because
	# layout SPICE can swap D and S vs. schematic convention.  This ensures that
	# when an internal node cascade finishes, the next transistor in the current
	# path (whose supply side sits at that node) is triggered correctly.
	_upstream_to_transistors.clear()
	for tc: Dictionary in _transistor_cursors:
		var cn: String = str(tc["comp_name"])
		if not _transistor_data.has(cn):
			continue
		var from_pin: String    = str(tc.get("from_spice_pin", "s"))
		var source_net: String  = str(_transistor_data[cn][from_pin])
		if not _upstream_to_transistors.has(source_net):
			_upstream_to_transistors[source_net] = []
		(_upstream_to_transistors[source_net] as Array).append(cn)

	print("Visualizer: %d gate nets, %d upstream nets wired for cascade" % [
		_gate_to_transistors.size(), _upstream_to_transistors.size()])


func _on_simulation_finished() -> void:
	print("Simulation finished — fetching vectors for animation...")
	var sim: Node = get_tree().root.find_child("CircuitSimulator", true, false)
	if sim == null:
		push_warning("Visualizer: CircuitSimulator not found after simulation_finished")
		return

	var names: PackedStringArray = sim.call("get_last_sim_signal_names")
	var snapshot: Array = sim.call("get_last_sim_snapshot")
	print("Visualizer: buffer has %d signal names, %d samples" % [names.size(), snapshot.size()])
	if names.size() > 0:
		print("Visualizer: signal names = ", Array(names))

	if names.size() > 0 and snapshot.size() > 0:
		var all_vecs: Dictionary = {}
		for i: int in range(names.size()):
			var col: Array = []
			col.resize(snapshot.size())
			for s: int in range(snapshot.size()):
				var row: PackedFloat64Array = snapshot[s]
				col[s] = float(row[i]) if i < row.size() else 0.0
			all_vecs[str(names[i])] = col
		_anim_player.load_sim_data(all_vecs)
		return

	push_warning("Visualizer: callback buffer empty — falling back to get_all_vectors()")
	var all_vecs: Dictionary = sim.call("get_all_vectors")
	if all_vecs.is_empty():
		push_warning("Visualizer: simulation_finished but no vectors available")
		return
	_anim_player.load_sim_data(all_vecs)
>>>>>>> cd7f9eb (visualization and simulation addition)
