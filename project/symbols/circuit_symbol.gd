class_name CircuitSymbol
extends Node3D

signal symbol_clicked(comp_data: Dictionary)

## Data-driven 3D circuit symbol built from a SymbolDefinition.
##
## Usage:
##   var symbol = CircuitSymbol.new()
##   symbol.setup(comp_dict, sym_def, scale, material)
##   add_child(symbol)

## The raw component dictionary from SchParser.
var comp_data: Dictionary = {}

## The parsed symbol definition.
var sym_def: SymbolDefinition

## Pin positions in local space, keyed by pin name (e.g. "D", "G", "S").
var pin_positions: Dictionary = {}

## Thickness of line-segment bars.
const BAR: float = 0.012

## Arc rendering resolution (segments per full circle).
const ARC_SEGMENTS: int = 16


func setup(comp: Dictionary, definition: SymbolDefinition, scale: float, mat: StandardMaterial3D) -> void:
	comp_data = comp
	sym_def = definition
	var compact_mos_pin_grid := _uses_compact_mos_pin_grid(definition)

	# Lines -> thin BoxMesh bars
	for line in definition.lines:
		_add_line_mesh(line, scale, mat, compact_mos_pin_grid)

	# Arcs -> segmented line bars (PMOS bubble, etc.)
	for arc in definition.arcs:
		_add_arc_mesh(arc, scale, mat, compact_mos_pin_grid)

	# Polygons -> triangle meshes (arrows, fills)
	for poly in definition.polygons:
		_add_polygon_mesh(poly, scale, mat, compact_mos_pin_grid)

	# Boxes/Pins -> compute local positions
	for box in definition.boxes:
		if box.pin_name != "":
			var c := _schematic_point(box.center(), compact_mos_pin_grid)
			pin_positions[box.pin_name] = Vector3(c.x * scale, 0, c.y * scale)

	# If the symbol has no visual geometry at all, add a small dot marker
	var has_geometry = definition.lines.size() > 0 \
		or definition.arcs.size() > 0 \
		or definition.polygons.size() > 0
	if not has_geometry:
		var mi = MeshInstance3D.new()
		var sphere = SphereMesh.new()
		sphere.radius = 3.0 * scale
		sphere.height = 6.0 * scale
		mi.mesh = sphere
		mi.material_override = mat
		add_child(mi)

	if _is_clickable_button(comp):
		_add_click_area(scale, compact_mos_pin_grid)


func get_pin_position(pin_name: String) -> Vector3:
	if pin_positions.has(pin_name):
		return to_global(pin_positions[pin_name])
	return global_position


func _is_clickable_button(comp: Dictionary) -> bool:
	return str(comp.get("type", "")).to_lower() == "button" \
		or str(comp.get("symbol", "")).to_lower().find("button") != -1


func _add_click_area(scale: float, compact_mos_pin_grid: bool) -> void:
	var bounds := _symbol_bounds(compact_mos_pin_grid)
	if bounds.is_empty():
		return

	var min_p: Vector2 = bounds["min"]
	var max_p: Vector2 = bounds["max"]
	var center := (min_p + max_p) / 2.0
	var size := max_p - min_p
	var padding := 18.0

	var area := Area3D.new()
	area.name = "ClickArea"
	area.input_ray_pickable = true
	area.collision_layer = 1
	area.collision_mask = 0
	area.position = Vector3(center.x * scale, 0.04, center.y * scale)

	var shape := BoxShape3D.new()
	shape.size = Vector3(maxf(size.x + padding, 20.0) * scale, 0.12, maxf(size.y + padding, 20.0) * scale)

	var collision := CollisionShape3D.new()
	collision.shape = shape
	area.add_child(collision)
	area.input_event.connect(_on_click_area_input)
	add_child(area)


