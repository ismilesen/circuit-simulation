extends Node3D

@export var scale_factor: float = 0.01

var parser: SchParser
var _sidebar: SidebarPanel = null

## Cached SymbolDefinition objects keyed by symbol name.
var _sym_cache: Dictionary = {}

## Cached materials keyed by component type.
var _materials: Dictionary = {}

## Search paths for resolving symbol file names.
var _sym_search_paths: Array[String] = [
	"res://symbols/sym/",
	"res://symbols/sym/sky130_fd_pr/",
	"res://symbols/",
	"res://symbols/sky130_fd_pr/",
]


var _floor: MeshInstance3D = null


func _ready() -> void:
	parser = SchParser.new()
	_build_materials()
	_create_floor()
	_setup_upload_ui()


func load_schematic(path: String) -> bool:
	if not parser.parse_file(path):
		push_error("Failed to parse: " + path)
		return false

	_draw_circuit()

	# Print summary
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
	ui_layer.layer = 10
	ui_layer.name = "UILayer"
	get_parent().add_child.call_deferred(ui_layer)
	ui_layer.add_child(_sidebar)


func _on_schematic_requested(path: String) -> void:
	print("Loading schematic from UI: " + path)
	load_schematic(path)


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
