extends Control

signal schematic_requested(path: String)
signal spice_paired(path: String)

@export var simulator_path: NodePath = NodePath("..")
const UPLOAD_DIR := "user://uploads"

const WORKSPACE_EXT := ".cvw.zip"
const WORKSPACE_MANIFEST := "manifest.json"
const WORKSPACE_FILES_DIR := "files/"

var NETLIST_EXTS: PackedStringArray = PackedStringArray(["spice", "cir", "net", "txt"])
var XSCHEM_EXTS: PackedStringArray = PackedStringArray(["sch", "sym"])

@onready var upload_button: Button = $Margin/VBox/ControlsRow/UploadButton
@onready var run_button: Button = $Margin/VBox/ControlsRow/RunButton
@onready var clear_button: Button = $Margin/VBox/ControlsRow/ClearButton
@onready var save_ws_button: Button = $Margin/VBox/ControlsRow/SaveWorkspaceButton
@onready var load_ws_button: Button = $Margin/VBox/ControlsRow/LoadWorkspaceButton
@onready var theme_toggle_button: Button = $Margin/VBox/ControlsRow/ThemeToggleButton

@onready var project_cards: VBoxContainer = $Margin/VBox/CardContainer/CardScroll/ProjectCards

@onready var status_bar: PanelContainer = $Margin/VBox/StatusBar
@onready var status_prefix: Label = $Margin/VBox/StatusBar/StatusRow/StatusPrefix
@onready var status_value: Label = $Margin/VBox/StatusBar/StatusRow/StatusValue

@onready var output_box: RichTextLabel = $Margin/VBox/Output
@onready var file_dialog: FileDialog = $FileDialog
@onready var workspace_dialog: FileDialog = $WorkspaceDialog

@onready var drop_zone: PanelContainer = $Margin/VBox/DropZone
@onready var drop_title: Label = $Margin/VBox/DropZone/DropZoneMargin/DropZoneVBox/DropTitle
@onready var drop_hint: Label = $Margin/VBox/DropZone/DropZoneMargin/DropZoneVBox/DropHint

# -------------------------------------------------------------------
# Project model
# Each project Dictionary:
#   "name"     : String              – spice basename
#   "xschem"   : Dictionary|null    – { display, user_path, bytes, ext }
#   "spice"    : Dictionary|null    – { display, user_path, bytes, ext }
#   "complete" : bool
# -------------------------------------------------------------------
var projects: Array[Dictionary] = []

# Targeted slot upload state (set when a card's "+" is clicked)
var _pending_slot_project: int = -1
var _pending_slot_key: String = ""

# Which card is selected for Run Simulation
var _selected_project: int = -1
var _dark_mode: bool = false
var _last_status_msg: String = "idle"
var _last_status_tone: StatusTone = StatusTone.IDLE

var _sim_signal_connected: bool = false
var _sim: Node = null

# Theme / style vars
var _t: Theme = null
var _sb_panel: StyleBoxFlat = null
var _sb_panel_hover: StyleBoxFlat = null
var _sb_drop_idle: StyleBoxFlat = null
var _sb_drop_flash: StyleBoxFlat = null
var _sb_status_bar: StyleBoxFlat = null
var _sb_card: StyleBoxFlat = null
var _sb_card_hover: StyleBoxFlat = null
var _sb_card_selected: StyleBoxFlat = null
var _sb_slot_box: StyleBoxFlat = null
var _sb_slot_box_hover: StyleBoxFlat = null

enum StatusTone { IDLE, OK, WARN, ERROR }

var _ws_mode: String = ""
var _ws_name_dialog: AcceptDialog = null
var _ws_name_edit: LineEdit = null
var _pending_ws_name_action: String = ""

# -------------------------------------------------------------------
# Ready
# -------------------------------------------------------------------

func _ready() -> void:
	_apply_theme()
	_ensure_upload_dir()
	_ensure_ws_name_popup()

	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	file_dialog.use_native_dialog = true
	file_dialog.clear_filters()
	file_dialog.add_filter("*.spice, *.cir, *.net, *.txt ; Netlists")
	file_dialog.add_filter("*.sch, *.sym ; Xschem schematics/symbols")
	file_dialog.add_filter("* ; All files")

	upload_button.pressed.connect(Callable(self, "_on_upload_pressed"))
	run_button.pressed.connect(Callable(self, "_on_run_pressed"))
	clear_button.pressed.connect(Callable(self, "_on_clear_pressed"))
	save_ws_button.pressed.connect(Callable(self, "_on_save_workspace_pressed"))
	load_ws_button.pressed.connect(Callable(self, "_on_load_workspace_pressed"))
	theme_toggle_button.pressed.connect(Callable(self, "_on_theme_toggle_pressed"))

	file_dialog.files_selected.connect(Callable(self, "_on_native_files_selected"))
	file_dialog.file_selected.connect(Callable(self, "_on_native_file_selected"))
	workspace_dialog.file_selected.connect(Callable(self, "_on_workspace_dialog_file_selected"))

	output_box.bbcode_enabled = true
	output_box.add_theme_color_override("default_color", Color(0.10, 0.10, 0.10, 1))

	if not OS.has_feature("web"):
		if get_viewport() != null:
			if not get_viewport().files_dropped.is_connected(Callable(self, "_on_os_files_dropped")):
				get_viewport().files_dropped.connect(Callable(self, "_on_os_files_dropped"))

	_sim = _resolve_simulator()
	_refresh_status("idle", StatusTone.IDLE)

	if OS.has_feature("web"):
		var has_bridge: bool = _web_eval_bool(
			"typeof window.godotUploadOpenPicker === 'function' && Array.isArray(window.godotUploadQueue)"
		)
		if has_bridge:
			_log("[color=darkgreen][b]OK:[/b][/color] Web upload bridge detected.")
		else:
			_log("[color=#b56a00][b]Warning:[/b][/color] Web upload bridge not detected yet.")

func _process(_delta: float) -> void:
	if OS.has_feature("web"):
		_poll_web_queue()

# -------------------------------------------------------------------
# Upload flows
# -------------------------------------------------------------------

