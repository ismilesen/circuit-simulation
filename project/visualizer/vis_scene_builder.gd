class_name VisSceneBuilder
extends RefCounted

## Builds the 3-D scene from a parsed schematic.
## After draw_circuit() completes, _vis._net_materials is populated with one
## StandardMaterial3D per labeled net, ready for the simulation to update
## their emission_energy_multiplier when simulation_data_ready samples arrive.

var _vis


func _init(vis) -> void:
	_vis = vis


# ---------- Top-level circuit draw ----------

func draw_circuit(parser, floor_: MeshInstance3D) -> void:
	# Clear previous children (keep the floor).
	for child in _vis.get_children():
		if child == floor_:
			continue
		child.queue_free()

	# Reset simulation-facing state.
	_vis._net_materials.clear()
	_vis._net_index.clear()
	_vis._time_index = -1

	var split_wires: Array = VisGeomUtils.split_wires_at_junctions(Array(parser.wires))
	_propagate_labels(split_wires, Array(parser.components))
	for wire: Dictionary in split_wires:
		draw_wire(wire)

	for comp in parser.components:
		draw_component(comp, parser)

	build_net_lookup()


# ---------- Wires ----------

func draw_wire(wire: Dictionary) -> void:
	var sf: float = _vis.scale_factor
	var p1 := Vector3(wire.x1, 0, wire.y1) * sf
	var p2 := Vector3(wire.x2, 0, wire.y2) * sf
	var direction := p2 - p1
	var length: float = direction.length()
	if length < 0.001:
		return

	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(length, 0.015, 0.015)
	mi.mesh = box

	var wire_label: String = wire.get("label", "")
	var net_key: String = ""
	if wire_label != "":
		net_key = wire_label.to_lower().replace("#", "")
		mi.set_meta("sim_net", net_key)

	# Labeled wires use the shared net material (set by build_net_lookup).
	# Unlabeled wires use the static wire material.
	if wire_label == "":
		mi.material_override = _vis._materials["wire"]

	mi.position = (p1 + p2) / 2.0
	mi.rotation.y = -atan2(direction.z, direction.x)

	# Physics body so raycasts can detect wire clicks.
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(length, 0.04, 0.04)
	col.shape = shape
	body.add_child(col)
	if net_key != "":
		body.set_meta("sim_net", net_key)
	mi.add_child(body)

	_vis.add_child(mi)

	draw_connection_dot(p1)
	draw_connection_dot(p2)

	if wire_label != "":
		var label := Label3D.new()
		label.text = wire_label
		label.position = (p1 + p2) / 2.0 + Vector3(0, 0.04, 0)
		label.font_size = 96
		label.pixel_size = 0.0005
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.modulate = Color(0.7, 0.7, 0.7)
		label.outline_size = 8
		label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		_vis.add_child(label)


