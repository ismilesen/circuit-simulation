class_name VisSceneBuilder
extends RefCounted

## Untyped reference to the main SchVis3D Node3D (avoids circular class dependency).
var _vis


func _init(vis) -> void:
	_vis = vis


# ---------- Top-level circuit draw ----------

func draw_circuit(parser, floor: MeshInstance3D) -> void:
	# Clear previous children (keep the floor).
	for child in _vis.get_children():
		if child == floor:
			continue
		child.queue_free()

	# Reset all state that references freed nodes.
	_vis._wire_cursors.clear()
	_vis._transistor_materials.clear()
	_vis._transistor_nodes.clear()
	_vis._transistor_cursors.clear()
	_vis._transistor_cursor_map.clear()
	_vis._gate_cursors.clear()
	_vis._gate_cursor_map.clear()
	_vis._input_positions.clear()
	_vis._net_cascade.clear()

	var split_wires: Array = VisGeomUtils.split_wires_at_junctions(Array(parser.wires))
	_propagate_labels(split_wires, Array(parser.components))
	for wire: Dictionary in split_wires:
		draw_wire(wire)

	for comp in parser.components:
		draw_component(comp, parser)

	build_net_lookup()
	build_pin_net_lookup()
	build_wire_graph()

	# If SPICE was already paired before this schematic loaded, rebuild cursors now
	# so they reference the freshly created CircuitSymbol nodes.
	if not _vis._transistor_data.is_empty():
		_vis._cursor_builder.build_transistor_cursors()


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
	if wire_label != "":
		mi.set_meta("sim_net", wire_label.to_lower().replace("#", ""))

	var wire_shader: ShaderMaterial = null
	if wire_label != "":
		wire_shader = ShaderMaterial.new()
		wire_shader.shader = _vis._WIRE_FILL_SHADER
		wire_shader.set_shader_parameter("wire_length",   length)
		wire_shader.set_shader_parameter("fill_fraction", 1.0)
		wire_shader.set_shader_parameter("fill_from_p1",  1)
		wire_shader.set_shader_parameter("color_behind",  Color.BLACK)
		wire_shader.set_shader_parameter("color_ahead",   Color.BLACK)
		wire_shader.set_shader_parameter("energy_behind", 0.0)
		wire_shader.set_shader_parameter("energy_ahead",  0.0)
		mi.material_override = wire_shader
	else:
		mi.material_override = _vis._materials["wire"]

	mi.position = (p1 + p2) / 2.0
	mi.rotation.y = -atan2(direction.z, direction.x)
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

		# Cursor node kept for wire-picking metadata but never made visible.
		var cursor := MeshInstance3D.new()
		var cursor_mat := StandardMaterial3D.new()
		cursor_mat.emission_enabled = true
		cursor.material_override = cursor_mat
		cursor.visible = false
		cursor.position = p1
		_vis.add_child(cursor)
		_vis._wire_cursors.append({
			"cursor":      cursor,
			"cursor_mat":  cursor_mat,
			"wire_shader": wire_shader,
			"p1":          p1,
			"p2":          p2,
			"net":         wire_label.to_lower().replace("#", ""),
			"trigger_t":   -999.0,
			"trigger_dir": 1.0,
			"color_old":   Color.BLACK,
			"color_new":   Color.BLACK,
			"energy_old":  0.0,
			"energy_new":  0.0,
		})


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

	var comp_name: String = comp.get("name", "")
	# Use both C++ type and sym K-block mat_type — C++ may return "unknown" for some
	# transistor sym files even though mat_type correctly reads "nmos"/"pmos" from K block.
	var is_transistor: bool = (type == "pmos" or type == "nmos" or mat_type == "pmos" or mat_type == "nmos")
	if is_transistor and comp_name != "":
		mat = mat.duplicate() as StandardMaterial3D
		_vis._transistor_materials[comp_name] = mat

	var symbol := CircuitSymbol.new()
	symbol.setup(comp, sym_def, sf, mat)
	symbol.position = pos
	symbol.rotation.y = -deg_to_rad(rot * 90.0)
	if mirror:
		symbol.scale.x = -1.0
	_vis.add_child(symbol)

	if comp_name != "" and is_transistor:
		_vis._transistor_nodes[comp_name] = symbol

	if type == "ipin" or type == "input_pin":
		_vis._input_positions.append(pos)

	# "primitive" sym files carry their own T-line texts (symname, name, pin labels)
	# rendered by CircuitSymbol._add_sym_text — skip the external billboard label to
	# avoid duplication.
	if mat_type == "primitive":
		return

	var comp_label: String = comp.get("label", "")
	var inst_name: String  = comp.get("name", "")
	var sym_base: String   = str(comp.get("symbol", "")).get_file().get_basename()
	var label_text: String
	if comp_label != "":
		label_text = comp_label
	elif sym_base != "" and inst_name != "":
		label_text = sym_base + "\n" + inst_name
	elif sym_base != "":
		label_text = sym_base
	else:
		label_text = mat_type
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


