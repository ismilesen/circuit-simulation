extends Control

@export var simulator_path: NodePath = NodePath("..")
const UPLOAD_DIR := "user://uploads"

signal schematic_requested(path: String)

var NETLIST_EXTS: PackedStringArray = PackedStringArray(["spice", "cir", "net", "txt"])
var XSCHEM_EXTS: PackedStringArray = PackedStringArray(["sch"])

@onready var upload_button: Button = $Margin/VBox/ControlsRow/UploadButton
@onready var run_button: Button = $Margin/VBox/ControlsRow/RunButton
@onready var clear_button: Button = $Margin/VBox/ControlsRow/ClearButton
@onready var staged_list: ItemList = $Margin/VBox/StagedList
@onready var status_prefix: Label = $Margin/VBox/StatusRow/StatusPrefix
@onready var status_value: Label = $Margin/VBox/StatusRow/StatusValue
@onready var output_box: RichTextLabel = $Margin/VBox/Output
@onready var file_dialog: FileDialog = $FileDialog

@onready var drop_zone: PanelContainer = $Margin/VBox/DropZone
@onready var drop_title: Label = $Margin/VBox/DropZone/DropZoneMargin/DropZoneVBox/DropTitle
@onready var drop_hint: Label = $Margin/VBox/DropZone/DropZoneMargin/DropZoneVBox/DropHint

# Each entry:
# { "display": String, "user_path": String, "bytes": int, "kind": String, "ext": String }
var staged: Array[Dictionary] = []
var _sim_signal_connected: bool = false
var _sim: Node = null

# --- Aesthetic theme state (light, “Microsoft-esque”) ---
var _t: Theme = null
var _sb_panel: StyleBoxFlat = null
var _sb_panel_hover: StyleBoxFlat = null
var _sb_drop_idle: StyleBoxFlat = null
var _sb_drop_flash: StyleBoxFlat = null

enum StatusTone { IDLE, OK, WARN, ERROR }

func _on_native_file_selected(path: String) -> void:
	if path.strip_edges() == "":
		return
	var added: int = int(_stage_native_file(path))
	if added > 0:
		_flash_drop_zone()
		_refresh_status("native: staged 1 file", StatusTone.OK)


