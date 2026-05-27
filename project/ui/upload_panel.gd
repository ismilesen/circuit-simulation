extends Control

signal schematic_requested(path: String)
signal spice_paired(path: String)
signal dark_mode_changed(dark_mode: bool)
signal pdk_component_selected(component: Dictionary)

@export var simulator_path: NodePath = NodePath("..")
const SIM_SCRIPT_PATH := "res://simulator/circuit_simulator.gd"
const UPLOAD_DIR := "user://uploads"

const WORKSPACE_EXT := ".cvw.zip"
const WORKSPACE_MANIFEST := "manifest.json"
const WORKSPACE_FILES_DIR := "files/"
const WEB_PDK_CACHE_ROOT := "user://pdks/sky130"

var NETLIST_EXTS: PackedStringArray = PackedStringArray(["spice", "cir", "net", "txt", "lib", "model", "mod"])
var SCHEMATIC_EXTS: PackedStringArray = PackedStringArray(["sch"])
var SYMBOL_EXTS: PackedStringArray = PackedStringArray(["sym"])
var XSCHEM_EXTS: PackedStringArray = PackedStringArray(["sch", "sym"])
var SYMBOL_DIRS: PackedStringArray = PackedStringArray(["res://symbols", "res://symbols/sym"])

@onready var upload_button: Button = $Margin/VBox/ControlsCol/PrimaryRow/UploadButton
@onready var run_button: Button = $Margin/VBox/ControlsCol/PrimaryRow/RunButton
@onready var stop_reset_button: Button = $Margin/VBox/ControlsCol/PrimaryRow/StopResetButton
@onready var save_ws_button: Button = $Margin/VBox/ControlsCol/WorkspaceRow/SaveWorkspaceButton
@onready var load_ws_button: Button = $Margin/VBox/ControlsCol/WorkspaceRow/LoadWorkspaceButton
@onready var clear_button: Button = $Margin/VBox/ControlsCol/UtilityRow/ClearButton
@onready var theme_toggle_button: Button = $Margin/VBox/ControlsCol/UtilityRow/ThemeToggleButton

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
var support_files: Array[Dictionary] = []

var _pending_slot_project: int = -1
var _pending_slot_key: String = ""
var _selected_project: int = -1
var _dark_mode: bool = false
var _last_status_msg: String = "idle"
var _last_status_tone: StatusTone = StatusTone.IDLE

## Reference to the CircuitSimulator node (resolved lazily).
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
var _pdk_manifest: Variant = null
var _pdk_components: Array[Dictionary] = []
var _pdk_filtered_components: Array[Dictionary] = []
var _pdk_section: PanelContainer = null
var _pdk_search: LineEdit = null
var _pdk_list: ItemList = null
var _pdk_status: Label = null
var _pdk_models_ready: bool = false
var _pdk_model_request: HTTPRequest = null

var _external_re: RegEx = null
var _include_re: RegEx = null

# -------------------------------------------------------------------
# Ready
# -------------------------------------------------------------------

func _ready() -> void:
	_apply_theme()
	_ensure_upload_dir()
	_ensure_ws_name_popup()
	_setup_pdk_browser()

	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	file_dialog.use_native_dialog = true
	file_dialog.clear_filters()
	file_dialog.add_filter("*.sch, *.sym ; Xschem schematics/symbols")
	file_dialog.add_filter("*.spice, *.cir, *.net, *.txt, *.lib, *.model, *.mod ; SPICE netlists/models")
	file_dialog.add_filter("* ; All files")

	upload_button.pressed.connect(Callable(self, "_on_upload_pressed"))
	run_button.pressed.connect(Callable(self, "_on_run_pressed"))
	stop_reset_button.pressed.connect(Callable(self, "_on_stop_reset_pressed"))
	clear_button.pressed.connect(Callable(self, "_on_clear_pressed"))
	save_ws_button.pressed.connect(Callable(self, "_on_save_workspace_pressed"))
	load_ws_button.pressed.connect(Callable(self, "_on_load_workspace_pressed"))
	theme_toggle_button.pressed.connect(Callable(self, "_on_theme_toggle_pressed"))

	file_dialog.files_selected.connect(Callable(self, "_on_native_files_selected"))
	file_dialog.file_selected.connect(Callable(self, "_on_native_file_selected"))
	workspace_dialog.file_selected.connect(Callable(self, "_on_workspace_dialog_file_selected"))

	output_box.bbcode_enabled = true
	output_box.custom_minimum_size = Vector2(0, 120)
	output_box.fit_content = false
	output_box.scroll_active = true
	output_box.scroll_following = true
	output_box.mouse_filter = Control.MOUSE_FILTER_STOP
	output_box.gui_input.connect(Callable(self, "_on_output_box_gui_input"))
	output_box.add_theme_color_override("default_color", Color(0.10, 0.10, 0.10, 1))

	if not OS.has_feature("web"):
		if get_viewport() != null:
			if not get_viewport().files_dropped.is_connected(Callable(self, "_on_os_files_dropped")):
				get_viewport().files_dropped.connect(Callable(self, "_on_os_files_dropped"))

	_external_re = RegEx.new()
	_external_re.compile("(?i)\\bexternal\\b")
	_include_re = RegEx.new()
	_include_re.compile("(?i)^\\s*\\.(include|lib)\\s+([^\\s]+)")

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

func set_pdk_manifest(manifest: Variant) -> void:
	_pdk_manifest = manifest
	_pdk_components.clear()
	if manifest != null:
		for item: Dictionary in manifest.symbols:
			_pdk_components.append(item)
	_pdk_components.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var lib_a := str(a.get("library", ""))
		var lib_b := str(b.get("library", ""))
		if lib_a == lib_b:
			return str(a.get("id", "")) < str(b.get("id", ""))
		return lib_a < lib_b
	)
	_refresh_pdk_browser()

func _process(_delta: float) -> void:
	if OS.has_feature("web"):
		_poll_web_queue()


# -------------------------------------------------------------------
# PDK browser
# -------------------------------------------------------------------

func _setup_pdk_browser() -> void:
	var root_vbox := get_node_or_null("Margin/VBox")
	if root_vbox == null:
		return

	_pdk_section = PanelContainer.new()
	_pdk_section.name = "PdkComponentBrowser"
	_pdk_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pdk_section.custom_minimum_size = Vector2(0, 150)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_pdk_section.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var header := Label.new()
	header.text = "Sky130 Components"
	header.add_theme_font_size_override("font_size", 13)
	vbox.add_child(header)

	_pdk_search = LineEdit.new()
	_pdk_search.placeholder_text = "Search components"
	_pdk_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pdk_search.text_changed.connect(_on_pdk_search_changed)
	vbox.add_child(_pdk_search)

	_pdk_list = ItemList.new()
	_pdk_list.custom_minimum_size = Vector2(0, 78)
	_pdk_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pdk_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pdk_list.select_mode = ItemList.SELECT_SINGLE
	_pdk_list.item_selected.connect(_on_pdk_item_selected)
	vbox.add_child(_pdk_list)

	_pdk_status = Label.new()
	_pdk_status.text = "PDK manifest pending"
	_pdk_status.add_theme_font_size_override("font_size", 10)
	_pdk_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_pdk_status)

	var insert_index := root_vbox.get_children().find(drop_zone)
	if insert_index < 0:
		root_vbox.add_child(_pdk_section)
	else:
		root_vbox.add_child(_pdk_section)
		root_vbox.move_child(_pdk_section, insert_index)
	_refresh_pdk_browser()