# ---------- Net Label Propagation ----------

## Fixes wire labels that conflict with a lab_pin/ipin/opin component at the
## same endpoint position.  Only seeds BFS from actual conflicts; schematics
## with correct labels are untouched (function returns immediately).
func _propagate_labels(wires: Array, components: Array) -> void:
	# Collect label sources: "x,y" → net_name from placed label components.
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

	# Build endpoint map: "x,y" → Array of wire indices.
	var ep_map: Dictionary = {}
	for i: int in range(wires.size()):
		var w: Dictionary = wires[i]
		for key: String in [_coord_key(float(w["x1"]), float(w["y1"])),
							 _coord_key(float(w["x2"]), float(w["y2"]))]:
			if not ep_map.has(key):
				ep_map[key] = []
			(ep_map[key] as Array).append(i)

	# Seed BFS ONLY where a wire's label conflicts with the lab_pin label at its endpoint.
	# If all labels are already correct no seeds are added and we return early.
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
			if src != orig and wire_labels[i] == "":   # conflict detected
				wire_labels[i] = src
				queue.append(i)

	if queue.is_empty():
		return  # all labels consistent — nothing to fix

	# BFS: spread the corrected label to connected wires that currently carry the wrong label.
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

	# Apply corrections.
	for i: int in range(wires.size()):
		if wire_labels[i] != "":
			wires[i]["label"] = wire_labels[i]


func _coord_key(x: float, y: float) -> String:
	return str(roundi(x)) + "," + str(roundi(y))


# ---------- Symbol Resolution ----------

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


# ---------- Net & Wire Graph ----------

## Rebuilds the net-name → mesh list and assigns unique materials per net.
func build_net_lookup() -> void:
	_vis._net_nodes.clear()
	_vis._net_materials.clear()
	_vis._anim_active = false
	for child in _vis.get_children():
		if not (child is MeshInstance3D):
			continue
		if not child.has_meta("sim_net"):
			continue
		var net: String = str(child.get_meta("sim_net"))
		if not _vis._net_nodes.has(net):
			_vis._net_nodes[net] = []
			# Neutral gray until simulation data arrives; unmatched wires stay dark.
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.9, 0.9, 0.9)
			mat.emission_enabled = true
			mat.emission = Color(0.0, 0.0, 0.0)
			mat.emission_energy_multiplier = 0.0
			_vis._net_materials[net] = mat
		_vis._net_nodes[net].append(child)
		# Labeled wires already carry a ShaderMaterial; don't overwrite.
		if not (child.material_override is ShaderMaterial):
			(child as MeshInstance3D).material_override = _vis._net_materials[net]


## Matches each primitive-symbol pin sphere to its connected wire net, then
## registers it in _net_nodes so _update_wire_colors animates it automatically.
func build_pin_net_lookup() -> void:
	var sf: float = _vis.scale_factor

	# Build world-position → net map from labeled wire cursor endpoints.
	var endpoint_nets: Dictionary = {}
	for wd: Dictionary in _vis._wire_cursors:
		var net: String = str(wd["net"])
		endpoint_nets[_vec3_key(wd["p1"])] = net
		endpoint_nets[_vec3_key(wd["p2"])] = net

	# Walk every CircuitSymbol child and register its pin dots.
	# Skip transistors — they use _transistor_materials, not _net_materials.
	for child in _vis.get_children():
		if not (child is CircuitSymbol):
			continue
		var sym: CircuitSymbol = child as CircuitSymbol
		var sym_type: String = sym.sym_def.type if sym.sym_def != null else ""
		if sym_type == "nmos" or sym_type == "pmos":
			continue
		for pin_name: String in sym.pin_meshes.keys():
			var world_pos: Vector3 = sym.get_pin_position(pin_name)
			var key: String = _vec3_key(world_pos)
			if not endpoint_nets.has(key):
				continue
			var net: String = str(endpoint_nets[key])
			var dot: MeshInstance3D = sym.pin_meshes[pin_name] as MeshInstance3D

			# Create net material if this net had no labeled wire segment (rare).
			if not _vis._net_materials.has(net):
				var mat := StandardMaterial3D.new()
				mat.albedo_color = Color(0.9, 0.9, 0.9)
				mat.emission_enabled = true
				mat.emission = Color.BLACK
				mat.emission_energy_multiplier = 0.0
				_vis._net_materials[net] = mat
				_vis._net_nodes[net] = []

			# Share the net's StandardMaterial so the anim player colors it for free.
			dot.material_override = _vis._net_materials[net]
			_vis._net_nodes[net].append(dot)


static func _vec3_key(v: Vector3) -> String:
	return "%.3f,%.3f,%.3f" % [v.x, v.y, v.z]


func build_wire_graph() -> void:
	_vis._net_cascade = WireGraph.build(_vis._wire_cursors, _vis._input_positions, _vis.scale_factor)