func _symbol_bounds(compact_mos_pin_grid: bool) -> Dictionary:
	var bounds := {
		"has_point": false,
		"min": Vector2(1.0e20, 1.0e20),
		"max": Vector2(-1.0e20, -1.0e20),
	}

	for line in sym_def.lines:
		_accum_bound_point(bounds, line.p1, compact_mos_pin_grid)
		_accum_bound_point(bounds, line.p2, compact_mos_pin_grid)
	for box in sym_def.boxes:
		_accum_bound_point(bounds, box.p1, compact_mos_pin_grid)
		_accum_bound_point(bounds, box.p2, compact_mos_pin_grid)
	for poly in sym_def.polygons:
		for p: Vector2 in poly.points:
			_accum_bound_point(bounds, p, compact_mos_pin_grid)
	for arc in sym_def.arcs:
		_accum_bound_point(bounds, Vector2(arc.cx - arc.radius, arc.cy - arc.radius), compact_mos_pin_grid)
		_accum_bound_point(bounds, Vector2(arc.cx + arc.radius, arc.cy + arc.radius), compact_mos_pin_grid)

	if not bool(bounds["has_point"]):
		return {}
	return {"min": bounds["min"], "max": bounds["max"]}


func _accum_bound_point(bounds: Dictionary, raw_point: Vector2, compact_mos_pin_grid: bool) -> void:
	var p := _schematic_point(raw_point, compact_mos_pin_grid)
	var min_p: Vector2 = bounds["min"]
	var max_p: Vector2 = bounds["max"]
	min_p.x = minf(min_p.x, p.x)
	min_p.y = minf(min_p.y, p.y)
	max_p.x = maxf(max_p.x, p.x)
	max_p.y = maxf(max_p.y, p.y)
	bounds["min"] = min_p
	bounds["max"] = max_p
	bounds["has_point"] = true