func _refresh_pdk_browser() -> void:
	if _pdk_list == null:
		return

	_pdk_filtered_components.clear()
	_pdk_list.clear()

	var query := ""
	if _pdk_search != null:
		query = _pdk_search.text.strip_edges().to_lower()

	for component: Dictionary in _pdk_components:
		if not _pdk_component_matches(component, query):
			continue
		_pdk_filtered_components.append(component)
		if _pdk_filtered_components.size() >= 80:
			break

	for component: Dictionary in _pdk_filtered_components:
		var label := "%s/%s" % [str(component.get("library", "")), str(component.get("id", ""))]
		var type_name := str(component.get("type", ""))
		if type_name != "":
			label += "  " + type_name
		_pdk_list.add_item(label)

	if _pdk_status != null:
		if _pdk_components.is_empty():
			_pdk_status.text = "PDK manifest pending"
		else:
			_pdk_status.text = "%d loaded, %d shown" % [_pdk_components.size(), _pdk_filtered_components.size()]


func _pdk_component_matches(component: Dictionary, query: String) -> bool:
	if query == "":
		return true
	var haystack := "%s %s %s %s" % [
		str(component.get("id", "")),
		str(component.get("name", "")),
		str(component.get("library", "")),
		str(component.get("type", "")),
	]
	return haystack.to_lower().contains(query)


func _on_pdk_search_changed(_text: String) -> void:
	_refresh_pdk_browser()


func _on_pdk_item_selected(index: int) -> void:
	if index < 0 or index >= _pdk_filtered_components.size():
		return
	var component := _pdk_filtered_components[index]
	pdk_component_selected.emit(component)
	var type_name := str(component.get("type", "component"))
	_refresh_status("selected %s" % str(component.get("id", "")), StatusTone.OK)
	_log("[color=#336699][b]PDK:[/b][/color] Selected %s (%s)." % [
		str(component.get("id", "")),
		type_name,
	])

# -------------------------------------------------------------------
# Upload flows
# -------------------------------------------------------------------

func _on_upload_pressed() -> void:
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
	if XSCHEM_EXTS.has(path.get_extension().to_lower()):
		_resolve_autogen_projects()