func _on_upload_pressed() -> void:
	# Top-level upload clears any pending slot target
	_pending_slot_project = -1
	_pending_slot_key = ""
	if OS.has_feature("web"):
		var ok: bool = _web_eval_bool("typeof window.godotUploadOpenPicker === 'function'")
		if not ok:
			_set_error("Web picker not available. Did you include upload_bridge.js in the export HTML?")
			return
		JavaScriptBridge.eval("window.godotUploadOpenPicker()", true)
		_refresh_status("web: picker opened", StatusTone.WARN)
	else:
		file_dialog.popup_centered_ratio(0.8)
		_refresh_status("native: file dialog opened", StatusTone.WARN)

func _on_native_file_selected(path: String) -> void:
	if path.strip_edges() == "":
		return
	_stage_native_file(path)

func _on_native_files_selected(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var xschem_paths: Array[String] = []
	var spice_paths: Array[String] = []
	for p: String in paths:
		if p.strip_edges() == "":
			continue
		var ext := p.get_extension().to_lower()
		if XSCHEM_EXTS.has(ext):
			xschem_paths.append(p)
		elif NETLIST_EXTS.has(ext):
			spice_paths.append(p)

	# When doing a targeted slot upload only one file is expected
	if _pending_slot_project >= 0:
		if paths.size() > 1:
			_set_error("Select exactly one file when filling a project slot.")
			_pending_slot_project = -1
			_pending_slot_key = ""
			return
	else:
		if xschem_paths.size() > 1:
			_set_error("Please select at most one xschem file (.sch/.sym) at a time.")
			return
		if spice_paths.size() > 1:
			_set_error("Please select at most one netlist/spice file at a time.")
			return

	var added := 0
	for p in xschem_paths:
		if _stage_native_file(p):
			added += 1
	for p in spice_paths:
		if _stage_native_file(p):
			added += 1

	if added > 0:
		_flash_drop_zone()
		_refresh_status("staged %d file(s)" % added, StatusTone.OK)
	else:
		_refresh_status("no valid files selected", StatusTone.WARN)

func _on_os_files_dropped(files: PackedStringArray) -> void:
	if OS.has_feature("web"):
		return
	if files.is_empty():
		return
	var added := 0
	for p: String in files:
		if p.strip_edges() == "":
			continue
		added += int(_stage_native_file(p))
	if added > 0:
		_flash_drop_zone()
		_refresh_status("dropped %d file(s)" % added, StatusTone.OK)
	else:
		_refresh_status("drop received, no valid files", StatusTone.WARN)

func _stage_native_file(src_path: String) -> bool:
	if not FileAccess.file_exists(src_path):
		_set_error("File does not exist: %s" % src_path)
		return false
	var src := FileAccess.open(src_path, FileAccess.READ)
	if src == null:
		_set_error("Failed to open: %s" % src_path)
		return false
	var bytes := src.get_buffer(src.get_length())
	src.close()
	return _stage_bytes(src_path.get_file(), bytes)

func _stage_bytes(original_name: String, bytes: PackedByteArray) -> bool:
	_ensure_upload_dir()
	var safe_name := _sanitize_filename(original_name)
	var user_path := "%s/%s" % [UPLOAD_DIR, safe_name]
	user_path = _avoid_collision(user_path)

	var f := FileAccess.open(user_path, FileAccess.WRITE)
	if f == null:
		_set_error("Failed to write into %s" % user_path)
		return false
	f.store_buffer(bytes)
	f.close()

	var ext := safe_name.get_extension().to_lower()
	var slot: Dictionary = {
		"display": safe_name,
		"user_path": user_path,
		"bytes": bytes.size(),
		"ext": ext
	}

	if _pending_slot_project >= 0 and _pending_slot_key != "":
		_assign_to_pending_slot(slot)
	elif XSCHEM_EXTS.has(ext):
		_assign_xschem(slot)
	elif NETLIST_EXTS.has(ext):
		_assign_spice(slot)
	else:
		_log("[color=#b56a00][b]Warning:[/b][/color] Unrecognised extension '%s', skipped." % ext)
		return false

	_rebuild_cards()
	_log("[color=#336699][b]Info:[/b][/color] Staged %s" % safe_name)
	return true

# -------------------------------------------------------------------
# Project slot assignment
# -------------------------------------------------------------------

func _assign_spice(slot: Dictionary) -> void:
	# Every spice upload creates a new project keyed by its basename.
	var basename := (slot["display"] as String).get_basename()
	projects.append({
		"name": basename,
		"xschem": null,
		"spice": slot,
		"complete": false
	})
	spice_paired.emit(str(slot.get("user_path", "")))

func _assign_xschem(slot: Dictionary) -> void:
	# Pair with the first incomplete project that has no xschem yet.
	for proj in projects:
		if proj["xschem"] == null:
			proj["xschem"] = slot
			proj["complete"] = proj["spice"] != null
			schematic_requested.emit(str(slot.get("user_path", "")))
			return
	# No waiting project — create orphan (name updated when spice arrives)
	var basename := (slot["display"] as String).get_basename()
	projects.append({
		"name": basename,
		"xschem": slot,
		"spice": null,
		"complete": false
	})
	schematic_requested.emit(str(slot.get("user_path", "")))

func _assign_to_pending_slot(slot: Dictionary) -> void:
	var idx := _pending_slot_project
	var key := _pending_slot_key
	_pending_slot_project = -1
	_pending_slot_key = ""

	if idx < 0 or idx >= projects.size():
		# Index out of range — fall back to auto-assign
		var ext := str(slot.get("ext", ""))
		if XSCHEM_EXTS.has(ext):
			_assign_xschem(slot)
		elif NETLIST_EXTS.has(ext):
			_assign_spice(slot)
		return

	var ext := str(slot.get("ext", ""))
	var proj := projects[idx]

	if key == "spice":
		if not NETLIST_EXTS.has(ext):
			_set_error("Expected a spice/netlist file (.spice/.cir/.net/.txt) for this slot.")
			return
		proj["spice"] = slot
		proj["name"] = (slot["display"] as String).get_basename()
		proj["complete"] = proj["xschem"] != null
		spice_paired.emit(str(slot.get("user_path", "")))

	elif key == "xschem":
		if not XSCHEM_EXTS.has(ext):
			_set_error("Expected an xschem file (.sch/.sym) for this slot.")
			return
		proj["xschem"] = slot
		proj["complete"] = proj["spice"] != null
		schematic_requested.emit(str(slot.get("user_path", "")))

# -------------------------------------------------------------------
# Web queue polling
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
	var json := str(raw)
	if json.is_empty():
		return
	var parsed: Variant = JSON.parse_string(json)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		_set_error("Web upload: failed to parse queued JSON.")
		return
	var d := parsed as Dictionary

	if str(d.get("type", "")) == "batch":
		var files_var: Variant = d.get("files", [])
		if typeof(files_var) != TYPE_ARRAY:
			_set_error("Web upload: batch missing files[].")
			return
		_handle_web_batch(files_var as Array)
		return

	if d.has("name") and d.has("base64"):
		_handle_web_batch([d])
		return

	_set_error("Web upload: unrecognized queue item.")

func _handle_web_batch(items: Array) -> void:
	var xschem_count := 0
	var spice_count := 0
	var entries: Array = []
	for it_v in items:
		if typeof(it_v) != TYPE_DICTIONARY:
			continue
		var it := it_v as Dictionary
		if it.has("error") and str(it["error"]) != "":
			_set_error("Web upload error for %s: %s" % [str(it.get("name", "unknown")), str(it["error"])])
			continue
		var filename := str(it.get("name", "upload.bin"))
		var b64 := str(it.get("base64", ""))
		var bytes := Marshalls.base64_to_raw(b64)
		if _looks_like_workspace_zip(filename, bytes):
			var ok_ws := _load_workspace_zip_from_bytes(bytes)
			if ok_ws:
				_refresh_status("web: workspace loaded", StatusTone.OK)
			return
		var ext := filename.get_extension().to_lower()
		if XSCHEM_EXTS.has(ext):
			xschem_count += 1
		elif NETLIST_EXTS.has(ext):
			spice_count += 1
		entries.append({"name": filename, "bytes": bytes})

	# Skip batch-size validation for targeted slot uploads
	if _pending_slot_project < 0:
		if xschem_count > 1:
			_set_error("Please select at most one xschem file (.sch/.sym) per upload.")
			return
		if spice_count > 1:
			_set_error("Please select at most one netlist/spice file per upload.")
			return

	var added := 0
	for e in entries:
		if _stage_bytes(str(e["name"]), e["bytes"] as PackedByteArray):
			added += 1
	if added > 0:
		_flash_drop_zone()
		_refresh_status("web: staged %d file(s)" % added, StatusTone.OK)

func _looks_like_workspace_zip(filename: String, bytes: PackedByteArray) -> bool:
	var lower := filename.to_lower()
	if not (lower.ends_with(WORKSPACE_EXT) or lower.ends_with(".zip")):
		return false
	if bytes.size() < 2:
		return false
	return int(bytes[0]) == 0x50 and int(bytes[1]) == 0x4B

func _web_eval_bool(expr: String) -> bool:
	var v: Variant = JavaScriptBridge.eval("(%s) ? true : false" % expr, true)
	return bool(v)

# -------------------------------------------------------------------
# Run simulation
# -------------------------------------------------------------------

func _on_run_pressed() -> void:
	var complete: Array[Dictionary] = []
	for proj in projects:
		if proj["complete"]:
			complete.append(proj)

	if complete.is_empty():
		_set_error("No complete project (needs both an xschem and a spice file).")
		return

	if OS.has_feature("web"):
		_set_error("Web build: ngspice runtime is not supported yet.")
		return

	_sim = _resolve_simulator()
	if _sim == null:
		_set_error("Could not find CircuitSimulator node.")
		return
	if not _sim.has_method("initialize_ngspice"):
		_set_error("Resolved node lacks initialize_ngspice().")
		return

	var selected_proj: Dictionary
	if _selected_project >= 0 and _selected_project < projects.size() and projects[_selected_project]["complete"]:
		selected_proj = projects[_selected_project]
	elif complete.size() == 1:
		selected_proj = complete[0]
	else:
		_set_error("Multiple complete projects — click one to select it first.")
		return

	var spice_entry: Dictionary = selected_proj["spice"]
	if not _sim_signal_connected and _sim.has_signal("simulation_finished"):
		_sim.connect("simulation_finished", Callable(self, "_on_sim_finished"))
		_sim_signal_connected = true

	_refresh_status("initializing ngspice...", StatusTone.WARN)
	if not bool(_sim.call("initialize_ngspice")):
		_set_error("initialize_ngspice() returned false.")
		return

	_refresh_status("loading netlist...", StatusTone.WARN)
	var os_path := ProjectSettings.globalize_path(str(spice_entry["user_path"]))
	_sim.call("load_netlist", os_path)
	_refresh_status("running simulation...", StatusTone.WARN)
	_sim.call("run_simulation")

func _on_sim_finished() -> void:
	_refresh_status("simulation finished", StatusTone.OK)
	_log("[color=darkgreen][b]OK:[/b][/color] Simulation finished.")

# -------------------------------------------------------------------
# Project cards
# -------------------------------------------------------------------

func _rebuild_cards() -> void:
	for child in project_cards.get_children():
		project_cards.remove_child(child)
		child.queue_free()
	for i in projects.size():
		project_cards.add_child(_build_project_card(i, projects[i]))

func _build_project_card(idx: int, proj: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	var is_selected := (idx == _selected_project)
	var normal_style := (_sb_card_selected if is_selected else _sb_card).duplicate() as StyleBoxFlat
	card.add_theme_stylebox_override("panel", normal_style)
	card.mouse_filter = Control.MOUSE_FILTER_STOP

	# Use .bind() — more reliable than a lambda for signal/idx capture
	card.gui_input.connect(_on_card_gui_input.bind(idx))

	# Hover: swap stylebox directly (no rebuild needed)
	card.mouse_entered.connect(func():
		if idx != _selected_project:
			card.add_theme_stylebox_override("panel", _sb_card_hover.duplicate())
	)
	card.mouse_exited.connect(func():
		if idx != _selected_project:
			card.add_theme_stylebox_override("panel", _sb_card.duplicate())
	)

	var hbox := HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", 6)
	card.add_child(hbox)

	var col_primary: Color   = Color("E0DDD4") if _dark_mode else Color(0, 0, 0)
	var col_secondary: Color = Color("8A8880") if _dark_mode else Color("606060")
	var col_mid: Color       = Color("9A9890") if _dark_mode else Color("404040")

	# Title label
	var title_lbl := Label.new()
	title_lbl.text = "%s:" % str(proj["name"])
	title_lbl.add_theme_color_override("font_color", col_primary)
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(title_lbl)

	# Spice slot
	hbox.add_child(_build_slot_control(idx, "spice", proj["spice"]))

	var spice_ext_lbl := Label.new()
	spice_ext_lbl.text = ".spice"
	spice_ext_lbl.add_theme_color_override("font_color", col_secondary)
	spice_ext_lbl.add_theme_font_size_override("font_size", 12)
	spice_ext_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(spice_ext_lbl)

	var and_lbl := Label.new()
	and_lbl.text = "  and  "
	and_lbl.add_theme_color_override("font_color", col_mid)
	and_lbl.add_theme_font_size_override("font_size", 12)
	and_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(and_lbl)

	# Xschem slot
	hbox.add_child(_build_slot_control(idx, "xschem", proj["xschem"]))

	var sch_ext := ".sch"
	if proj["xschem"] != null:
		sch_ext = ".%s" % str((proj["xschem"] as Dictionary).get("ext", "sch"))
	var xschem_ext_lbl := Label.new()
	xschem_ext_lbl.text = sch_ext
	xschem_ext_lbl.add_theme_color_override("font_color", col_secondary)
	xschem_ext_lbl.add_theme_font_size_override("font_size", 12)
	xschem_ext_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(xschem_ext_lbl)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(spacer)

	# Size label
	var total_bytes := 0
	if proj["spice"] != null:
		total_bytes += int((proj["spice"] as Dictionary).get("bytes", 0))
	if proj["xschem"] != null:
		total_bytes += int((proj["xschem"] as Dictionary).get("bytes", 0))
	var size_lbl := Label.new()
	size_lbl.text = "Size: %s" % _human_size(total_bytes)
	size_lbl.add_theme_color_override("font_color", col_secondary)
	size_lbl.add_theme_font_size_override("font_size", 12)
	size_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(size_lbl)

	return card

func _build_slot_control(proj_idx: int, slot_key: String, slot_data: Variant) -> Control:
	if slot_data != null:
		# File present — show basename in a styled box, transparent to mouse
		var container := PanelContainer.new()
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		container.add_theme_stylebox_override("panel", _sb_slot_box.duplicate())
		var lbl := Label.new()
		lbl.text = (str((slot_data as Dictionary).get("display", ""))).get_basename()
		lbl.add_theme_color_override("font_color", Color("E0DDD4") if _dark_mode else Color(0, 0, 0))
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		container.add_child(lbl)
		return container
	else:
		# File missing — show "+" upload button
		var btn := Button.new()
		btn.text = "  +  "
		btn.add_theme_stylebox_override("normal", _sb_slot_box.duplicate())
		btn.add_theme_stylebox_override("hover", _sb_slot_box_hover.duplicate())
		btn.add_theme_stylebox_override("pressed", _sb_slot_box.duplicate())
		btn.add_theme_stylebox_override("focus", _sb_slot_box.duplicate())
		btn.add_theme_color_override("font_color", Color("4A82D0") if _dark_mode else Color("316AC5"))
		btn.add_theme_font_size_override("font_size", 12)
		btn.pressed.connect(func(): _on_slot_plus_pressed(proj_idx, slot_key))
		return btn

func _on_card_gui_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_selected_project = idx
			# Deferred so we don't free this card node while still inside its signal
			_rebuild_cards.call_deferred()

func _on_slot_plus_pressed(proj_idx: int, slot_key: String) -> void:
	_pending_slot_project = proj_idx
	_pending_slot_key = slot_key
	var proj_name := str(projects[proj_idx]["name"])
	_refresh_status("select a %s file for '%s'..." % [slot_key, proj_name], StatusTone.WARN)
	if OS.has_feature("web"):
		var ok := _web_eval_bool("typeof window.godotUploadOpenPicker === 'function'")
		if not ok:
			_set_error("Web picker not available.")
			_pending_slot_project = -1
			_pending_slot_key = ""
			return
		JavaScriptBridge.eval("window.godotUploadOpenPicker()", true)
	else:
		file_dialog.popup_centered_ratio(0.8)

# -------------------------------------------------------------------
# Clear
# -------------------------------------------------------------------

func _on_clear_pressed() -> void:
	projects.clear()
	_selected_project = -1
	_pending_slot_project = -1
	_pending_slot_key = ""
	for child in project_cards.get_children():
		project_cards.remove_child(child)
		child.queue_free()
	output_box.clear()
	_refresh_status("staging cleared", StatusTone.WARN)

# -------------------------------------------------------------------
# Workspace save / load
# -------------------------------------------------------------------

func _on_save_workspace_pressed() -> void:
	if projects.is_empty():
		_set_error("Nothing to save: stage at least one file first.")
		return
	_pending_ws_name_action = "save"
	_ws_name_edit.text = _default_workspace_name()
	_ws_name_dialog.popup_centered()

func _on_ws_name_confirmed() -> void:
	var raw := _ws_name_edit.text.strip_edges()
	var name := _sanitize_workspace_basename(raw)
	if name == "":
		name = _default_workspace_name()
	_pending_ws_name_action = ""
	if OS.has_feature("web"):
		_save_workspace_zip_web_download(name)
		return
	_ws_mode = "save"
	workspace_dialog.access = FileDialog.ACCESS_FILESYSTEM
	workspace_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	workspace_dialog.use_native_dialog = true
	workspace_dialog.clear_filters()
	workspace_dialog.add_filter("*%s ; Circuit Visualizer Workspace" % WORKSPACE_EXT)
	workspace_dialog.current_file = "%s%s" % [name, WORKSPACE_EXT]
	workspace_dialog.popup_centered_ratio(0.8)
	_refresh_status("choose workspace save location...", StatusTone.WARN)

func _on_ws_name_canceled() -> void:
	_pending_ws_name_action = ""
	_refresh_status("save canceled", StatusTone.WARN)

func _on_load_workspace_pressed() -> void:
	if OS.has_feature("web"):
		var ok: bool = _web_eval_bool("typeof window.godotUploadOpenPicker === 'function'")
		if not ok:
			_set_error("Web picker not available.")
			return
		JavaScriptBridge.eval("window.godotUploadOpenPicker()", true)
		_refresh_status("web: choose a workspace zip to load...", StatusTone.WARN)
		return
	_ws_mode = "load"
	workspace_dialog.access = FileDialog.ACCESS_FILESYSTEM
	workspace_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	workspace_dialog.use_native_dialog = true
	workspace_dialog.clear_filters()
	workspace_dialog.add_filter("*%s ; Circuit Visualizer Workspace" % WORKSPACE_EXT)
	workspace_dialog.add_filter("*.zip ; ZIP files")
	workspace_dialog.popup_centered_ratio(0.8)
	_refresh_status("choose workspace file to load...", StatusTone.WARN)

func _on_workspace_dialog_file_selected(path: String) -> void:
	if path.strip_edges() == "":
		return
	if _ws_mode == "save":
		_save_workspace_zip_to_path(path)
	elif _ws_mode == "load":
		_load_workspace_zip_from_path(path)

func _save_workspace_zip_web_download(workspace_name: String) -> void:
	_ensure_upload_dir()
	var tmp_name := "%s_%d%s" % [workspace_name, int(Time.get_unix_time_from_system()), WORKSPACE_EXT]
	var tmp_path := "user://%s" % tmp_name
	if not _save_workspace_zip_to_user_path(tmp_path):
		return
	var fa := FileAccess.open(tmp_path, FileAccess.READ)
	if fa == null:
		_set_error("Failed to open generated workspace for download.")
		return
	var buf := fa.get_buffer(fa.get_length())
	fa.close()
	JavaScriptBridge.download_buffer(buf, "%s%s" % [workspace_name, WORKSPACE_EXT], "application/zip")
	_refresh_status("web: workspace downloaded", StatusTone.OK)
	_log("[color=darkgreen][b]OK:[/b][/color] Workspace download started.")

func _save_workspace_zip_to_path(path: String) -> void:
	var zip_path := path
	if not zip_path.to_lower().ends_with(WORKSPACE_EXT):
		zip_path += WORKSPACE_EXT
	if _save_workspace_zip_to_filesystem_path(zip_path):
		_refresh_status("workspace saved: %s" % zip_path.get_file(), StatusTone.OK)
		_log("[color=darkgreen][b]OK:[/b][/color] Saved workspace %s" % zip_path)

func _build_workspace_manifest_for_zip() -> Dictionary:
	var used: Dictionary = {}
	var proj_list: Array = []
	for proj in projects:
		var proj_entry: Dictionary = {
			"name": str(proj["name"]),
			"complete": bool(proj["complete"]),
			"xschem": null,
			"spice": null
		}
		for slot_key in ["xschem", "spice"]:
			var slot: Variant = proj[slot_key]
			if slot == null:
				continue
			var s: Dictionary = slot as Dictionary
			var display := str(s["display"])
			var zip_name := _sanitize_filename(display)
			if zip_name == "":
				zip_name = "file.bin"
			zip_name = _unique_name(zip_name, used)
			used[zip_name] = true
			proj_entry[slot_key] = {
				"name": display,
				"zip_path": WORKSPACE_FILES_DIR + zip_name,
				"user_path": str(s["user_path"]),
				"bytes": int(s["bytes"]),
				"ext": str(s["ext"])
			}
		proj_list.append(proj_entry)
	return {
		"format": "circuit-visualizer-workspace-zip",
		"version": 2,
		"created_unix": int(Time.get_unix_time_from_system()),
		"projects": proj_list
	}

func _save_workspace_zip_to_filesystem_path(zip_abs_path: String) -> bool:
	var writer := ZIPPacker.new()
	var err := writer.open(zip_abs_path, ZIPPacker.APPEND_CREATE)
	if err != OK:
		_set_error("Could not create zip: %s (err=%s)" % [zip_abs_path, str(err)])
		return false
	return _write_manifest_and_files(writer)

func _save_workspace_zip_to_user_path(zip_user_path: String) -> bool:
	var writer := ZIPPacker.new()
	var err := writer.open(zip_user_path, ZIPPacker.APPEND_CREATE)
	if err != OK:
		_set_error("Could not create zip in user storage: %s (err=%s)" % [zip_user_path, str(err)])
		return false
	return _write_manifest_and_files(writer)

func _write_manifest_and_files(writer: ZIPPacker) -> bool:
	var manifest := _build_workspace_manifest_for_zip()
	var err := writer.start_file(WORKSPACE_MANIFEST)
	if err != OK:
		writer.close()
		_set_error("Zip start_file(manifest) failed (err=%s)" % str(err))
		return false
	err = writer.write_file(JSON.stringify(manifest, "\t").to_utf8_buffer())
	if err != OK:
		writer.close_file()
		writer.close()
		_set_error("Zip write_file(manifest) failed (err=%s)" % str(err))
		return false
	writer.close_file()

	for proj_var in (manifest.get("projects", []) as Array):
		var proj := proj_var as Dictionary
		for slot_key in ["xschem", "spice"]:
			var slot_var: Variant = proj.get(slot_key, null)
			if slot_var == null:
				continue
			var item := slot_var as Dictionary
			var user_path := str(item.get("user_path", ""))
			var zip_rel := str(item.get("zip_path", ""))
			var fa := FileAccess.open(user_path, FileAccess.READ)
			if fa == null:
				writer.close()
				_set_error("Could not open staged file for zipping: %s" % user_path)
				return false
			var buf := fa.get_buffer(fa.get_length())
			fa.close()
			err = writer.start_file(zip_rel)
			if err != OK:
				writer.close()
				_set_error("Zip start_file(%s) failed (err=%s)" % [zip_rel, str(err)])
				return false
			err = writer.write_file(buf)
			if err != OK:
				writer.close_file()
				writer.close()
				_set_error("Zip write_file(%s) failed (err=%s)" % [zip_rel, str(err)])
				return false
			writer.close_file()

	writer.close()
	return true

func _load_workspace_zip_from_path(path: String) -> void:
	if not path.to_lower().ends_with(".zip"):
		_set_error("Not a zip file: %s" % path)
		return
	var reader := ZIPReader.new()
	var err := reader.open(path)
	if err != OK:
		_set_error("Could not open workspace zip (err=%s)" % str(err))
		return

	var manifest_bytes := reader.read_file(WORKSPACE_MANIFEST)
	if manifest_bytes.is_empty():
		reader.close()
		_set_error("Workspace zip missing %s" % WORKSPACE_MANIFEST)
		return

	var parsed: Variant = JSON.parse_string(manifest_bytes.get_string_from_utf8())
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		reader.close()
		_set_error("Workspace manifest is not valid JSON.")
		return

	var m := parsed as Dictionary
	if str(m.get("format", "")) != "circuit-visualizer-workspace-zip":
		reader.close()
		_set_error("Not a circuit-visualizer workspace zip.")
		return

	_on_clear_pressed()
	_ensure_upload_dir()

	var version := int(m.get("version", 1))

	if version >= 2:
		var proj_list_var: Variant = m.get("projects", [])
		if typeof(proj_list_var) != TYPE_ARRAY:
			reader.close()
			_set_error("Manifest missing projects[].")
			return
		for pv in (proj_list_var as Array):
			if typeof(pv) != TYPE_DICTIONARY:
				continue
			var pm := pv as Dictionary
			var new_proj: Dictionary = {
				"name": str(pm.get("name", "unnamed")),
				"xschem": null,
				"spice": null,
				"complete": false
			}
			for slot_key in ["xschem", "spice"]:
				var sv: Variant = pm.get(slot_key, null)
				if sv == null:
					continue
				var si := sv as Dictionary
				var name := str(si.get("name", "file.bin"))
				var zip_rel := str(si.get("zip_path", ""))
				if zip_rel == "":
					continue
				var buf := reader.read_file(zip_rel)
				if buf.is_empty():
					_log("[color=#b56a00][b]Warning:[/b][/color] Missing zip entry: %s" % zip_rel)
					continue
				var safe_name := _sanitize_filename(name)
				var user_path := _avoid_collision("%s/%s" % [UPLOAD_DIR, safe_name])
				var wf := FileAccess.open(user_path, FileAccess.WRITE)
				if wf == null:
					_set_error("Failed to write %s" % user_path)
					continue
				wf.store_buffer(buf)
				wf.close()
				new_proj[slot_key] = {
					"display": safe_name,
					"user_path": user_path,
					"bytes": buf.size(),
					"ext": safe_name.get_extension().to_lower()
				}
			new_proj["complete"] = new_proj["xschem"] != null and new_proj["spice"] != null
			projects.append(new_proj)
		reader.close()
	else:
		# Legacy v1: flat items[]
		var items_var: Variant = m.get("items", [])
		if typeof(items_var) != TYPE_ARRAY:
			reader.close()
			_set_error("Legacy manifest missing items[].")
			return
		for iv in (items_var as Array):
			if typeof(iv) != TYPE_DICTIONARY:
				continue
			var it := iv as Dictionary
			var name := str(it.get("name", "file.bin"))
			var zip_rel := str(it.get("zip_path", ""))
			if zip_rel == "":
				continue
			var buf := reader.read_file(zip_rel)
			if buf.is_empty():
				continue
			_stage_bytes(name, buf)
		reader.close()

	_rebuild_cards()
	_refresh_status("workspace loaded: %d project(s)" % projects.size(), StatusTone.OK)
	_log("[color=darkgreen][b]OK:[/b][/color] Loaded workspace (%d projects)." % projects.size())

func _load_workspace_zip_from_bytes(bytes: PackedByteArray) -> bool:
	var tmp_path := "user://incoming_workspace_%d%s" % [int(Time.get_unix_time_from_system()), WORKSPACE_EXT]
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		_set_error("Failed to write workspace zip into user storage.")
		return false
	f.store_buffer(bytes)
	f.close()
	_load_workspace_zip_from_path(tmp_path)
	return true

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
		for c in root.find_children("*", "", true, false):
			if c is Node and (c as Node).has_method("initialize_ngspice") and (c as Node).has_method("load_netlist"):
				return c as Node
	return null

func _ensure_upload_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(UPLOAD_DIR))

func _sanitize_filename(filename: String) -> String:
	var s := filename.strip_edges()
	for ch in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]:
		s = s.replace(ch, "_")
	if s == "":
		s = "upload.bin"
	return s

