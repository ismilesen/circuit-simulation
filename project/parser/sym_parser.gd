class_name SymParser


######################################################################################################
static func parse(path: String) -> SymbolDefinition:
	var symbol = SymbolDefinition.new()

	if not FileAccess.file_exists(path):
		push_error("SymParser: file not found: " + path)
		return symbol

	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("SymParser: cannot open: " + path)
		return symbol

	var all_lines: PackedStringArray = f.get_as_text().split("\n")
	f.close()

	var i := 0
	while i < all_lines.size():
		var raw_line: String = all_lines[i].strip_edges()

		if raw_line == "" or raw_line.begins_with("*"):
			i += 1
			continue

		if raw_line.begins_with("v ") or raw_line.begins_with("v{"):
			i = _skip_brace_block(all_lines, i)
			continue
		elif raw_line == "G {}" or raw_line == "V {}" or raw_line == "S {}" or raw_line == "E {}":
			i += 1
			continue
		elif raw_line.begins_with("G {") or raw_line.begins_with("V {") or raw_line.begins_with("S {") or raw_line.begins_with("E {"):
			i = _skip_brace_block(all_lines, i)
			continue
		elif raw_line.begins_with("K {"):
			i = _parse_k_block(all_lines, i, symbol)
			continue
		elif raw_line.begins_with("L "):
			_parse_line(raw_line, symbol)
		elif raw_line.begins_with("B "):
			_parse_box(raw_line, symbol)
		elif raw_line.begins_with("P "):
			_parse_polygon(raw_line, symbol)
		elif raw_line.begins_with("A "):
			_parse_arc(raw_line, symbol)
		elif raw_line.begins_with("T "):
			i = _parse_text(all_lines, i, symbol)
			continue

		i += 1

	return symbol


######################################################################################################
# Block skipping — advances past balanced braces.
static func _skip_brace_block(lines: PackedStringArray, start: int) -> int:
	var depth := 0
	var i := start
	while i < lines.size():
		for ch_idx in range(lines[i].length()):
			var ch = lines[i][ch_idx]
			if ch == "{":
				depth += 1
			elif ch == "}":
				depth -= 1
				if depth <= 0:
					return i + 1
		i += 1
	return i


######################################################################################################
# K block — extracts type= and template= fields.
static func _parse_k_block(lines: PackedStringArray, start: int, symbol: SymbolDefinition) -> int:
	var depth := 0
	var block := ""
	var i := start
	while i < lines.size():
		var raw: String = lines[i]
		for ch_idx in range(raw.length()):
			var ch = raw[ch_idx]
			if ch == "{":
				depth += 1
			elif ch == "}":
				depth -= 1
				if depth <= 0:
					block += raw.substr(0, ch_idx)
					_extract_k_fields(block, symbol)
					return i + 1
		block += raw + "\n"
		i += 1
	_extract_k_fields(block, symbol)
	return i


static func _extract_k_fields(block: String, symbol: SymbolDefinition) -> void:
	# Extract type=VALUE
	var type_re := RegEx.new()
	type_re.compile("type=(\\S+)")
	var m = type_re.search(block)
	if m:
		symbol.type = m.get_string(1)

	# Extract template="..." (may span multiple lines)
	var tmpl_start = block.find("template=\"")
	if tmpl_start >= 0:
		tmpl_start += 10  # skip 'template="'
		var tmpl_end = block.find("\"", tmpl_start)
		while tmpl_end > 0 and block[tmpl_end - 1] == "\\":
			tmpl_end = block.find("\"", tmpl_end + 1)
		if tmpl_end > 0:
			symbol.template = block.substr(tmpl_start, tmpl_end - tmpl_start)
		else:
			symbol.template = block.substr(tmpl_start)


######################################################################################################
# L layer x1 y1 x2 y2 {}
static func _parse_line(raw_line: String, symbol: SymbolDefinition) -> void:
	var parts := _split_before_brace(raw_line).split(" ", false)
	if parts.size() < 6:
		return

	var line := SymbolDefinition.Line.new()
	line.layer = parts[1].to_int()
	line.p1 = Vector2(parts[2].to_float(), parts[3].to_float())
	line.p2 = Vector2(parts[4].to_float(), parts[5].to_float())

	symbol.lines.append(line)


######################################################################################################
# B layer x1 y1 x2 y2 {name=D dir=inout ...}
static func _parse_box(raw_line: String, symbol: SymbolDefinition) -> void:
	var parts := _split_before_brace(raw_line).split(" ", false)
	if parts.size() < 6:
		return

	var box := SymbolDefinition.Box.new()
	box.layer = parts[1].to_int()
	box.p1 = Vector2(parts[2].to_float(), parts[3].to_float())
	box.p2 = Vector2(parts[4].to_float(), parts[5].to_float())

	var attrs = _parse_brace_attrs(raw_line)
	box.pin_name = attrs.get("name", "")
	box.dir = attrs.get("dir", "")

	symbol.boxes.append(box)