func _on_click_area_input(_camera: Node, event: InputEvent, _event_position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			symbol_clicked.emit(comp_data)


# ---------- Geometry Builders ----------

func _add_line_mesh(
		line: SymbolDefinition.Line,
		scale: float,
		mat: StandardMaterial3D,
		compact_mos_pin_grid: bool) -> void:
	var p1 := _schematic_point(line.p1, compact_mos_pin_grid)
	var p2 := _schematic_point(line.p2, compact_mos_pin_grid)
	var from = Vector3(p1.x * scale, 0, p1.y * scale)
	var to = Vector3(p2.x * scale, 0, p2.y * scale)

	var mid = (from + to) / 2.0
	var dir = to - from
	var length = dir.length()
	if length < 0.0001:
		return

	var mi = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(length, BAR, BAR)
	mi.mesh = box
	mi.material_override = mat
	mi.position = mid
	mi.rotation.y = -atan2(dir.z, dir.x)
	add_child(mi)


func _add_arc_mesh(
		arc: SymbolDefinition.Arc,
		scale: float,
		mat: StandardMaterial3D,
		compact_mos_pin_grid: bool) -> void:
	var start_deg: float = arc.start_angle
	var sweep_deg: float = arc.sweep_angle

	# Render arc as connected line segments (thin bars)
	var segment_count: int = maxi(4, int(abs(sweep_deg) / 360.0 * ARC_SEGMENTS))
	var step_deg: float = sweep_deg / segment_count

	var prev_point := Vector3.ZERO
	for i in range(segment_count + 1):
		var angle_deg = start_deg + step_deg * i
		var angle_rad = deg_to_rad(angle_deg)
		var local_point := Vector2(
			arc.cx + cos(angle_rad) * arc.radius,
			arc.cy + sin(angle_rad) * arc.radius)
		var schematic_point := _schematic_point(local_point, compact_mos_pin_grid)
		var point = Vector3(schematic_point.x * scale, 0, schematic_point.y * scale)

		if i > 0:
			var mid = (prev_point + point) / 2.0
			var dir = point - prev_point
			var length = dir.length()
			if length > 0.0001:
				var mi = MeshInstance3D.new()
				var box = BoxMesh.new()
				box.size = Vector3(length, BAR, BAR)
				mi.mesh = box
				mi.material_override = mat
				mi.position = mid
				mi.rotation.y = -atan2(dir.z, dir.x)
				add_child(mi)

		prev_point = point


func _add_polygon_mesh(
		poly: SymbolDefinition.Polygon,
		scale: float,
		mat: StandardMaterial3D,
		compact_mos_pin_grid: bool) -> void:
	if poly.points.size() < 2:
		return

	if poly.fill and poly.points.size() >= 3:
		_add_filled_polygon(poly.points, scale, mat, compact_mos_pin_grid)
	else:
		# Outline only -> line segments between consecutive points
		for i in range(poly.points.size() - 1):
			var p1: Vector2 = _schematic_point(poly.points[i], compact_mos_pin_grid)
			var p2: Vector2 = _schematic_point(poly.points[i + 1], compact_mos_pin_grid)
			var from = Vector3(p1.x * scale, 0, p1.y * scale)
			var to = Vector3(p2.x * scale, 0, p2.y * scale)
			var mid = (from + to) / 2.0
			var dir = to - from
			var length = dir.length()
			if length > 0.0001:
				var mi = MeshInstance3D.new()
				var box = BoxMesh.new()
				box.size = Vector3(length, BAR, BAR)
				mi.mesh = box
				mi.material_override = mat
				mi.position = mid
				mi.rotation.y = -atan2(dir.z, dir.x)
				add_child(mi)


func _add_filled_polygon(
		points: Array[Vector2],
		scale: float,
		mat: StandardMaterial3D,
		compact_mos_pin_grid: bool) -> void:
	# Fan triangulation from first point (works for convex polygons like arrows)
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()

	for i in range(1, points.size() - 1):
		var p0: Vector2 = _schematic_point(points[0], compact_mos_pin_grid)
		var p1: Vector2 = _schematic_point(points[i], compact_mos_pin_grid)
		var p2: Vector2 = _schematic_point(points[i + 1], compact_mos_pin_grid)

		vertices.append(Vector3(p0.x * scale, 0, p0.y * scale))
		vertices.append(Vector3(p1.x * scale, 0, p1.y * scale))
		vertices.append(Vector3(p2.x * scale, 0, p2.y * scale))

		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)

	if vertices.size() == 0:
		return

	var arr_mesh = ArrayMesh.new()
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi = MeshInstance3D.new()
	mi.mesh = arr_mesh
	mi.material_override = mat
	add_child(mi)

	# Also add bottom face so polygon is visible from below
	var flipped_normals = PackedVector3Array()
	var flipped_verts = PackedVector3Array()
	for i in range(0, vertices.size(), 3):
		flipped_verts.append(vertices[i])
		flipped_verts.append(vertices[i + 2])
		flipped_verts.append(vertices[i + 1])
		flipped_normals.append(Vector3.DOWN)
		flipped_normals.append(Vector3.DOWN)
		flipped_normals.append(Vector3.DOWN)

	var arr_mesh2 = ArrayMesh.new()
	var arrays2 = []
	arrays2.resize(Mesh.ARRAY_MAX)
	arrays2[Mesh.ARRAY_VERTEX] = flipped_verts
	arrays2[Mesh.ARRAY_NORMAL] = flipped_normals
	arr_mesh2.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays2)

	var mi2 = MeshInstance3D.new()
	mi2.mesh = arr_mesh2
	mi2.material_override = mat
	add_child(mi2)


func _uses_compact_mos_pin_grid(definition: SymbolDefinition) -> bool:
	var symbol_type := definition.type.to_lower()
	if symbol_type not in ["pfet", "nfet", "pmos", "nmos"]:
		return false

	var pins := {}
	for box in definition.boxes:
		if box.pin_name != "":
			pins[box.pin_name.to_upper()] = box.center()

	if not (pins.has("G") and pins.has("D") and pins.has("S")):
		return false

	var gate: Vector2 = pins["G"]
	var drain: Vector2 = pins["D"]
	var source: Vector2 = pins["S"]
	var compact_gate := is_equal_approx(gate.x, -20.0) and is_equal_approx(gate.y, 0.0)
	var compact_drain_source := is_equal_approx(drain.x, 20.0) \
		and is_equal_approx(source.x, 20.0) \
		and is_equal_approx(absf(drain.y), 30.0) \
		and is_equal_approx(absf(source.y), 30.0)
	return compact_gate and compact_drain_source


func _schematic_point(point: Vector2, compact_mos_pin_grid: bool) -> Vector2:
	if not compact_mos_pin_grid:
		return point

	return Vector2(point.x - 20.0, point.y * (4.0 / 3.0))