func _on_native_files_selected(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var schematic_paths: Array[String] = []
	var symbol_paths: Array[String] = []
	var spice_paths: Array[String] = []
	for p: String in paths:
		if p.strip_edges() == "":
			continue
		var ext := p.get_extension().to_lower()
		if SCHEMATIC_EXTS.has(ext):
			schematic_paths.append(p)
		elif SYMBOL_EXTS.has(ext):
			symbol_paths.append(p)
		elif NETLIST_EXTS.has(ext):
			spice_paths.append(p)

	if _pending_slot_project >= 0:
		if paths.size() > 1:
			_set_error("Select exactly one file when filling a project slot.")
			_pending_slot_project = -1
			_pending_slot_key = ""
			return
	else:
		if schematic_paths.size() > 1:
			_set_error("Please select at most one schematic file (.sch) at a time.")
			return

	var added := 0
	for p in schematic_paths:
		if _stage_native_file(p):
			added += 1
	for p in symbol_paths:
		if _stage_native_file(p):
			added += 1
	for p in spice_paths:
		if _stage_native_file(p):
			added += 1

	if not schematic_paths.is_empty() or not symbol_paths.is_empty():
		_resolve_autogen_projects()

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
	var saw_xschem := false
	for p: String in files:
		if p.strip_edges() == "":
			continue
		if XSCHEM_EXTS.has(p.get_extension().to_lower()):
			saw_xschem = true
		added += int(_stage_native_file(p))

	if saw_xschem:
		_resolve_autogen_projects()

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
	elif SCHEMATIC_EXTS.has(ext):
		_assign_xschem(slot)
	elif SYMBOL_EXTS.has(ext):
		_log("[color=#336699][b]Info:[/b][/color] Added symbol file for xschem2spice lookup.")
	elif NETLIST_EXTS.has(ext):
		var analysis := _analyze_spice_file(user_path)
		slot["spice_analysis"] = analysis
		if _should_stage_as_support_file(slot, analysis):
			_assign_support_file(slot)
		_assign_spice(slot)
	else:
		_log("[color=#b56a00][b]Warning:[/b][/color] Unrecognised extension '%s', skipped." % ext)
		return false

	_rebuild_cards()
	_recheck_all_project_dependencies(true)
	_rebuild_cards()
	_log("[color=#336699][b]Info:[/b][/color] Staged %s (%d bytes) -> %s" % [
		safe_name,
		bytes.size(),
		user_path,
	])
	return true

# -------------------------------------------------------------------
# Project slot assignment
# -------------------------------------------------------------------

func _assign_spice(slot: Dictionary) -> void:
	var basename := (slot["display"] as String).get_basename()
	for i in projects.size():
		var proj: Dictionary = projects[i]
		if str(proj.get("name", "")) != basename:
			continue
		proj["spice"] = slot
		proj["complete"] = true
		projects[i] = proj
		_selected_project = i
		spice_paired.emit(str(slot.get("user_path", "")))
		_log("[color=#336699][b]Info:[/b][/color] Replaced SPICE for project '%s'." % basename)
		return

	projects.append({
		"name": basename,
		"xschem": null,
		"spice": slot,
		"complete": true,
		"buttons": [],
		"switch_states": {}
	})
	spice_paired.emit(str(slot.get("user_path", "")))

func _assign_support_file(slot: Dictionary) -> void:
	var path := str(slot.get("user_path", ""))
	for i in support_files.size():
		if str((support_files[i] as Dictionary).get("display", "")) == str(slot.get("display", "")):
			support_files[i] = slot
			_log("[color=#336699][b]Info:[/b][/color] Replaced support file %s." % str(slot.get("display", "")))
			return
	support_files.append(slot)
	_log("[color=#336699][b]Info:[/b][/color] Added support SPICE/model file %s." % path)

func _should_stage_as_support_file(slot: Dictionary, analysis: Dictionary) -> bool:
	if _pending_slot_project >= 0:
		return false
	if _netlist_satisfies_missing_dependency(slot, analysis):
		return true
	var display := str(slot.get("display", "")).to_lower()
	if display.ends_with(".lib") or display.ends_with(".model") or display.ends_with(".mod"):
		return true
	if not (analysis.get("subckt_defs", []) as Array).is_empty() and (analysis.get("subckt_calls", []) as Array).is_empty():
		return true
	if projects.is_empty():
		return false
	if not _has_primary_netlist():
		return false
	if not (analysis.get("subckt_defs", []) as Array).is_empty():
		return true
	return false

func _has_primary_netlist() -> bool:
	for proj in projects:
		if proj.get("spice") != null:
			return true
	return false

func _netlist_satisfies_missing_dependency(slot: Dictionary, analysis: Dictionary) -> bool:
	var display := str(slot.get("display", "")).to_lower()
	var defs := _array_to_lookup(analysis.get("subckt_defs", []))
	for proj in projects:
		if proj.get("spice") == null:
			continue
		var report := _check_project_subcircuit_files(proj, false)
		for missing_v in (report.get("missing_subckts", []) as Array):
			if defs.has(str(missing_v).to_lower()):
				return true
		for include_v in (report.get("missing_includes", []) as Array):
			if str(include_v).get_file().to_lower() == display:
				return true
	return false

func _analyze_spice_file(user_path: String) -> Dictionary:
	var report: Dictionary = {
		"subckt_defs": [],
		"subckt_calls": [],
		"include_paths": []
	}
	var f := FileAccess.open(user_path, FileAccess.READ)
	if f == null:
		return report
	var physical: Array[String] = []
	while not f.eof_reached():
		physical.append(f.get_line())
	f.close()

	var lines := _spice_logical_lines(physical)
	var defs: Dictionary = {}
	var calls: Dictionary = {}
	var includes: Dictionary = {}
	for raw_line in lines:
		var line := _strip_spice_comment(str(raw_line)).strip_edges()
		if line == "":
			continue
		var lower := line.to_lower()
		if lower.begins_with(".subckt"):
			var parts := line.split(" ", false)
			if parts.size() >= 2:
				defs[str(parts[1]).to_lower()] = str(parts[1])
			continue
		if lower.begins_with(".include") or lower.begins_with(".lib"):
			var include_path := _extract_include_path(line)
			if include_path != "":
				includes[include_path.to_lower()] = include_path
			continue
		if lower.begins_with("x"):
			var subckt_name := _extract_subckt_call_name(line)
			if subckt_name != "":
				calls[subckt_name.to_lower()] = subckt_name
	report["subckt_defs"] = _lookup_values(defs)
	report["subckt_calls"] = _lookup_values(calls)
	report["include_paths"] = _lookup_values(includes)
	return report

func _spice_logical_lines(physical: Array[String]) -> Array[String]:
	var logical: Array[String] = []
	for raw in physical:
		var line := str(raw).strip_edges()
		if line.begins_with("+") and not logical.is_empty():
			logical[logical.size() - 1] = str(logical[logical.size() - 1]) + " " + line.substr(1).strip_edges()
		else:
			logical.append(str(raw))
	return logical

func _strip_spice_comment(line: String) -> String:
	var trimmed := line.strip_edges()
	if trimmed.begins_with("*"):
		return ""
	var semicolon := line.find(";")
	if semicolon >= 0:
		return line.substr(0, semicolon)
	return line

func _extract_include_path(line: String) -> String:
	if _include_re == null:
		return ""
	var m := _include_re.search(line)
	if m == null:
		return ""
	return _unquote(str(m.get_string(2)).strip_edges())

func _extract_subckt_call_name(line: String) -> String:
	var tokens := line.split(" ", false)
	if tokens.size() < 2:
		return ""
	for i in range(tokens.size() - 1, 0, -1):
		var token := str(tokens[i]).strip_edges()
		var lower := token.to_lower()
		if token == "" or token.find("=") >= 0 or lower == "params:":
			continue
		return token
	return ""

func _check_project_subcircuit_files(proj: Dictionary, prompt: bool = true) -> Dictionary:
	var report: Dictionary = {
		"ok": true,
		"missing_subckts": [],
		"missing_includes": [],
		"defined_subckts": [],
		"called_subckts": []
	}
	var spice_v: Variant = proj.get("spice", null)
	if typeof(spice_v) != TYPE_DICTIONARY:
		return report

	var spice_entry := spice_v as Dictionary
	var spice_path := str(spice_entry.get("user_path", ""))
	var root_analysis := _analysis_for_entry(spice_entry)
	var definitions := _array_to_lookup(root_analysis.get("subckt_defs", []))
	var calls := _array_to_lookup(root_analysis.get("subckt_calls", []))
	var missing_includes: Dictionary = {}

	for support_entry in _support_entries_for_project(spice_path):
		var support_analysis := _analysis_for_entry(support_entry)
		for def_v in (support_analysis.get("subckt_defs", []) as Array):
			definitions[str(def_v).to_lower()] = str(def_v)

	for include_v in (root_analysis.get("include_paths", []) as Array):
		var include_path := str(include_v)
		if not _include_file_is_available(include_path, spice_path):
			missing_includes[include_path.to_lower()] = include_path

	var missing_subckts: Dictionary = {}
	for call_key in calls.keys():
		if not definitions.has(call_key):
			missing_subckts[call_key] = calls[call_key]

	report["defined_subckts"] = _lookup_values(definitions)
	report["called_subckts"] = _lookup_values(calls)
	report["missing_subckts"] = _lookup_values(missing_subckts)
	report["missing_includes"] = _lookup_values(missing_includes)
	report["ok"] = (missing_subckts.is_empty() and missing_includes.is_empty())
	if prompt and not bool(report["ok"]):
		_prompt_missing_subcircuit_files(proj, report)
	return report

func _analysis_for_entry(entry: Dictionary) -> Dictionary:
	var analysis_v: Variant = entry.get("spice_analysis", null)
	if typeof(analysis_v) == TYPE_DICTIONARY:
		return analysis_v as Dictionary
	var analysis := _analyze_spice_file(str(entry.get("user_path", "")))
	entry["spice_analysis"] = analysis
	return analysis

func _support_entries_for_project(spice_path: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for support_v in support_files:
		var support := support_v as Dictionary
		if str(support.get("user_path", "")) != spice_path:
			entries.append(support)
	for proj in projects:
		var spice_v: Variant = proj.get("spice", null)
		if typeof(spice_v) != TYPE_DICTIONARY:
			continue
		var spice := spice_v as Dictionary
		if str(spice.get("user_path", "")) != spice_path:
			entries.append(spice)
	return entries

func _include_file_is_available(include_path: String, spice_path: String) -> bool:
	if include_path == "":
		return false
	if include_path.begins_with("user://") or include_path.begins_with("res://"):
		return FileAccess.file_exists(include_path)
	var base_dir := spice_path.get_base_dir()
	if FileAccess.file_exists("%s/%s" % [base_dir, include_path]):
		return true
	var wanted := include_path.get_file().to_lower()
	for entry in support_files:
		if str((entry as Dictionary).get("display", "")).to_lower() == wanted:
			return true
	for proj in projects:
		var spice_v: Variant = proj.get("spice", null)
		if typeof(spice_v) == TYPE_DICTIONARY and str((spice_v as Dictionary).get("display", "")).to_lower() == wanted:
			return true
	return false

func _prompt_missing_subcircuit_files(proj: Dictionary, report: Dictionary) -> void:
	var pieces: Array[String] = []
	var missing_subckts := report.get("missing_subckts", []) as Array
	var missing_includes := report.get("missing_includes", []) as Array
	if not missing_subckts.is_empty():
		pieces.append("definitions for: %s" % ", ".join(_array_to_packed_strings(missing_subckts)))
	if not missing_includes.is_empty():
		var include_names := PackedStringArray()
		for include_v in missing_includes:
			include_names.append(str(include_v).get_file())
		pieces.append("included files: %s" % ", ".join(include_names))
	_refresh_status("upload missing subcircuit file(s)", StatusTone.WARN)
	_log("[color=#b56a00][b]Missing subcircuit files:[/b][/color] Project '%s' needs %s. Upload the matching .spice/.cir/.net/.txt/.lib model file(s), then run again." % [
		str(proj.get("name", "unnamed")),
		"; ".join(pieces)
	])

func _recheck_all_project_dependencies(prompt_missing: bool = false) -> void:
	for proj in projects:
		if proj.get("spice") == null:
			continue
		var report := _check_project_subcircuit_files(proj, prompt_missing)
		if bool(report.get("ok", true)) and not (report.get("called_subckts", []) as Array).is_empty():
			_log("[color=darkgreen][b]OK:[/b][/color] Subcircuit files resolved for project '%s'." % str(proj.get("name", "unnamed")))

func _array_to_lookup(values_v: Variant) -> Dictionary:
	var lookup: Dictionary = {}
	if typeof(values_v) != TYPE_ARRAY:
		return lookup
	for value_v in (values_v as Array):
		var value := str(value_v)
		if value != "":
			lookup[value.to_lower()] = value
	return lookup

func _lookup_values(lookup: Dictionary) -> Array:
	var values: Array = []
	var keys := lookup.keys()
	keys.sort()
	for key in keys:
		values.append(lookup[key])
	return values

func _array_to_packed_strings(values: Array) -> PackedStringArray:
	var packed := PackedStringArray()
	for value in values:
		packed.append(str(value))
	return packed

func _unquote(value: String) -> String:
	if value.length() >= 2:
		var first := value.substr(0, 1)
		var last := value.substr(value.length() - 1, 1)
		if (first == "\"" and last == "\"") or (first == "'" and last == "'"):
			return value.substr(1, value.length() - 2)
	return value

func _assign_xschem(slot: Dictionary) -> void:
	var buttons := _parse_buttons_from_sch(str(slot.get("user_path", "")))
	var sw: Dictionary = {}
	for b in buttons:
		sw[b] = false
	for proj in projects:
		if proj["xschem"] == null:
			proj["xschem"] = slot
			proj["complete"] = proj["spice"] != null
			proj["buttons"] = buttons
			proj["switch_states"] = sw
			schematic_requested.emit(str(slot.get("user_path", "")))
			return
	var basename := (slot["display"] as String).get_basename()
	projects.append({
		"name": basename,
		"xschem": slot,
		"spice": null,
		"complete": false,
		"buttons": buttons,
		"switch_states": sw
	})
	schematic_requested.emit(str(slot.get("user_path", "")))

func _assign_to_pending_slot(slot: Dictionary) -> void:
	var idx := _pending_slot_project
	var key := _pending_slot_key
	_pending_slot_project = -1
	_pending_slot_key = ""

	if idx < 0 or idx >= projects.size():
		var ext := str(slot.get("ext", ""))
		if SCHEMATIC_EXTS.has(ext):
			_assign_xschem(slot)
		elif SYMBOL_EXTS.has(ext):
			_resolve_autogen_projects()
		elif NETLIST_EXTS.has(ext):
			_assign_spice(slot)
		return

	var ext := str(slot.get("ext", ""))
	var proj := projects[idx]

	if key == "spice":
		if not NETLIST_EXTS.has(ext):
			_set_error("Expected a spice/netlist file (.spice/.cir/.net/.txt/.lib/.model/.mod) for this slot.")
			return
		proj["spice"] = slot
		proj["name"] = (slot["display"] as String).get_basename()
		proj["complete"] = true
		spice_paired.emit(str(slot.get("user_path", "")))

	elif key == "xschem":
		if not SCHEMATIC_EXTS.has(ext):
			_set_error("Expected an xschem schematic file (.sch) for this slot.")
			return
		proj["xschem"] = slot
		proj["complete"] = proj["spice"] != null
		var buttons := _parse_buttons_from_sch(str(slot.get("user_path", "")))
		var sw: Dictionary = {}
		for b in buttons:
			sw[b] = false
		proj["buttons"] = buttons
		proj["switch_states"] = sw
		schematic_requested.emit(str(slot.get("user_path", "")))
		_resolve_autogen_projects()

# -------------------------------------------------------------------
# Automatic xschem -> SPICE conversion
# -------------------------------------------------------------------

func _resolve_autogen_projects() -> void:
	for proj in projects:
		if proj.get("xschem") != null and proj.get("spice") == null:
			_auto_generate_spice(proj)

func _auto_generate_spice(proj: Dictionary) -> bool:
	var xschem_slot_v: Variant = proj.get("xschem")
	if typeof(xschem_slot_v) != TYPE_DICTIONARY:
		return false

	var xschem_slot := xschem_slot_v as Dictionary
	if str(xschem_slot.get("ext", "")).to_lower() != "sch":
		return false

	var sch_user_path := str(xschem_slot.get("user_path", ""))
	if sch_user_path == "":
		return false

	var sim := _resolve_simulator()
	if sim == null or not sim.has_method("xschem_to_spice"):
		_set_error("xschem2spice is unavailable. Rebuild the GDExtension after initializing submodules.")
		return false

	_ensure_upload_dir()
	var base := str(xschem_slot.get("display", "schematic")).get_basename()
	var out_user_path := _avoid_collision("%s/%s.spice" % [UPLOAD_DIR, base])
	var sch_os_path := ProjectSettings.globalize_path(sch_user_path)
	var out_os_path := ProjectSettings.globalize_path(out_user_path)

	var symbol_dirs := PackedStringArray()
	for d in SYMBOL_DIRS:
		symbol_dirs.append(ProjectSettings.globalize_path(d))
	symbol_dirs.append(ProjectSettings.globalize_path(UPLOAD_DIR))

	var res_v: Variant = sim.call("xschem_to_spice", sch_os_path, out_os_path, "", symbol_dirs)
	if typeof(res_v) != TYPE_DICTIONARY:
		_set_error("xschem2spice returned an unexpected result.")
		return false

	var res := res_v as Dictionary
	if not bool(res.get("ok", false)):
		_set_error("xschem2spice failed for %s: %s" % [base, str(res.get("error", "unknown error"))])
		return false

	var out_bytes := 0
	var fa := FileAccess.open(out_user_path, FileAccess.READ)
	if fa != null:
		out_bytes = fa.get_length()
		fa.close()

	var spice_slot: Dictionary = {
		"display": out_user_path.get_file(),
		"user_path": out_user_path,
		"bytes": out_bytes,
		"ext": "spice",
		"autogenerated": true
	}
	proj["spice"] = spice_slot
	proj["complete"] = true
	spice_paired.emit(out_user_path)
	_log("[color=darkgreen][b]OK:[/b][/color] Generated %s with xschem2spice." % str(spice_slot["display"]))
	_check_project_subcircuit_files(proj, true)
	_rebuild_cards()
	return true

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
	var schematic_count := 0
	var symbol_count := 0
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
		if SCHEMATIC_EXTS.has(ext):
			schematic_count += 1
		elif SYMBOL_EXTS.has(ext):
			symbol_count += 1
		elif NETLIST_EXTS.has(ext):
			spice_count += 1
		entries.append({"name": filename, "bytes": bytes})

	if _pending_slot_project < 0:
		if schematic_count > 1:
			_set_error("Please select at most one schematic file (.sch) per upload.")
			return

	var added := 0
	for e in entries:
		if _stage_bytes(str(e["name"]), e["bytes"] as PackedByteArray):
			added += 1

	if schematic_count > 0 or symbol_count > 0:
		_resolve_autogen_projects()

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
		_set_error("No runnable project. Upload a SPICE netlist, or upload a .sch file so xschem2spice can generate one.")
		return

	_sim = _resolve_simulator()
	if _sim == null:
		_set_error("Could not find CircuitSimulator node.")
		return
	if not _sim.has_method("run_continuous"):
		_set_error("Resolved node lacks run_continuous().")
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
	var dep_report := _check_project_subcircuit_files(selected_proj, true)
	if not bool(dep_report.get("ok", true)):
		return
	var spice_user_path := str(spice_entry["user_path"])

	var switch_states: Dictionary = selected_proj.get("switch_states", {})
	if not switch_states.is_empty():
		var patched := _patch_spice_for_switches(spice_user_path, switch_states)
		if patched != "":
			spice_user_path = patched

	var support_patched := _patch_spice_for_subcircuit_support(spice_user_path, selected_proj)
	if support_patched != "":
		spice_user_path = support_patched

	# Web uploads live behind Godot's user:// filesystem; the simulator can read that path directly.
	var sim_path := spice_user_path if OS.has_feature("web") else ProjectSettings.globalize_path(spice_user_path)

	if OS.has_feature("web"):
		if _pdk_manifest == null:
			_set_error("Sky130 PDK manifest is not ready yet. Wait for the PDK manifest to load, then run again.")
			return
		_refresh_status("preparing PDK models...", StatusTone.WARN)
		var pdk_ok: bool = await _ensure_web_pdk_models_ready()
		if not pdk_ok:
			_set_error("Could not prepare Sky130 model files for browser simulation.")
			return

	_refresh_status("starting simulation...", StatusTone.WARN)
	_log_spice_run_context(spice_entry)

	# Single call: C++ handles initialization, netlist loading, and bg_run.
	var ok: bool = bool(_sim.call("run_continuous", sim_path))
	if not ok:
		_set_error("run_continuous() failed.")
		return

	_refresh_status("simulation running", StatusTone.OK)
	_log("[color=darkgreen][b]OK:[/b][/color] Continuous simulation started.")


func _on_stop_reset_pressed() -> void:
	_sim = _resolve_simulator()
	if _sim == null:
		_set_error("Could not find CircuitSimulator node.")
		return

	_refresh_status("resetting simulation...", StatusTone.WARN)
	if _sim.has_method("reset_simulation"):
		var ok := bool(_sim.call("reset_simulation"))
		if not ok:
			_set_error("ngspice reset failed.")
			return
	elif _sim.has_method("stop_continuous"):
		_sim.call("stop_continuous")
		_log("[color=#b56a00][b]Warning:[/b][/color] Native reset_simulation() is unavailable; replacing the simulator node for this reset.")
		var replacement := await _replace_legacy_simulator(_sim)
		if replacement == null:
			_set_error("Could not recreate CircuitSimulator node.")
			return
		_sim = replacement
		simulator_path = get_path_to(_sim)
		_notify_simulator_replaced(_sim)
	else:
		_set_error("Resolved node lacks reset_simulation().")
		return

	_refresh_status("simulation reset", StatusTone.OK)
	_log("[color=darkgreen][b]OK:[/b][/color] Simulation stopped and ngspice reset.")


func _replace_legacy_simulator(old_sim: Node) -> Node:
	var parent := old_sim.get_parent()
	var replacement_name := str(old_sim.name)
	if parent == null:
		parent = get_tree().root
	if replacement_name == "":
		replacement_name = "CircuitSimulator"

	old_sim.queue_free()
	await get_tree().process_frame

	var sim_script: Resource = load(SIM_SCRIPT_PATH)
	if not (sim_script is GDScript):
		return null

	var created: Variant = (sim_script as GDScript).new()
	if not (created is Node):
		return null

	var replacement := created as Node
	replacement.name = replacement_name
	parent.add_child(replacement)
	return replacement


func _notify_simulator_replaced(simulator: Node) -> void:
	var root := get_tree().root
	if root == null:
		return

	for node in root.find_children("*", "", true, false):
		if not (node is Node):
			continue
		var n := node as Node
		if n.has_method("set_simulator_node"):
			n.call("set_simulator_node", simulator)
		if n.has_method("reset_simulation_view"):
			n.call("reset_simulation_view")


func _log_spice_run_context(spice_entry: Dictionary) -> void:
	var user_path := str(spice_entry.get("user_path", ""))
	var byte_count := int(spice_entry.get("bytes", 0))
	_log("[color=#336699][b]Info:[/b][/color] Running SPICE file: %s (%d bytes)." % [
		user_path,
		byte_count,
	])

	var f := FileAccess.open(user_path, FileAccess.READ)
	if f == null:
		_log("[color=#b56a00][b]Warning:[/b][/color] Could not reopen SPICE file for preview.")
		return
	var text := f.get_as_text()
	f.close()

	var preview_lines: Array[String] = []
	for raw_line in text.split("\n"):
		var line := str(raw_line).strip_edges()
		if line == "":
			continue
		var lower := line.to_lower()
		if lower.begins_with("xm_") or lower.begins_with(".lib") or lower.begins_with(".include"):
			preview_lines.append(line)
		if preview_lines.size() >= 4:
			break

	if preview_lines.is_empty():
		return
	_log("[color=#336699][b]Info:[/b][/color] SPICE preview: %s" % " | ".join(preview_lines))


func _ensure_web_pdk_models_ready() -> bool:
	if _pdk_models_ready:
		return true
	if _pdk_manifest == null:
		return false

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WEB_PDK_CACHE_ROOT))
	if _pdk_model_request == null:
		_pdk_model_request = HTTPRequest.new()
		_pdk_model_request.name = "PdkModelRequest"
		add_child(_pdk_model_request)

	var model_files: Array[Dictionary] = []
	for entry: Dictionary in _pdk_manifest.files:
		var rel_path := str(entry.get("path", ""))
		if rel_path.begins_with("models/"):
			model_files.append(entry)

	if model_files.is_empty():
		return false

	var done := 0
	for entry: Dictionary in model_files:
		done += 1
		if done == 1 or done % 50 == 0 or done == model_files.size():
			_refresh_status("preparing PDK %d/%d" % [done, model_files.size()], StatusTone.WARN)
		if not await _fetch_and_cache_pdk_file(entry):
			return false

	_pdk_models_ready = true
	_refresh_status("PDK models ready", StatusTone.OK)
	return true