func _sanitize_workspace_basename(name: String) -> String:
	var s := name.strip_edges().replace(".", "_")
	s = _sanitize_filename(s).trim_suffix(".zip").trim_suffix(WORKSPACE_EXT)
	return s

func _default_workspace_name() -> String:
	return "workspace"

func _avoid_collision(user_path: String) -> String:
	if not FileAccess.file_exists(user_path):
		return user_path
	var base := user_path.get_basename()
	var ext := user_path.get_extension()
	return "%s_%d.%s" % [base, int(Time.get_unix_time_from_system()), ext]

func _unique_name(name: String, used: Dictionary) -> String:
	if not used.has(name):
		return name
	var base := name.get_basename()
	var ext := name.get_extension()
	var i := 2
	while true:
		var candidate := "%s_%d%s" % [base, i, ("." + ext) if ext != "" else ""]
		if not used.has(candidate):
			return candidate
		i += 1
	return name

func _human_size(n: int) -> String:
	if n < 1024:
		return "%d B" % n
	if n < 1024 * 1024:
		return "%.1f KB" % (float(n) / 1024.0)
	return "%.2f MB" % (float(n) / (1024.0 * 1024.0))

func _refresh_status(msg: String, tone: StatusTone = StatusTone.IDLE) -> void:
	_last_status_msg = msg
	_last_status_tone = tone
	status_prefix.text = "Status:"
	status_prefix.add_theme_color_override("font_color", Color(0, 0, 0) if not _dark_mode else Color("E0DDD4"))
	status_value.text = msg
	var c: Color
	if _dark_mode:
		match tone:
			StatusTone.OK:    c = Color("50CC70")
			StatusTone.WARN:  c = Color("D4A030")
			StatusTone.ERROR: c = Color("E05040")
			_:                c = Color("C0BDB6")   # light warm grey, readable on dark
	else:
		match tone:
			StatusTone.OK:    c = Color(0.10, 0.55, 0.20)
			StatusTone.WARN:  c = Color(0.70, 0.45, 0.00)
			StatusTone.ERROR: c = Color(0.80, 0.10, 0.10)
			_:                c = Color(0.25, 0.25, 0.25)
	status_value.add_theme_color_override("font_color", c)