func draw_connection_dot(pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.012
	sphere.height = 0.024
	mi.mesh = sphere
	mi.material_override = _vis._materials["wire"]
	mi.position = pos
	_vis.add_child(mi)


# ---------- Components ----------

func draw_component(comp: Dictionary, parser) -> void:
	var sf: float = _vis.scale_factor
	var pos := Vector3(comp.x, 0, comp.y) * sf
	var type: String = parser.get_component_type(comp.symbol)
	var rot: int  = comp.get("rotation", 0)
	var mirror: int = comp.get("mirror", 0)

	var sym_def: SymbolDefinition = get_sym_def(comp.symbol)
	var mat_type: String = sym_def.type if sym_def.type != "" else type
	var mat: StandardMaterial3D = VisMaterialFactory.get_material(_vis._materials, mat_type)

	var symbol := CircuitSymbol.new()
	symbol.setup(comp, sym_def, sf, mat)
	symbol.position = pos
	symbol.rotation.y = -deg_to_rad(rot * 90.0)
	if mirror:
		symbol.scale.x = -1.0
	_vis.add_child(symbol)

	var comp_label: String = comp.get("label", "")
	var label_text: String = comp_label if comp_label != "" else mat_type
	var label := Label3D.new()
	label.text = label_text
	label.position = pos + Vector3(0, VisMaterialFactory.get_label_height(mat_type), 0)
	label.font_size = 96
	label.pixel_size = 0.0005
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = mat.albedo_color
	label.outline_size = 8
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_vis.add_child(label)


# ---------- Net label propagation ----------

func _propagate_labels(wires: Array, components: Array) -> void:
	var label_sources: Dictionary = {}
	for comp: Dictionary in components:
		var comp_label: String = comp.get("label", "")
		if comp_label == "":
			continue
		var comp_type: String = comp.get("type", "")
		if comp_type not in ["label", "input_pin", "output_pin"]:
			continue
		label_sources[_coord_key(float(comp["x"]), float(comp["y"]))] = comp_label

	if label_sources.is_empty():
		return

	var ep_map: Dictionary = {}
	for i: int in range(wires.size()):
		var w: Dictionary = wires[i]
		for key: String in [_coord_key(float(w["x1"]), float(w["y1"])),
							 _coord_key(float(w["x2"]), float(w["y2"]))]:
			if not ep_map.has(key):
				ep_map[key] = []
			(ep_map[key] as Array).append(i)

	var wire_labels: Array = []
	wire_labels.resize(wires.size())
	wire_labels.fill("")
	var queue: Array = []

	for i: int in range(wires.size()):
		var w: Dictionary     = wires[i]
		var orig: String      = str(w.get("label", ""))
		for key: String in [_coord_key(float(w["x1"]), float(w["y1"])),
							 _coord_key(float(w["x2"]), float(w["y2"]))]:
			if not label_sources.has(key):
				continue
			var src: String = str(label_sources[key])
			if src != orig and wire_labels[i] == "":
				wire_labels[i] = src
				queue.append(i)

	if queue.is_empty():
		return

	var visited: Array = []
	visited.resize(wires.size())
	visited.fill(false)
	while queue.size() > 0:
		var idx: int = queue.pop_front()
		if visited[idx]:
			continue
		visited[idx] = true
		var lbl: String = str(wire_labels[idx])
		var w: Dictionary = wires[idx]
		for key: String in [_coord_key(float(w["x1"]), float(w["y1"])),
							 _coord_key(float(w["x2"]), float(w["y2"]))]:
			for ni: int in (ep_map.get(key, []) as Array):
				if visited[ni] or wire_labels[ni] != "":
					continue
				wire_labels[ni] = lbl
				queue.append(ni)

	for i: int in range(wires.size()):
		if wire_labels[i] != "":
			wires[i]["label"] = wire_labels[i]


func _coord_key(x: float, y: float) -> String:
	return str(roundi(x)) + "," + str(roundi(y))


# ---------- Symbol resolution ----------

func get_sym_def(symbol_name: String) -> SymbolDefinition:
	var sym_cache: Dictionary = _vis._sym_cache
	if sym_cache.has(symbol_name):
		return sym_cache[symbol_name]

	var path: String = resolve_sym_path(symbol_name)
	var sym_def: SymbolDefinition
	if path == "":
		sym_def = SymbolDefinition.new()
	else:
		sym_def = SymParser.parse(path)

	sym_cache[symbol_name] = sym_def
	return sym_def


func resolve_sym_path(symbol_name: String) -> String:
	var sym_search_paths: Array = _vis._sym_search_paths

	for search_path in sym_search_paths:
		var candidate: String = search_path + symbol_name
		if FileAccess.file_exists(candidate):
			return candidate

	var basename: String = symbol_name.get_file()
	for search_path in sym_search_paths:
		var candidate: String = search_path + basename
		if FileAccess.file_exists(candidate):
			return candidate

	var found: String = find_sym_recursive("res://symbols", basename)
	if found != "":
		return found

	if _vis._pdk_manifest != null and _vis._pdk_manifest.has_method("get_symbol_for_file"):
		var symbol: Dictionary = _vis._pdk_manifest.get_symbol_for_file(basename)
		if not symbol.is_empty():
			var pdk_filename := str(symbol.get("symbol_path", "")).get_file()
			for cached_name: String in [basename, pdk_filename, "%s.sym" % str(symbol.get("id", ""))]:
				if cached_name == "":
					continue
				var cached_path := "user://pdk_symbols/" + cached_name
				if FileAccess.file_exists(cached_path):
					return cached_path

	push_warning("SymParser: .sym file not found for: " + symbol_name)
	return ""


func find_sym_recursive(base_path: String, filename: String) -> String:
	var dir := DirAccess.open(base_path)
	if dir == null:
		return ""

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		var full_path: String = base_path + "/" + file_name
		if dir.current_is_dir():
			if file_name != "." and file_name != "..":
				var result: String = find_sym_recursive(full_path, filename)
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


# ---------- Net lookup ----------

## Builds _net_materials: one StandardMaterial3D per labeled net.
## The material starts dark; the visualizer updates emission_energy_multiplier
## each time a simulation_data_ready sample arrives.
func build_net_lookup() -> void:
	_vis._net_materials.clear()
	for child in _vis.get_children():
		if not (child is MeshInstance3D):
			continue
		if not child.has_meta("sim_net"):
			continue
		var net: String = str(child.get_meta("sim_net"))
		if not _vis._net_materials.has(net):
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.9, 0.9, 0.9)
			mat.emission_enabled = true
			mat.emission = Color(1.0, 0.95, 0.3)
			mat.emission_energy_multiplier = 0.0
			_vis._net_materials[net] = mat
		(child as MeshInstance3D).material_override = _vis._net_materials[net]

	print("VisSceneBuilder: %d labeled nets registered." % _vis._net_materials.size())