func _fetch_and_cache_pdk_file(entry: Dictionary) -> bool:
	var rel_path := str(entry.get("path", ""))
	if rel_path == "":
		return true

	var cache_path := "%s/%s" % [WEB_PDK_CACHE_ROOT, rel_path]
	if FileAccess.file_exists(cache_path):
		return true

	var dir_path := cache_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))

	var url := _resolve_web_asset_url("pdks/sky130/" + rel_path)
	var err := _pdk_model_request.request(url)
	if err != OK:
		_log("[color=#b00020][b]Error:[/b][/color] Could not request PDK file: %s" % url)
		return false

	var completed: Array = await _pdk_model_request.request_completed
	var result := int(completed[0])
	var response_code := int(completed[1])
	var body: PackedByteArray = completed[3]
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_log("[color=#b00020][b]Error:[/b][/color] Could not fetch PDK file %s (HTTP %d, result %d)." % [
			rel_path,
			response_code,
			result,
		])
		return false

	var file := FileAccess.open(cache_path, FileAccess.WRITE)
	if file == null:
		_log("[color=#b00020][b]Error:[/b][/color] Could not cache PDK file: %s" % cache_path)
		return false
	file.store_buffer(body)
	file.close()
	return true


func _resolve_web_asset_url(path: String) -> String:
	var relative := path.trim_prefix("/")
	var script := """
		(() => {
			const base = window.location.href.replace(/[#?].*$/, "").replace(/[^/]*$/, "");
			return new URL("%s", base).toString();
		})()
	""" % relative.json_escape()
	var resolved: Variant = JavaScriptBridge.eval(script, true)
	if typeof(resolved) == TYPE_STRING and str(resolved) != "":
		return str(resolved)
	return relative

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
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.clip_contents = true

	card.gui_input.connect(_on_card_gui_input.bind(idx))

	card.mouse_entered.connect(func():
		if idx != _selected_project:
			card.add_theme_stylebox_override("panel", _sb_card_hover.duplicate())
	)
	card.mouse_exited.connect(func():
		if idx != _selected_project:
			card.add_theme_stylebox_override("panel", _sb_card.duplicate())
	)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 4)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_child(vbox)

	var title_row := HBoxContainer.new()
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_theme_constant_override("separation", 6)
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.clip_contents = true
	vbox.add_child(title_row)

	var file_row := HBoxContainer.new()
	file_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	file_row.add_theme_constant_override("separation", 6)
	file_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_row.clip_contents = true
	vbox.add_child(file_row)

	var col_primary: Color   = Color("E0DDD4") if _dark_mode else Color(0, 0, 0)
	var col_secondary: Color = Color("8A8880") if _dark_mode else Color("606060")
	var col_mid: Color       = Color("9A9890") if _dark_mode else Color("404040")
	var dep_report := _check_project_subcircuit_files(proj, false)
	var has_missing_deps := not bool(dep_report.get("ok", true))

	if has_missing_deps:
		title_row.add_child(_build_dependency_error_badge(dep_report))

	var title_lbl := Label.new()
	title_lbl.text = "%s:" % str(proj["name"])
	title_lbl.add_theme_color_override("font_color", col_primary)
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.custom_minimum_size = Vector2(0, 0)
	title_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_lbl.tooltip_text = str(proj["name"])
	title_row.add_child(title_lbl)

	var total_bytes := 0
	if proj["spice"] != null:
		total_bytes += int((proj["spice"] as Dictionary).get("bytes", 0))
	if proj["xschem"] != null:
		total_bytes += int((proj["xschem"] as Dictionary).get("bytes", 0))
	var size_lbl := Label.new()
	size_lbl.text = _human_size(total_bytes)
	size_lbl.add_theme_color_override("font_color", col_secondary)
	size_lbl.add_theme_font_size_override("font_size", 12)
	size_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_row.add_child(size_lbl)

	file_row.add_child(_build_slot_control(idx, "spice", proj["spice"]))

	var spice_ext_lbl := Label.new()
	spice_ext_lbl.text = ".spice"
	spice_ext_lbl.add_theme_color_override("font_color", col_secondary)
	spice_ext_lbl.add_theme_font_size_override("font_size", 12)
	spice_ext_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	file_row.add_child(spice_ext_lbl)

	var and_lbl := Label.new()
	and_lbl.text = "  and  "
	and_lbl.add_theme_color_override("font_color", col_mid)
	and_lbl.add_theme_font_size_override("font_size", 12)
	and_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	file_row.add_child(and_lbl)

	file_row.add_child(_build_slot_control(idx, "xschem", proj["xschem"]))

	var sch_ext := ".sch"
	if proj["xschem"] != null:
		sch_ext = ".%s" % str((proj["xschem"] as Dictionary).get("ext", "sch"))
	var xschem_ext_lbl := Label.new()
	xschem_ext_lbl.text = sch_ext
	xschem_ext_lbl.add_theme_color_override("font_color", col_secondary)
	xschem_ext_lbl.add_theme_font_size_override("font_size", 12)
	xschem_ext_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	file_row.add_child(xschem_ext_lbl)

	var buttons: Array = proj.get("buttons", [])
	if buttons.size() > 0:
		var sw_row := HBoxContainer.new()
		sw_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sw_row.add_theme_constant_override("separation", 8)
		vbox.add_child(sw_row)

		var sw_lbl := Label.new()
		sw_lbl.text = "Switches:"
		sw_lbl.add_theme_color_override("font_color", col_secondary)
		sw_lbl.add_theme_font_size_override("font_size", 12)
		sw_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sw_row.add_child(sw_lbl)

		var sw_states: Dictionary = proj.get("switch_states", {})
		for btn_name_v in buttons:
			var btn_name := str(btn_name_v)
			var toggle := CheckButton.new()
			toggle.text = btn_name
			toggle.button_pressed = bool(sw_states.get(btn_name, false))
			toggle.add_theme_font_size_override("font_size", 12)
			toggle.mouse_filter = Control.MOUSE_FILTER_STOP
			toggle.toggled.connect(func(on: bool): _on_switch_toggled(idx, btn_name, on))
			sw_row.add_child(toggle)

	return card