func _set_error(msg: String) -> void:
	_refresh_status("error", StatusTone.ERROR)
	_log("[color=#cc2200][b]Error:[/b][/color] %s" % msg)

func _log(bb: String) -> void:
	output_box.append_text(bb + "\n")
	output_box.scroll_to_line(output_box.get_line_count())

# -------------------------------------------------------------------
# Workspace naming popup
# -------------------------------------------------------------------

func _ensure_ws_name_popup() -> void:
	if _ws_name_dialog != null:
		return
	_ws_name_dialog = AcceptDialog.new()
	_ws_name_dialog.title = "Workspace name"
	_ws_name_dialog.dialog_text = "Choose a name for this workspace file:"
	_ws_name_dialog.exclusive = true
	add_child(_ws_name_dialog)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ws_name_dialog.add_child(vb)
	_ws_name_edit = LineEdit.new()
	_ws_name_edit.placeholder_text = "workspace"
	_ws_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(_ws_name_edit)
	var hint := Label.new()
	hint.text = "Tip: You can leave the default and press OK."
	hint.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45, 1))
	vb.add_child(hint)
	_ws_name_dialog.confirmed.connect(Callable(self, "_on_ws_name_confirmed"))
	_ws_name_dialog.canceled.connect(Callable(self, "_on_ws_name_canceled"))

