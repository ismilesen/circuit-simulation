class_name CircuitSymbol
extends Node3D

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


func get_pin_position(pin_name: String) -> Vector3:
	if pin_positions.has(pin_name):
		return to_global(pin_positions[pin_name])
	return global_position


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