func _build_dependency_error_badge(report: Dictionary) -> Control:
	var badge := PanelContainer.new()
	badge.mouse_filter = Control.MOUSE_FILTER_STOP
	badge.tooltip_text = _dependency_error_tooltip(report)
	badge.custom_minimum_size = Vector2(18, 18)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("5A1818") if _dark_mode else Color("FFE1DA")
	sb.border_color = Color("E05040") if _dark_mode else Color("CC2200")
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 2
	sb.corner_radius_top_right = 2
	sb.corner_radius_bottom_left = 2
	sb.corner_radius_bottom_right = 2
	sb.content_margin_left = 5
	sb.content_margin_right = 5
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	badge.add_theme_stylebox_override("panel", sb)

	var lbl := Label.new()
	lbl.text = "!"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color("FFD6D0") if _dark_mode else Color("B02010"))
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_child(lbl)
	return badge

func _dependency_error_tooltip(report: Dictionary) -> String:
	var parts: Array[String] = []
	var missing_subckts := report.get("missing_subckts", []) as Array
	if not missing_subckts.is_empty():
		parts.append("Missing subcircuits: %s" % ", ".join(_array_to_packed_strings(missing_subckts)))
	var missing_includes := report.get("missing_includes", []) as Array
	if not missing_includes.is_empty():
		var include_names := PackedStringArray()
		for include_v in missing_includes:
			include_names.append(str(include_v).get_file())
		parts.append("Missing include files: %s" % ", ".join(include_names))
	if parts.is_empty():
		return "Subcircuit files resolved"
	return "\n".join(parts)