func _ready() -> void:
	_apply_light_theme()
	_ensure_upload_dir()

	upload_button.pressed.connect(_on_upload_pressed)
	run_button.pressed.connect(_on_run_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	staged_list.item_activated.connect(_on_staged_item_activated)
	file_dialog.file_selected.connect(_on_native_file_selected)
	file_dialog.files_selected.connect(_on_native_files_selected)

	# OS drag-and-drop (IMPORTANT):
	# Docs show connecting via the main viewport for file drops. :contentReference[oaicite:2]{index=2}
	# On Windows, when running from the editor, drag-drop can be intercepted by the editor UI,
	# so the most reliable test is in an exported .exe.
	if not OS.has_feature("web"):
		if get_viewport() != null:
			if not get_viewport().files_dropped.is_connected(_on_os_files_dropped):
				get_viewport().files_dropped.connect(_on_os_files_dropped)

		var w: Window = get_window()
		if w != null:
			if not w.files_dropped.is_connected(_on_os_files_dropped):
				w.files_dropped.connect(_on_os_files_dropped)

		if Engine.is_editor_hint():
			_log("[color=yellow]Note:[/color] In the editor, Windows drag-drop often targets the editor window instead of the running game. Export and run the .exe to test OS drag-drop reliably.")

	_sim = _resolve_simulator()
	_refresh_status("idle", StatusTone.IDLE)

	if OS.has_feature("web"):
		var has_bridge: bool = _web_eval_bool("typeof window.godotUploadOpenPicker === 'function' && Array.isArray(window.godotUploadQueue)")
		if has_bridge:
			_log("[color=lime]Web upload bridge detected.[/color]")
		else:
			_log("[color=yellow]Web upload bridge not detected yet. Ensure upload_bridge.js is included in the exported HTML.[/color]")

func _process(_delta: float) -> void:
	if OS.has_feature("web"):
		_poll_web_queue()

# -------------------------------------------------------------------
# Upload flows
# -------------------------------------------------------------------

func _on_upload_pressed() -> void:
	if OS.has_feature("web"):
		var ok: bool = _web_eval_bool("typeof window.godotUploadOpenPicker === 'function'")
		if not ok:
			_set_error("Web picker not available. Did you include res://web/shell/upload_bridge.js in the export HTML?")
			return
		JavaScriptBridge.eval("window.godotUploadOpenPicker()", true)
		_refresh_status("web: picker opened", StatusTone.WARN)
	else:
		file_dialog.popup_centered_ratio(0.8)
		_refresh_status("native: file dialog opened", StatusTone.WARN)

func _on_native_files_selected(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var added: int = 0
	for p: String in paths:
		added += int(_stage_native_file(p))
	_flash_drop_zone()
	_refresh_status("native: staged %d file(s)" % added, StatusTone.OK)

func _on_os_files_dropped(files: PackedStringArray) -> void:
	# OS-level drag-and-drop from Explorer/Finder/etc.
	# Note: only works with native windows (main window / non-embedded). :contentReference[oaicite:3]{index=3}
	if OS.has_feature("web"):
		return
	if files.is_empty():
		return

	# Defensive: sometimes editor passes weird strings, ignore empties.
	var added: int = 0
	for p: String in files:
		if p.strip_edges() == "":
			continue
		added += int(_stage_native_file(p))

	if added > 0:
		_flash_drop_zone()
		_refresh_status("native: dropped %d file(s)" % added, StatusTone.OK)
	else:
		_refresh_status("native: drop received, no valid files", StatusTone.WARN)

func _stage_native_file(src_path: String) -> bool:
	if not FileAccess.file_exists(src_path):
		_set_error("File does not exist: %s" % src_path)
		return false

	var src: FileAccess = FileAccess.open(src_path, FileAccess.READ)
	if src == null:
		_set_error("Failed to open: %s" % src_path)
		return false

	var bytes: PackedByteArray = src.get_buffer(src.get_length())
	src.close()

	var base_name: String = src_path.get_file()
	return _stage_bytes(base_name, bytes)

func _stage_bytes(original_name: String, bytes: PackedByteArray) -> bool:
	_ensure_upload_dir()

	var safe_name: String = _sanitize_filename(original_name)
	var user_path: String = "%s/%s" % [UPLOAD_DIR, safe_name]
	user_path = _avoid_collision(user_path)

	var f: FileAccess = FileAccess.open(user_path, FileAccess.WRITE)
	if f == null:
		_set_error("Failed to write into %s" % user_path)
		return false
	f.store_buffer(bytes)
	f.close()

	var ext: String = safe_name.get_extension().to_lower()
	var kind: String = _detect_kind(ext, bytes)

	var entry: Dictionary = {
		"display": safe_name,
		"user_path": user_path,
		"bytes": bytes.size(),
		"kind": kind,
		"ext": ext
	}
	staged.append(entry)
	_rebuild_list()
	_log("[color=lightblue]Staged[/color] %s  →  %s" % [safe_name, user_path])
	return true

# -------------------------------------------------------------------
# Web queue polling (JS -> Godot)
# -------------------------------------------------------------------

func _poll_web_queue() -> void:
	var raw: Variant = JavaScriptBridge.eval("""
		(() => {
			if (!Array.isArray(window.godotUploadQueue) || window.godotUploadQueue.length === 0) return null;
			const item = window.godotUploadQueue.shift();
			return JSON.stringify(item);
		})()
	""", true)

	if raw == null:
		return

	var json: String = str(raw)
	if json.is_empty():
		return

	var parsed: Variant = JSON.parse_string(json)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		_set_error("Web upload: failed to parse queued JSON.")
		return

	var d: Dictionary = parsed as Dictionary
	if not d.has("name") or not d.has("base64"):
		_set_error("Web upload: queue item missing fields.")
		return

	if d.has("error") and str(d["error"]) != "":
		_set_error("Web upload error for %s: %s" % [str(d.get("name", "unknown")), str(d["error"])])
		return

	var filename: String = str(d.get("name", "upload.bin"))
	var b64: String = str(d.get("base64", ""))
	var bytes: PackedByteArray = Marshalls.base64_to_raw(b64)

	var ok: bool = _stage_bytes(filename, bytes)
	if ok:
		_flash_drop_zone()
		_refresh_status("web: staged %s (%s)" % [filename, _human_size(bytes.size())], StatusTone.OK)

func _web_eval_bool(expr: String) -> bool:
	var v: Variant = JavaScriptBridge.eval("(%s) ? true : false" % expr, true)
	return bool(v)

# -------------------------------------------------------------------
# Run simulation
# -------------------------------------------------------------------

func _on_run_pressed() -> void:
	if staged.is_empty():
		_set_error("No staged files. Upload a file first.")
		return

	var idx: PackedInt32Array = staged_list.get_selected_items()
	if idx.is_empty():
		_set_error("Select a staged file in the list first.")
		return

	var entry: Dictionary = staged[int(idx[0])]

	# .sch files -> visualize instead of simulate
	if _is_schematic_entry(entry):
		var sch_path: String = str(entry["user_path"])
		_log("[color=lime]Visualizing schematic:[/color] %s" % str(entry["display"]))
		_refresh_status("loading schematic…", StatusTone.WARN)
		schematic_requested.emit(sch_path)
		_refresh_status("schematic loaded", StatusTone.OK)
		return

	if not _is_netlist_entry(entry):
		_set_error("Selected file is not a supported type. Choose .sch or .spice/.cir/.net/.txt.")
		return

	if OS.has_feature("web"):
		_set_error("Web build: ngspice runtime is not supported yet, staging works though.")
		return

	_sim = _resolve_simulator()
	if _sim == null:
		_set_error("Could not find CircuitSimulator node. Ensure the harness instanced it, or set simulator_path.")
		return

	if not _sim.has_method("initialize_ngspice"):
		_set_error("Resolved node lacks initialize_ngspice(). Wrong simulator_path?")
		return

	if (not _sim_signal_connected) and _sim.has_signal("simulation_finished"):
		_sim.connect("simulation_finished", Callable(self, "_on_sim_finished"))
		_sim_signal_connected = true

	_refresh_status("native: initializing ngspice…", StatusTone.WARN)
	var init_ok: Variant = _sim.call("initialize_ngspice")
	if not bool(init_ok):
		_set_error("initialize_ngspice() returned false.")
		return

	_refresh_status("native: loading netlist…", StatusTone.WARN)
	var godot_path: String = str(entry["user_path"]) # user://uploads/...
	var os_path: String = ProjectSettings.globalize_path(godot_path)
	_sim.call("load_netlist", os_path)

	_refresh_status("native: running simulation…", StatusTone.WARN)
	_sim.call("run_simulation")

func _on_sim_finished() -> void:
	_refresh_status("native: simulation_finished", StatusTone.OK)
	_log("[color=lime]Simulation finished.[/color]")

# -------------------------------------------------------------------
# Clear staging
# -------------------------------------------------------------------

func _on_staged_item_activated(index: int) -> void:
	if index < 0 or index >= staged.size():
		return
	# Select the item and trigger run (handles .sch vs netlist automatically)
	staged_list.select(index)
	_on_run_pressed()


func _on_clear_pressed() -> void:
	staged.clear()
	staged_list.clear()
	output_box.clear()
	_refresh_status("staging cleared", StatusTone.WARN)

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

func _resolve_simulator() -> Node:
	if simulator_path != NodePath("") and has_node(simulator_path):
		var n0: Node = get_node(simulator_path)
		if n0 != null and n0.has_method("initialize_ngspice"):
			return n0

	var cur: Node = self
	while cur != null:
		if cur.has_method("initialize_ngspice") and cur.has_method("load_netlist") and cur.has_method("run_simulation"):
			return cur
		cur = cur.get_parent()

	var root: Window = get_tree().root
	if root != null:
		var candidates: Array = root.find_children("*", "", true, false)
		for c in candidates:
			if c is Node and (c as Node).has_method("initialize_ngspice") and (c as Node).has_method("load_netlist"):
				return c as Node

	return null

func _ensure_upload_dir() -> void:
	var abs_path: String = ProjectSettings.globalize_path(UPLOAD_DIR)
	DirAccess.make_dir_recursive_absolute(abs_path)

func _sanitize_filename(filename: String) -> String:
	var s: String = filename.strip_edges()
	s = s.replace("\\", "_").replace("/", "_").replace(":", "_")
	s = s.replace("*", "_").replace("?", "_").replace("\"", "_").replace("<", "_").replace(">", "_").replace("|", "_")
	if s == "":
		s = "upload.bin"
	return s

func _avoid_collision(user_path: String) -> String:
	if not FileAccess.file_exists(user_path):
		return user_path

	var base: String = user_path.get_basename()
	var ext: String = user_path.get_extension()
	var stamp: int = int(Time.get_unix_time_from_system())
	return "%s_%d.%s" % [base, stamp, ext]

func _detect_kind(ext: String, bytes: PackedByteArray) -> String:
	if XSCHEM_EXTS.has(ext):
		return "xschem (.sch)"
	if NETLIST_EXTS.has(ext):
		var head: String = _bytes_head_as_text(bytes, 120).strip_edges()
		if head.begins_with(".") or head.begins_with("*") or head.find("ngspice") != -1:
			return "netlist"
		return "netlist/text"
	return "unknown"

func _is_netlist_entry(entry: Dictionary) -> bool:
	return entry.has("ext") and NETLIST_EXTS.has(str(entry["ext"]))

func _is_schematic_entry(entry: Dictionary) -> bool:
	return entry.has("ext") and XSCHEM_EXTS.has(str(entry["ext"]))

func _bytes_head_as_text(bytes: PackedByteArray, n: int) -> String:
	var slice: PackedByteArray = bytes.slice(0, min(n, bytes.size()))
	return slice.get_string_from_utf8()

func _rebuild_list() -> void:
	staged_list.clear()
	for e in staged:
		var label: String = "%s    (%s, %s)    → %s" % [
			str(e["display"]),
			str(e["kind"]),
			_human_size(int(e["bytes"])),
			str(e["user_path"])
		]
		staged_list.add_item(label)

func _human_size(n: int) -> String:
	if n < 1024:
		return "%d B" % n
	if n < 1024 * 1024:
		return "%.1f KB" % (float(n) / 1024.0)
	return "%.2f MB" % (float(n) / (1024.0 * 1024.0))

func _refresh_status(msg: String, tone: StatusTone = StatusTone.IDLE) -> void:
	if status_prefix == null:
		status_prefix = get_node_or_null("Margin/VBox/StatusRow/StatusPrefix")
	if status_value == null:
		status_value = get_node_or_null("Margin/VBox/StatusRow/StatusValue")
	if status_prefix == null or status_value == null:
		return

	status_prefix.text = "Status:"
	status_prefix.add_theme_color_override("font_color", Color(1, 1, 1, 1))

	status_value.text = msg

	var c: Color
	match tone:
		StatusTone.OK:
			c = Color(0.25, 0.85, 0.45) # green
		StatusTone.WARN:
			c = Color(1.00, 0.70, 0.20) # orange
		StatusTone.ERROR:
			c = Color(1.00, 0.30, 0.30) # red
		_:
			c = Color(0.85, 0.85, 0.85) # light gray idle

	status_value.add_theme_color_override("font_color", c)

func _set_error(msg: String) -> void:
	_refresh_status("error", StatusTone.ERROR)
	_log("[color=tomato][b]Error:[/b][/color] %s" % msg)

func _log(bb: String) -> void:
	if output_box == null:
		output_box = get_node_or_null("Margin/VBox/Output")
	if output_box != null:
		output_box.append_text(bb + "\n")
		output_box.scroll_to_line(output_box.get_line_count())
	else:
		print("[UploadPanel] ", bb.replace("[color=", "").replace("[/color]", ""))

# -------------------------------------------------------------------
# Styling: light “Microsoft-esque” theme + drop flash
# -------------------------------------------------------------------

func _apply_light_theme() -> void:
	_t = Theme.new()

	var bg: Color = Color(1, 1, 1)
	var panel: Color = Color(0.98, 0.98, 0.98)
	var border: Color = Color(0.82, 0.82, 0.82)
	var text: Color = Color(0.13, 0.13, 0.13)
	var subtext: Color = Color(0.35, 0.35, 0.35)
	var accent: Color = Color(0.00, 0.47, 0.83)
	var accent_hover: Color = Color(0.00, 0.40, 0.72)

	_sb_panel = StyleBoxFlat.new()
	_sb_panel.bg_color = panel
	_sb_panel.border_color = border
	_sb_panel.border_width_left = 1
	_sb_panel.border_width_top = 1
	_sb_panel.border_width_right = 1
	_sb_panel.border_width_bottom = 1
	_sb_panel.corner_radius_top_left = 10
	_sb_panel.corner_radius_top_right = 10
	_sb_panel.corner_radius_bottom_left = 10
	_sb_panel.corner_radius_bottom_right = 10
	_sb_panel.content_margin_left = 10
	_sb_panel.content_margin_right = 10
	_sb_panel.content_margin_top = 10
	_sb_panel.content_margin_bottom = 10

	_sb_panel_hover = _sb_panel.duplicate() as StyleBoxFlat
	_sb_panel_hover.border_color = Color(0.70, 0.70, 0.70)

	_sb_drop_idle = _sb_panel.duplicate() as StyleBoxFlat
	_sb_drop_idle.bg_color = Color(0.985, 0.985, 0.985)

	_sb_drop_flash = _sb_panel.duplicate() as StyleBoxFlat
	_sb_drop_flash.bg_color = Color(0.93, 0.97, 1.0)
	_sb_drop_flash.border_color = Color(0.35, 0.62, 0.90)

	var sb_root: StyleBoxFlat = StyleBoxFlat.new()
	sb_root.bg_color = bg
	add_theme_stylebox_override("panel", sb_root)

	_t.set_color("font_color", "Label", text)
	_t.set_color("font_color", "RichTextLabel", text)
	_t.set_color("font_color", "LineEdit", text)
	_t.set_color("font_color", "ItemList", text)

	drop_hint.add_theme_color_override("font_color", subtext)

	var sb_btn: StyleBoxFlat = StyleBoxFlat.new()
	sb_btn.bg_color = accent
	sb_btn.border_color = accent
	sb_btn.corner_radius_top_left = 8
	sb_btn.corner_radius_top_right = 8
	sb_btn.corner_radius_bottom_left = 8
	sb_btn.corner_radius_bottom_right = 8
	sb_btn.content_margin_left = 12
	sb_btn.content_margin_right = 12
	sb_btn.content_margin_top = 8
	sb_btn.content_margin_bottom = 8

	var sb_btn_hover: StyleBoxFlat = sb_btn.duplicate() as StyleBoxFlat
	sb_btn_hover.bg_color = accent_hover
	sb_btn_hover.border_color = accent_hover

	var sb_btn_pressed: StyleBoxFlat = sb_btn.duplicate() as StyleBoxFlat
	sb_btn_pressed.bg_color = Color(0.00, 0.34, 0.62)
	sb_btn_pressed.border_color = sb_btn_pressed.bg_color

	_t.set_stylebox("normal", "Button", sb_btn)
	_t.set_stylebox("hover", "Button", sb_btn_hover)
	_t.set_stylebox("pressed", "Button", sb_btn_pressed)
	_t.set_stylebox("focus", "Button", sb_btn_hover)
	_t.set_color("font_color", "Button", Color(1, 1, 1))

	var sb_edit: StyleBoxFlat = _sb_panel.duplicate() as StyleBoxFlat
	sb_edit.bg_color = Color(1, 1, 1)
	sb_edit.corner_radius_top_left = 8
	sb_edit.corner_radius_top_right = 8
	sb_edit.corner_radius_bottom_left = 8
	sb_edit.corner_radius_bottom_right = 8
	_t.set_stylebox("normal", "LineEdit", sb_edit)
	_t.set_stylebox("focus", "LineEdit", _sb_panel_hover)

	# ItemList / Output panes
	var sb_list: StyleBoxFlat = _sb_panel.duplicate() as StyleBoxFlat
	sb_list.bg_color = Color(1, 1, 1)
	_t.set_stylebox("panel", "ItemList", sb_list)
	_t.set_stylebox("normal", "RichTextLabel", sb_list)

	# ------------------------------------------------------------
	# ItemList hover + selection colors
	# Theme keys for ItemList include:
	#   StyleBoxes: hovered, selected, selected_focus, hovered_selected, hovered_selected_focus
	#   Colors: font_color, font_hovered_color, font_selected_color, font_hovered_selected_color
	# ------------------------------------------------------------

	# Hovered (darkish grey)
	var sb_item_hover: StyleBoxFlat = StyleBoxFlat.new()
	sb_item_hover.bg_color = Color(0.25, 0.25, 0.25, 0.55)   # dark grey hover
	sb_item_hover.corner_radius_top_left = 6
	sb_item_hover.corner_radius_top_right = 6
	sb_item_hover.corner_radius_bottom_left = 6
	sb_item_hover.corner_radius_bottom_right = 6
	sb_item_hover.content_margin_left = 6
	sb_item_hover.content_margin_right = 6
	sb_item_hover.content_margin_top = 2
	sb_item_hover.content_margin_bottom = 2

	# Selected (green)
	var sb_item_selected: StyleBoxFlat = sb_item_hover.duplicate() as StyleBoxFlat
	sb_item_selected.bg_color = Color(0.20, 0.75, 0.35, 0.90)  # green selection

	# Hovered + selected (slightly darker green)
	var sb_item_hover_selected: StyleBoxFlat = sb_item_selected.duplicate() as StyleBoxFlat
	sb_item_hover_selected.bg_color = Color(0.16, 0.68, 0.31, 0.95)

	# Apply the styleboxes to ItemList’s theme slots
	_t.set_stylebox("hovered", "ItemList", sb_item_hover)
	_t.set_stylebox("selected", "ItemList", sb_item_selected)
	_t.set_stylebox("selected_focus", "ItemList", sb_item_selected)
	_t.set_stylebox("hovered_selected", "ItemList", sb_item_hover_selected)
	_t.set_stylebox("hovered_selected_focus", "ItemList", sb_item_hover_selected)

	# Text colors for the different ItemList states
	_t.set_color("font_color", "ItemList", Color(0.13, 0.13, 0.13))                 # default
	_t.set_color("font_hovered_color", "ItemList", Color(1, 1, 1))                  # hover text
	_t.set_color("font_selected_color", "ItemList", Color(1, 1, 1))                 # selected text
	_t.set_color("font_hovered_selected_color", "ItemList", Color(1, 1, 1))         # hover+selected text


	_t.set_stylebox("panel", "PanelContainer", _sb_panel)

	theme = _t
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_idle)

func _flash_drop_zone() -> void:
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_flash)
	drop_title.text = "Dropped, staging…"
	await get_tree().create_timer(0.35).timeout
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_idle)
	drop_title.text = "Drop files here"