# -------------------------------------------------------------------
# Theme toggle
# -------------------------------------------------------------------

func _on_theme_toggle_pressed() -> void:
	_dark_mode = not _dark_mode
	_apply_theme()
	_rebuild_cards()
	_refresh_status(_last_status_msg, _last_status_tone)

# -------------------------------------------------------------------
# Styling — Windows XP Luna (light) / dark variant
# -------------------------------------------------------------------

func _apply_theme() -> void:
	_t = Theme.new()

	# --- Palette: light (XP Luna) or dark ---
	var xp_face: Color
	var xp_white: Color
	var xp_text: Color
	var xp_subtext: Color
	var xp_ctrl_border: Color
	var xp_btn_face: Color
	var xp_btn_hover_face: Color
	var xp_btn_hover_border: Color
	var xp_btn_pressed_face: Color
	var xp_btn_pressed_border: Color
	var xp_sel_blue: Color
	var xp_sel_blue_dark: Color
	var xp_sel_blue_pale: Color
	var xp_title_blue: Color
	var xp_ctrl_shadow: Color

	if _dark_mode:
		xp_face              = Color("1C1B18")
		xp_white             = Color("1A1918")
		xp_text              = Color("E0DDD4")
		xp_subtext           = Color("8A8880")
		xp_ctrl_border       = Color("4A5468")
		xp_btn_face          = Color("302E2A")
		xp_btn_hover_face    = Color("3D300E")
		xp_btn_hover_border  = Color("907020")
		xp_btn_pressed_face  = Color("152040")
		xp_btn_pressed_border = Color("204870")
		xp_sel_blue          = Color("4A82D0")
		xp_sel_blue_dark     = Color("2A5090")
		xp_sel_blue_pale     = Color("1A2D48")
		xp_title_blue        = Color("8AAED8")
		xp_ctrl_shadow       = Color("606878")
		theme_toggle_button.text = "Light Theme"
	else:
		xp_face              = Color("ECE9D8")
		xp_white             = Color(1, 1, 1)
		xp_text              = Color(0, 0, 0)
		xp_subtext           = Color("404040")
		xp_ctrl_border       = Color("7F9DB9")
		xp_btn_face          = Color("ECEBE7")
		xp_btn_hover_face    = Color("FFECC6")
		xp_btn_hover_border  = Color("E2A936")
		xp_btn_pressed_face  = Color("B6CFE6")
		xp_btn_pressed_border = Color("2A5CAA")
		xp_sel_blue          = Color("316AC5")
		xp_sel_blue_dark     = Color("1C3F7C")
		xp_sel_blue_pale     = Color("D6E5F5")
		xp_title_blue        = Color("0A246A")
		xp_ctrl_shadow       = Color("404D5B")
		theme_toggle_button.text = "Dark Theme"

	# Root background
	var sb_root := StyleBoxFlat.new()
	sb_root.bg_color = xp_face
	add_theme_stylebox_override("panel", sb_root)

	# Generic panel
	_sb_panel = StyleBoxFlat.new()
	_sb_panel.bg_color = xp_face
	_sb_panel.border_color = xp_ctrl_border
	_sb_panel.border_width_left = 1
	_sb_panel.border_width_top = 1
	_sb_panel.border_width_right = 1
	_sb_panel.border_width_bottom = 1
	_sb_panel.content_margin_left = 8
	_sb_panel.content_margin_right = 8
	_sb_panel.content_margin_top = 6
	_sb_panel.content_margin_bottom = 6

	_sb_panel_hover = _sb_panel.duplicate() as StyleBoxFlat
	_sb_panel_hover.border_color = xp_sel_blue

	# Drop zone
	_sb_drop_idle = _sb_panel.duplicate() as StyleBoxFlat
	_sb_drop_idle.bg_color = Color("1A2530") if _dark_mode else Color("EBF3FC")
	_sb_drop_idle.border_color = xp_ctrl_border

	_sb_drop_flash = _sb_panel.duplicate() as StyleBoxFlat
	_sb_drop_flash.bg_color = Color("2A2010") if _dark_mode else Color("FFF6D4")
	_sb_drop_flash.border_color = xp_btn_hover_border

	# Project card styles
	_sb_card = StyleBoxFlat.new()
	_sb_card.bg_color = xp_white
	_sb_card.border_color = xp_ctrl_border
	_sb_card.border_width_left = 1
	_sb_card.border_width_top = 1
	_sb_card.border_width_right = 1
	_sb_card.border_width_bottom = 1
	_sb_card.content_margin_left = 12
	_sb_card.content_margin_right = 12
	_sb_card.content_margin_top = 8
	_sb_card.content_margin_bottom = 8

	_sb_card_selected = _sb_card.duplicate() as StyleBoxFlat
	_sb_card_selected.bg_color = Color("2A2018") if _dark_mode else Color("D8D6C8")
	_sb_card_selected.border_color = xp_btn_hover_border if _dark_mode else xp_ctrl_shadow
	_sb_card_selected.border_width_left = 1
	_sb_card_selected.border_width_top = 1
	_sb_card_selected.border_width_right = 1
	_sb_card_selected.border_width_bottom = 1

	_sb_card_hover = _sb_card.duplicate() as StyleBoxFlat
	_sb_card_hover.bg_color = xp_btn_hover_face   # FFECC6 — matches button hover
	_sb_card_hover.border_color = xp_btn_hover_border

	# Slot box (filename / + button inside cards)
	_sb_slot_box = StyleBoxFlat.new()
	_sb_slot_box.bg_color = xp_white
	_sb_slot_box.border_color = xp_ctrl_border
	_sb_slot_box.border_width_left = 1
	_sb_slot_box.border_width_top = 1
	_sb_slot_box.border_width_right = 1
	_sb_slot_box.border_width_bottom = 1
	_sb_slot_box.content_margin_left = 6
	_sb_slot_box.content_margin_right = 6
	_sb_slot_box.content_margin_top = 2
	_sb_slot_box.content_margin_bottom = 2

	_sb_slot_box_hover = _sb_slot_box.duplicate() as StyleBoxFlat
	_sb_slot_box_hover.bg_color = xp_btn_hover_face
	_sb_slot_box_hover.border_color = xp_btn_hover_border

	# Buttons
	var sb_btn := StyleBoxFlat.new()
	sb_btn.bg_color = xp_btn_face
	sb_btn.border_color = xp_ctrl_border
	sb_btn.border_width_left = 1
	sb_btn.border_width_right = 1
	sb_btn.border_width_top = 1
	sb_btn.border_width_bottom = 1
	sb_btn.corner_radius_top_left = 3
	sb_btn.corner_radius_top_right = 3
	sb_btn.corner_radius_bottom_left = 3
	sb_btn.corner_radius_bottom_right = 3
	sb_btn.content_margin_left = 14
	sb_btn.content_margin_right = 14
	sb_btn.content_margin_top = 5
	sb_btn.content_margin_bottom = 5
	sb_btn.shadow_color = Color(0, 0, 0, 0.18)
	sb_btn.shadow_size = 1
	sb_btn.shadow_offset = Vector2(0, 1)

	var sb_btn_hover := sb_btn.duplicate() as StyleBoxFlat
	sb_btn_hover.bg_color = xp_btn_hover_face
	sb_btn_hover.border_color = xp_btn_hover_border

	var sb_btn_pressed := sb_btn.duplicate() as StyleBoxFlat
	sb_btn_pressed.bg_color = xp_btn_pressed_face
	sb_btn_pressed.border_color = xp_btn_pressed_border
	sb_btn_pressed.shadow_size = 0
	sb_btn_pressed.shadow_offset = Vector2(0, 0)

	var sb_btn_focus := sb_btn.duplicate() as StyleBoxFlat
	sb_btn_focus.border_color = xp_sel_blue
	sb_btn_focus.border_width_left = 2
	sb_btn_focus.border_width_right = 2
	sb_btn_focus.border_width_top = 2
	sb_btn_focus.border_width_bottom = 2

	_t.set_stylebox("normal", "Button", sb_btn)
	_t.set_stylebox("hover", "Button", sb_btn_hover)
	_t.set_stylebox("pressed", "Button", sb_btn_pressed)
	_t.set_stylebox("focus", "Button", sb_btn_focus)
	_t.set_color("font_color", "Button", xp_text)
	_t.set_color("font_hover_color", "Button", xp_text)
	_t.set_color("font_pressed_color", "Button", xp_text)
	_t.set_color("font_focus_color", "Button", xp_text)

	# LineEdit
	var sb_edit := StyleBoxFlat.new()
	sb_edit.bg_color = xp_white
	sb_edit.border_color = xp_ctrl_border
	sb_edit.border_width_left = 1
	sb_edit.border_width_right = 1
	sb_edit.border_width_top = 1
	sb_edit.border_width_bottom = 1
	sb_edit.content_margin_left = 6
	sb_edit.content_margin_right = 6
	sb_edit.content_margin_top = 3
	sb_edit.content_margin_bottom = 3
	_t.set_stylebox("normal", "LineEdit", sb_edit)
	var sb_edit_focus := sb_edit.duplicate() as StyleBoxFlat
	sb_edit_focus.border_color = xp_sel_blue
	_t.set_stylebox("focus", "LineEdit", sb_edit_focus)

	# RichTextLabel (output box)
	var sb_rtl := StyleBoxFlat.new()
	sb_rtl.bg_color = xp_white
	sb_rtl.border_color = xp_ctrl_border
	sb_rtl.border_width_left = 1
	sb_rtl.border_width_right = 1
	sb_rtl.border_width_top = 1
	sb_rtl.border_width_bottom = 1
	sb_rtl.content_margin_left = 6
	sb_rtl.content_margin_right = 6
	sb_rtl.content_margin_top = 4
	sb_rtl.content_margin_bottom = 4
	_t.set_stylebox("normal", "RichTextLabel", sb_rtl)

	# Labels
	_t.set_color("font_color", "Label", xp_text)
	_t.set_color("font_color", "LineEdit", xp_text)
	_t.set_stylebox("panel", "PanelContainer", _sb_panel)

	theme = _t

	# Per-node overrides
	var header: Label = $Margin/VBox/Header
	if header != null:
		header.add_theme_color_override("font_color", xp_title_blue)
	var subheader: Label = $Margin/VBox/Subheader
	if subheader != null:
		subheader.add_theme_color_override("font_color", xp_subtext)

	drop_hint.add_theme_color_override("font_color", xp_subtext)
	drop_title.add_theme_color_override("font_color", xp_title_blue)
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_idle)

	# Status bar
	_sb_status_bar = StyleBoxFlat.new()
	_sb_status_bar.bg_color = xp_face
	_sb_status_bar.border_color = xp_ctrl_shadow
	_sb_status_bar.border_width_left = 1
	_sb_status_bar.border_width_top = 1
	_sb_status_bar.border_width_right = 1
	_sb_status_bar.border_width_bottom = 1
	_sb_status_bar.content_margin_left = 8
	_sb_status_bar.content_margin_right = 8
	_sb_status_bar.content_margin_top = 3
	_sb_status_bar.content_margin_bottom = 3
	if status_bar != null:
		status_bar.add_theme_stylebox_override("panel", _sb_status_bar)

	# Output box text colour follows the theme
	if output_box != null:
		output_box.add_theme_color_override("default_color", xp_text)

func _flash_drop_zone() -> void:
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_flash)
	drop_title.text = "Dropped, staging..."
	await get_tree().create_timer(0.35).timeout
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_idle)
	drop_title.text = "Drop files here"