func _build_slot_control(proj_idx: int, slot_key: String, slot_data: Variant) -> Control:
	if slot_data != null:
		var container := PanelContainer.new()
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		container.add_theme_stylebox_override("panel", _sb_slot_box.duplicate())
		container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.custom_minimum_size = Vector2(48, 0)
		container.clip_contents = true
		var lbl := Label.new()
		var display := (str((slot_data as Dictionary).get("display", ""))).get_basename()
		lbl.text = display
		lbl.add_theme_color_override("font_color", Color("E0DDD4") if _dark_mode else Color(0, 0, 0))
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.custom_minimum_size = Vector2(0, 0)
		lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		lbl.tooltip_text = display
		container.add_child(lbl)
		return container
	else:
		var btn := Button.new()
		btn.text = "  +  "
		btn.add_theme_stylebox_override("normal", _sb_slot_box.duplicate())
		btn.add_theme_stylebox_override("hover", _sb_slot_box_hover.duplicate())
		btn.add_theme_stylebox_override("pressed", _sb_slot_box.duplicate())
		btn.add_theme_stylebox_override("focus", _sb_slot_box.duplicate())
		btn.add_theme_color_override("font_color", Color("4A82D0") if _dark_mode else Color("316AC5"))
		btn.add_theme_font_size_override("font_size", 12)
		btn.custom_minimum_size = Vector2(32, 0)
		btn.pressed.connect(func(): _on_slot_plus_pressed(proj_idx, slot_key))
		return btn