######################################################################################################
# P layer numpoints x1 y1 x2 y2 ... {fill=true}
static func _parse_polygon(raw_line: String, symbol: SymbolDefinition) -> void:
	var parts := _split_before_brace(raw_line).split(" ", false)
	if parts.size() < 4:
		return

	var polygon := SymbolDefinition.Polygon.new()
	polygon.layer = int(parts[1])
	var numpoints = int(parts[2])
	polygon.points = []
	for j in range(numpoints):
		var idx = 3 + j * 2
		if idx + 1 >= parts.size():
			break
		polygon.points.append(Vector2(parts[idx].to_float(), parts[idx + 1].to_float()))

	var attrs = _parse_brace_attrs(raw_line)
	if attrs.get("fill", "false") == "true":
		polygon.fill = true

	symbol.polygons.append(polygon)


######################################################################################################
# A layer cx cy radius start_angle sweep_angle {}
static func _parse_arc(raw_line: String, symbol: SymbolDefinition) -> void:
	var parts := _split_before_brace(raw_line).split(" ", false)
	if parts.size() < 7:
		return

	var arc := SymbolDefinition.Arc.new()
	arc.layer = parts[1].to_int()
	arc.cx = parts[2].to_float()
	arc.cy = parts[3].to_float()
	arc.radius = parts[4].to_float()
	arc.start_angle = parts[5].to_float()
	arc.sweep_angle = parts[6].to_float()

	symbol.arcs.append(arc)


######################################################################################################
# T {text} x y rot mirror sx sy {layer=N}
# Text content is in braces and may span multiple lines.
static func _parse_text(lines: PackedStringArray, start: int, symbol: SymbolDefinition) -> int:
	var line: String = lines[start]

	var first_open = line.find("{")
	if first_open < 0:
		return start + 1

	# Find matching close brace for text content
	var text_content := ""
	var depth := 0
	var scan_line := start
	var scan_pos: int = first_open

	while scan_line < lines.size():
		var scan_str: String = lines[scan_line]
		var ch_start = scan_pos if scan_line == start else 0
		for ci in range(ch_start, scan_str.length()):
			var ch = scan_str[ci]
			if ch == "{":
				depth += 1
			elif ch == "}":
				depth -= 1
				if depth == 0:
					# Extract text between the outer braces
					if scan_line == start:
						text_content = scan_str.substr(first_open + 1, ci - first_open - 1)
					else:
						text_content = lines[start].substr(first_open + 1) + "\n"
						for ml in range(start + 1, scan_line):
							text_content += lines[ml] + "\n"
						text_content += scan_str.substr(0, ci)

					# Parse the rest of the line after the closing brace
					var remainder = scan_str.substr(ci + 1).strip_edges()
					var tokens = remainder.split(" ", false)

					var t := SymbolDefinition.Text.new()
					t.text = text_content
					if tokens.size() >= 2:
						t.x = tokens[0].to_float()
						t.y = tokens[1].to_float()
					if tokens.size() >= 3:
						t.rotation = tokens[2].to_int()
					if tokens.size() >= 4:
						t.mirror = tokens[3].to_int()
					if tokens.size() >= 5:
						t.size_x = tokens[4].to_float()
					if tokens.size() >= 6:
						t.size_y = tokens[5].to_float()

					# Check for {layer=N} at end
					var last_brace = remainder.rfind("{")
					if last_brace >= 0:
						var attr_str = remainder.substr(last_brace)
						var layer_attrs = _parse_brace_attrs("T " + attr_str)
						if layer_attrs.has("layer"):
							t.layer = layer_attrs["layer"].to_int()

					symbol.texts.append(t)
					return scan_line + 1
		scan_line += 1

	return start + 1


######################################################################################################
# Attribute helpers

## Extracts key=value pairs from the last {...} on a line.
static func _parse_brace_attrs(line: String) -> Dictionary:
	var last_open = line.rfind("{")
	var last_close = line.rfind("}")
	if last_open < 0 or last_close <= last_open:
		return {}

	var inside = line.substr(last_open + 1, last_close - last_open - 1).strip_edges()
	if inside.is_empty():
		return {}

	var result: Dictionary = {}
	var re := RegEx.new()
	re.compile("(\\w+)=(\\S+)")
	for match in re.search_all(inside):
		result[match.get_string(1)] = match.get_string(2)
	return result


## Returns the portion of a line before the first '{'.
static func _split_before_brace(line: String) -> String:
	var idx = line.find("{")
	if idx >= 0:
		return line.substr(0, idx).strip_edges()
	return line.strip_edges()