func _on_card_gui_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_selected_project = idx
			_rebuild_cards.call_deferred()

func _on_output_box_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP \
				or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN \
				or mb.button_index == MOUSE_BUTTON_WHEEL_LEFT \
				or mb.button_index == MOUSE_BUTTON_WHEEL_RIGHT:
			output_box.accept_event()
	elif event is InputEventPanGesture:
		output_box.accept_event()

func _on_switch_toggled(proj_idx: int, btn_name: String, on: bool) -> void:
	if proj_idx < 0 or proj_idx >= projects.size():
		return
	var sw: Dictionary = projects[proj_idx].get("switch_states", {})
	sw[btn_name] = on
	projects[proj_idx]["switch_states"] = sw

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
	support_files.clear()
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
	var support_list: Array = []
	for support_slot in support_files:
		var display := str(support_slot["display"])
		var zip_name := _sanitize_filename(display)
		if zip_name == "":
			zip_name = "support.spice"
		zip_name = _unique_name(zip_name, used)
		used[zip_name] = true
		support_list.append({
			"name": display,
			"zip_path": WORKSPACE_FILES_DIR + zip_name,
			"user_path": str(support_slot["user_path"]),
			"bytes": int(support_slot["bytes"]),
			"ext": str(support_slot["ext"])
		})
	return {
		"format": "circuit-visualizer-workspace-zip",
		"version": 2,
		"created_unix": int(Time.get_unix_time_from_system()),
		"projects": proj_list,
		"support_files": support_list
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

	for support_var in (manifest.get("support_files", []) as Array):
		var support_item := support_var as Dictionary
		var support_user_path := str(support_item.get("user_path", ""))
		var support_zip_rel := str(support_item.get("zip_path", ""))
		var support_fa := FileAccess.open(support_user_path, FileAccess.READ)
		if support_fa == null:
			writer.close()
			_set_error("Could not open support file for zipping: %s" % support_user_path)
			return false
		var support_buf := support_fa.get_buffer(support_fa.get_length())
		support_fa.close()
		err = writer.start_file(support_zip_rel)
		if err != OK:
			writer.close()
			_set_error("Zip start_file(%s) failed (err=%s)" % [support_zip_rel, str(err)])
			return false
		err = writer.write_file(support_buf)
		if err != OK:
			writer.close_file()
			writer.close()
			_set_error("Zip write_file(%s) failed (err=%s)" % [support_zip_rel, str(err)])
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
				"complete": false,
				"buttons": [],
				"switch_states": {}
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
				var loaded_slot: Dictionary = {
					"display": safe_name,
					"user_path": user_path,
					"bytes": buf.size(),
					"ext": safe_name.get_extension().to_lower()
				}
				if slot_key == "spice":
					loaded_slot["spice_analysis"] = _analyze_spice_file(user_path)
				new_proj[slot_key] = loaded_slot
				if slot_key == "xschem":
					var buttons := _parse_buttons_from_sch(user_path)
					var sw: Dictionary = {}
					for b in buttons:
						sw[b] = false
					new_proj["buttons"] = buttons
					new_proj["switch_states"] = sw
			new_proj["complete"] = new_proj["spice"] != null
			projects.append(new_proj)
		var support_list_var: Variant = m.get("support_files", [])
		if typeof(support_list_var) == TYPE_ARRAY:
			for support_saved_v in (support_list_var as Array):
				if typeof(support_saved_v) != TYPE_DICTIONARY:
					continue
				var support_saved := support_saved_v as Dictionary
				var support_name := str(support_saved.get("name", "support.spice"))
				var support_zip_rel := str(support_saved.get("zip_path", ""))
				if support_zip_rel == "":
					continue
				var support_buf := reader.read_file(support_zip_rel)
				if support_buf.is_empty():
					_log("[color=#b56a00][b]Warning:[/b][/color] Missing support zip entry: %s" % support_zip_rel)
					continue
				var support_safe_name := _sanitize_filename(support_name)
				var support_user_path := _avoid_collision("%s/%s" % [UPLOAD_DIR, support_safe_name])
				var support_wf := FileAccess.open(support_user_path, FileAccess.WRITE)
				if support_wf == null:
					_set_error("Failed to write %s" % support_user_path)
					continue
				support_wf.store_buffer(support_buf)
				support_wf.close()
				var support_slot: Dictionary = {
					"display": support_safe_name,
					"user_path": support_user_path,
					"bytes": support_buf.size(),
					"ext": support_safe_name.get_extension().to_lower()
				}
				support_slot["spice_analysis"] = _analyze_spice_file(support_user_path)
				support_files.append(support_slot)
		reader.close()
	else:
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
# Button / switch helpers
# -------------------------------------------------------------------

func _parse_buttons_from_sch(user_path: String) -> Array:
	if user_path == "":
		return []
	if not ClassDB.class_exists("SchParser"):
		return []
	var parser: Object = ClassDB.instantiate("SchParser")
	if parser == null or not parser.has_method("parse_file"):
		return []
	if not parser.call("parse_file", user_path):
		return []
	var buttons: Array = []
	for comp_v in parser.call("get_components"):
		var comp := comp_v as Dictionary
		if str(comp.get("type", "")) == "button":
			var name := str(comp.get("name", ""))
			if name != "":
				buttons.append(name)
	return buttons

func _patch_spice_for_switches(user_path: String, switch_states: Dictionary) -> String:
	var fa := FileAccess.open(user_path, FileAccess.READ)
	if fa == null:
		return ""
	var content := fa.get_as_text()
	fa.close()

	var lines := content.split("\n")
	var modified := false

	for btn_name_v in switch_states:
		var btn_name := str(btn_name_v)
		var on: bool = bool(switch_states[btn_name_v])
		var voltage := "DC 1.8" if on else "DC 0"
		for i in lines.size():
			if lines[i].strip_edges().to_lower().begins_with(btn_name.to_lower()):
				var new_line: String = _external_re.sub(lines[i], voltage)
				if new_line != lines[i]:
					lines[i] = new_line
					modified = true

	if not modified:
		return ""

	_ensure_upload_dir()
	var tmp_path := "%s/_sim_%d.spice" % [UPLOAD_DIR, int(Time.get_unix_time_from_system())]
	var wf := FileAccess.open(tmp_path, FileAccess.WRITE)
	if wf == null:
		return ""
	wf.store_string("\n".join(lines))
	wf.close()
	return tmp_path

func _patch_spice_for_subcircuit_support(user_path: String, proj: Dictionary) -> String:
	var root_entry_v: Variant = proj.get("spice", null)
	if typeof(root_entry_v) != TYPE_DICTIONARY:
		return ""
	var root_entry := root_entry_v as Dictionary
	var root_analysis := _analysis_for_entry(root_entry)
	var root_defs := _array_to_lookup(root_analysis.get("subckt_defs", []))
	var calls := _array_to_lookup(root_analysis.get("subckt_calls", []))
	if calls.is_empty():
		return ""

	var include_paths := PackedStringArray()
	var seen_paths: Dictionary = {}
	for support_entry in _support_entries_for_project(str(root_entry.get("user_path", ""))):
		var support_analysis := _analysis_for_entry(support_entry)
		var support_defs := _array_to_lookup(support_analysis.get("subckt_defs", []))
		var needed := false
		for call_key in calls.keys():
			if not root_defs.has(call_key) and support_defs.has(call_key):
				needed = true
				break
		if not needed:
			continue
		var support_user_path := str(support_entry.get("user_path", ""))
		if support_user_path == "" or seen_paths.has(support_user_path):
			continue
		seen_paths[support_user_path] = true
		include_paths.append(support_user_path if OS.has_feature("web") else ProjectSettings.globalize_path(support_user_path))

	if include_paths.is_empty():
		return ""

	var fa := FileAccess.open(user_path, FileAccess.READ)
	if fa == null:
		return ""
	var content := fa.get_as_text()
	fa.close()

	var lines := content.split("\n")
	var insert_at := lines.size()
	for i in range(lines.size() - 1, -1, -1):
		if str(lines[i]).strip_edges().to_lower() == ".end":
			insert_at = i
			break
	for include_path in include_paths:
		lines.insert(insert_at, ".include \"%s\"" % include_path)
		insert_at += 1

	_ensure_upload_dir()
	var tmp_path := "%s/_sim_subckts_%d.spice" % [UPLOAD_DIR, int(Time.get_unix_time_from_system())]
	var wf := FileAccess.open(tmp_path, FileAccess.WRITE)
	if wf == null:
		return ""
	wf.store_string("\n".join(lines))
	wf.close()
	_log("[color=#336699][b]Info:[/b][/color] Added %d uploaded subcircuit include(s) for this run." % include_paths.size())
	return tmp_path

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

func _resolve_simulator() -> Node:
	if simulator_path != NodePath("") and has_node(simulator_path):
		var n0: Node = get_node(simulator_path)
		if n0 != null and n0.has_method("run_continuous"):
			return n0
	var cur: Node = self
	while cur != null:
		if cur.has_method("run_continuous"):
			return cur
		cur = cur.get_parent()
	var root: Window = get_tree().root
	if root != null:
		for c in root.find_children("*", "", true, false):
			if c is Node and (c as Node).has_method("run_continuous"):
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
			_:                c = Color("C0BDB6")
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
	dark_mode_changed.emit(_dark_mode)

func is_dark_mode() -> bool:
	return _dark_mode

# -------------------------------------------------------------------
# Styling — Windows XP Luna (light) / dark variant
# -------------------------------------------------------------------

func _apply_theme() -> void:
	_t = Theme.new()

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

	var sb_root := StyleBoxFlat.new()
	sb_root.bg_color = xp_face
	add_theme_stylebox_override("panel", sb_root)

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

	_sb_drop_idle = _sb_panel.duplicate() as StyleBoxFlat
	_sb_drop_idle.bg_color = Color("1A2530") if _dark_mode else Color("EBF3FC")
	_sb_drop_idle.border_color = xp_ctrl_border

	_sb_drop_flash = _sb_panel.duplicate() as StyleBoxFlat
	_sb_drop_flash.bg_color = Color("2A2010") if _dark_mode else Color("FFF6D4")
	_sb_drop_flash.border_color = xp_btn_hover_border

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
	_sb_card_hover.bg_color = xp_btn_hover_face
	_sb_card_hover.border_color = xp_btn_hover_border

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

	_t.set_color("font_color", "Label", xp_text)
	_t.set_color("font_color", "LineEdit", xp_text)
	_t.set_stylebox("panel", "PanelContainer", _sb_panel)

	theme = _t

	var header: Label = $Margin/VBox/Header
	if header != null:
		header.add_theme_color_override("font_color", xp_title_blue)
	var subheader: Label = $Margin/VBox/Subheader
	if subheader != null:
		subheader.add_theme_color_override("font_color", xp_subtext)

	drop_hint.add_theme_color_override("font_color", xp_subtext)
	drop_title.add_theme_color_override("font_color", xp_title_blue)
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_idle)

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

	if output_box != null:
		output_box.add_theme_color_override("default_color", xp_text)

func _flash_drop_zone() -> void:
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_flash)
	drop_title.text = "Dropped, staging..."
	await get_tree().create_timer(0.35).timeout
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_idle)
	drop_title.text = "Drop files here"
