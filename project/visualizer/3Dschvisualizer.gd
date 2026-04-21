extends Node3D

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
var _sidebar:        SidebarPanel  = null
var _floor:          MeshInstance3D = null
var _status_panel:   SimStatusPanel  = null
var _waveform_panel: WaveformPanel   = null
var _voltage_key:    VoltageKeyPanel = null

# ---------- Live / continuous-transient state ----------
const MAX_LIVE_SAMPLES: int          = 2000
var _live_mode:         bool         = false
var _live_signal_names: PackedStringArray = PackedStringArray()
var _live_time_buf:     Array        = []
var _live_volt_bufs:    Dictionary   = {}   # norm_name → Array[float]
var _live_sim_t:        float        = 0.0

# ---------- Shared state (read/written by helper scripts) ----------

## Symbol definition cache: symbol_name → SymbolDefinition.
var _sym_cache: Dictionary = {}

## Shared materials: component_type → StandardMaterial3D.
var _materials: Dictionary = {}

## Search paths for .sym files.
var _sym_search_paths: Array[String] = [
	"res://symbols/sym/",
	"res://symbols/sym/sky130_fd_pr/",
	"res://symbols/",
	"res://symbols/sky130_fd_pr/",
]

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


## Edge-detection trackers for cursor completion (true = was idle last frame).
var _tc_was_done: Array[bool] = []
var _gc_was_done: Array[bool] = []

# ---------- Helper instances ----------
var _scene_builder:  VisSceneBuilder
var _cursor_builder: VisCursorBuilder
var _anim_player:    VisAnimPlayer


func _ready() -> void:
	parser = SchParser.new()
	_materials = VisMaterialFactory.build_materials()
	_floor = VisMaterialFactory.create_floor(self)
	_scene_builder  = VisSceneBuilder.new(self)
	_cursor_builder = VisCursorBuilder.new(self)
	_anim_player    = VisAnimPlayer.new(self)
	_setup_upload_ui()
	_setup_glow()


func _setup_glow() -> void:
	var we := get_parent().find_child("WorldEnvironment", true, false) as WorldEnvironment
	if we == null or we.environment == null:
		push_warning("Visualizer: WorldEnvironment not found — wire bloom will be inactive.")
		return
	var env: Environment = we.environment
	env.glow_enabled        = true
	env.glow_normalized     = false
	env.glow_intensity      = 0.6
	env.glow_strength       = 0.9
	env.glow_bloom          = 0.0    # only HDR pixels bloom (keeps dark wires clean)
	env.glow_blend_mode     = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold  = 1.2   # slightly above 1 so only the dot peak blooms
	env.glow_hdr_scale      = 1.5
	# Enable levels 1–5 — higher levels spread the halo wider
	for i: int in range(1, 6):
		env.set("glow_levels/" + str(i), true)
	for i: int in range(6, 8):
		env.set("glow_levels/" + str(i), false)


func _process(delta: float) -> void:
	_anim_player.process_frame(delta)
	_drive_ui_panels()


func _drive_ui_panels() -> void:
	if not _anim_active or _sim_time.size() < 2:
		return
	var sim_start: float    = float(_sim_time[0])
	var sim_end: float      = float(_sim_time[_sim_time.size() - 1])
	var sim_duration: float = sim_end - sim_start
	var sim_t: float        = sim_start + _anim_sim_elapsed
	if _status_panel != null:
		_status_panel.update_anim_progress(sim_t, sim_duration)
	if _waveform_panel != null:
		_waveform_panel.update_sim_time(sim_t)


# ---------- Schematic loading ----------

func load_schematic(path: String) -> bool:
	if not parser.parse_file(path):
		push_error("Failed to parse: " + path)
		return false

	_scene_builder.draw_circuit(parser, _floor)

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


# ---------- UI setup ----------

func _setup_upload_ui() -> void:
	var sim_packed = load("res://circuit_simulator.tscn")
	if sim_packed != null:
		var sim := (sim_packed as PackedScene).instantiate()
		sim.name = "CircuitSimulator"
		# CONNECT_DEFERRED: ngspice emits signals from its own OS thread.
		# Deferred connections queue the call for the main thread.
		# NOTE: simulation_data_ready is NOT connected here — it fires once per
		# ngspice timestep (potentially millions/sec) and would crash the queue.
		# Visual updates are driven by continuous_transient_frame instead (sane rate).
		sim.simulation_finished.connect(_on_simulation_finished, CONNECT_DEFERRED)
		if sim.has_signal("continuous_transient_started"):
			sim.continuous_transient_started.connect(_on_continuous_transient_started, CONNECT_DEFERRED)
		if sim.has_signal("continuous_transient_frame"):
			sim.continuous_transient_frame.connect(_on_continuous_transient_frame, CONNECT_DEFERRED)
		get_parent().add_child.call_deferred(sim)
	else:
		push_warning("Could not load res://circuit_simulator.tscn — simulation will be unavailable.")

	_sidebar = SidebarPanel.new()
	_sidebar.name = "Sidebar"
	_sidebar.schematic_requested.connect(_on_schematic_requested)
	_sidebar.spice_paired.connect(_on_spice_paired)
	_sidebar.simulation_started.connect(_on_simulation_started)

	var ui_layer := CanvasLayer.new()
	ui_layer.layer = 10
	ui_layer.name = "UILayer"
	get_parent().add_child.call_deferred(ui_layer)
	ui_layer.add_child(_sidebar)

	# ── Status panel — top-right corner ──────────────────────────────────
	_status_panel = SimStatusPanel.new()
	_status_panel.name = "SimStatusPanel"
	_status_panel.anchor_left   = 1.0
	_status_panel.anchor_right  = 1.0
	_status_panel.anchor_top    = 0.0
	_status_panel.anchor_bottom = 0.0
	_status_panel.offset_left   = -244.0
	_status_panel.offset_right  = -8.0
	_status_panel.offset_top    = 8.0
	_status_panel.offset_bottom = 0.0
	_status_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ui_layer.add_child(_status_panel)

	# ── Voltage key — right side, below the status panel ────────────────
	_voltage_key = VoltageKeyPanel.new()
	_voltage_key.name = "VoltageKeyPanel"
	_voltage_key.anchor_left   = 1.0
	_voltage_key.anchor_right  = 1.0
	_voltage_key.anchor_top    = 0.0
	_voltage_key.anchor_bottom = 0.0
	_voltage_key.offset_left   = -168.0
	_voltage_key.offset_right  = -8.0
	_voltage_key.offset_top    = 102.0
	_voltage_key.offset_bottom = 0.0
	_voltage_key.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_voltage_key.hide()
	ui_layer.add_child(_voltage_key)

	# ── Waveform panel — right side, below the voltage key ───────────────
	_waveform_panel = WaveformPanel.new()
	_waveform_panel.name = "WaveformPanel"
	_waveform_panel.anchor_left   = 1.0
	_waveform_panel.anchor_right  = 1.0
	_waveform_panel.anchor_top    = 0.0
	_waveform_panel.anchor_bottom = 0.0
	_waveform_panel.offset_left   = -428.0
	_waveform_panel.offset_right  = -8.0
	_waveform_panel.offset_top    = 250.0
	_waveform_panel.offset_bottom = 0.0
	_waveform_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ui_layer.add_child(_waveform_panel)


# ---------- Signal handlers ----------

func _on_schematic_requested(path: String) -> void:
	print("Loading schematic from UI: " + path)
	if _status_panel != null:
		_status_panel.set_stage("loading")
	load_schematic(path)


func _on_spice_paired(path: String) -> void:
	_transistor_data = VisGeomUtils.parse_spice_transistors(path)
	print("Visualizer: paired SPICE — %d transistors mapped for conductance animation" % _transistor_data.size())
	_cursor_builder.build_transistor_cursors()

	print("Visualizer: %d transistors mapped for conductance animation" % _transistor_data.size())


func _on_simulation_started() -> void:
	if _status_panel != null:
		_status_panel.set_stage("simulating")
	if _voltage_key != null:
		_voltage_key.hide()


func _on_simulation_finished() -> void:
	print("Simulation finished — fetching vectors for animation...")
	var sim: Node = get_tree().root.find_child("CircuitSimulator", true, false)
	if sim == null:
		push_warning("Visualizer: CircuitSimulator not found after simulation_finished")
		if _status_panel != null:
			_status_panel.set_stage("error")
		return

	# Try the streaming snapshot first — it has the full time series.
	var names: PackedStringArray = sim.call("get_last_sim_signal_names")
	var snapshot: Array          = sim.call("get_last_sim_snapshot")
	print("Visualizer: snapshot %d signals × %d steps" % [names.size(), snapshot.size()])

	if names.size() > 0 and snapshot.size() > 0:
		var all_vecs: Dictionary = {}
		for i: int in range(names.size()):
			var col: Array = []
			col.resize(snapshot.size())
			for s: int in range(snapshot.size()):
				var row: PackedFloat64Array = snapshot[s]
				col[s] = float(row[i]) if i < row.size() else 0.0
			all_vecs[str(names[i])] = col
		# Supplement with get_all_vectors() for internal nodes (e.g. x_dut.net1)
		# that aren't streamed in the snapshot callback but ARE saved to ngspice's plot.
		var extra_vecs: Dictionary = sim.call("get_all_vectors")
		for key: String in extra_vecs.keys():
			if not all_vecs.has(key):
				all_vecs[key] = extra_vecs[key]
		_anim_player.load_sim_data(all_vecs)
		_on_sim_data_loaded(all_vecs)
		return

	# Snapshot empty (race on first run) — fall back to batch buffer.
	push_warning("Visualizer: snapshot empty, falling back to get_all_vectors()")
	var all_vecs: Dictionary = sim.call("get_all_vectors")
	if all_vecs.is_empty():
		push_warning("Visualizer: simulation_finished but no vectors available")
		if _status_panel != null:
			_status_panel.set_stage("error")
		return
	_anim_player.load_sim_data(all_vecs)
	_on_sim_data_loaded(all_vecs)


func _on_sim_data_loaded(all_vecs: Dictionary) -> void:
	if _status_panel != null:
		_status_panel.set_stage("playing")
		var time_pts: int  = _sim_time.size()
		var net_count: int = _net_nodes.size()
		var vec_count: int = all_vecs.size()
		_status_panel.set_sim_info(time_pts, net_count, vec_count)
	if _voltage_key != null:
		_voltage_key.show()


# ── Wire picking — open waveform panel when a wire is clicked ─────────────

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	# Don't intercept clicks over UI controls.
	if _is_over_ui(mb.global_position):
		return
	_try_pick_wire(mb.global_position)


func _is_over_ui(screen_pos: Vector2) -> bool:
	# Ask Godot's GUI system if any Control at this position consumed the event.
	# get_viewport().gui_get_focus_owner() isn't enough — use hit-testing instead.
	# We check the sidebar bounds and waveform panel bounds manually.
	if _sidebar != null and _sidebar.visible:
		var sb_rect: Rect2 = _sidebar.get_global_rect()
		if sb_rect.has_point(screen_pos):
			return true
	if _waveform_panel != null and _waveform_panel.visible:
		var wp_rect: Rect2 = _waveform_panel.get_global_rect()
		if wp_rect.has_point(screen_pos):
			return true
	if _status_panel != null and _status_panel.visible:
		var sp_rect: Rect2 = _status_panel.get_global_rect()
		if sp_rect.has_point(screen_pos):
			return true
	return false


func _try_pick_wire(screen_pos: Vector2) -> void:
	if _wire_cursors.is_empty() or (not _anim_active and not _live_mode):
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return

	const PICK_RADIUS_PX: float = 14.0
	var best_dist: float = PICK_RADIUS_PX * PICK_RADIUS_PX
	var best_net:  String = ""

	for wd: Dictionary in _wire_cursors:
		var p1_screen: Vector2 = camera.unproject_position(to_global(wd["p1"]))
		var p2_screen: Vector2 = camera.unproject_position(to_global(wd["p2"]))
		var d: float = _point_to_seg_dist_sq(screen_pos, p1_screen, p2_screen)
		if d < best_dist:
			best_dist = d
			best_net  = str(wd["net"])

	if best_net == "":
		return

	if _live_mode and _live_volt_bufs.has(best_net) and _live_time_buf.size() >= 2:
		var t_win: Array = _live_time_buf.slice(-MAX_LIVE_SAMPLES)
		var v_win: Array = (_live_volt_bufs[best_net] as Array).slice(-MAX_LIVE_SAMPLES)
		if _waveform_panel != null:
			_waveform_panel.show_net(best_net, t_win, v_win, VisAnimPlayer.VMAX)
	elif not _live_mode and _sim_vectors.has(best_net):
		if _waveform_panel != null:
			_waveform_panel.show_net(best_net, _sim_time, _sim_vectors[best_net], VisAnimPlayer.VMAX)


# ── Live / continuous-transient handlers ─────────────────────────────────────

## Fires when start_continuous_transient() is called successfully.
func _on_continuous_transient_started() -> void:
	_live_mode = true
	_live_time_buf.clear()
	_live_volt_bufs.clear()
	_live_sim_t = 0.0
	if _status_panel != null:
		_status_panel.set_stage("playing")
	if _voltage_key != null:
		_voltage_key.show()
	# Fetch signal names now — may be populated by the time this fires.
	var sim: Node = get_tree().root.find_child("CircuitSimulator", true, false)
	if sim != null and sim.has_method("get_continuous_memory_signal_names"):
		_live_signal_names = sim.call("get_continuous_memory_signal_names")
		if _status_panel != null and _live_signal_names.size() > 0:
			_status_panel.set_sim_info(0, _net_nodes.size(), _live_signal_names.size())


## Fires once per ngspice frame boundary — deferred to main thread via CONNECT_DEFERRED.
## This is the ONLY live-mode visual update path.
## Data comes from the C++ memory buffer (filled on the ngspice thread, mutex-protected).
## Do NOT use get_all_vectors() here — that only works after a batch simulation completes.
var _live_frame_count: int = 0
func _on_continuous_transient_frame(frame: Dictionary) -> void:
	if not _live_mode:
		return
	_live_sim_t = float(frame.get("time", 0.0))

	var sim: Node = get_tree().root.find_child("CircuitSimulator", true, false)
	if sim == null:
		return

	# Drain the C++ memory buffer — safe from main thread, filled by ngspice callback.
	# Returns Array of PackedFloat64Array, one per buffered sample.
	var samples: Array = sim.call("pop_continuous_memory_samples", 256)
	if samples.is_empty():
		if _status_panel != null:
			_status_panel.set_live_time(_live_sim_t)
		return

	# Signal names are set once when ngspice initialises the plot (SendInitData callback).
	var names: PackedStringArray = sim.call("get_continuous_memory_signal_names")
	if names.is_empty():
		if _status_panel != null:
			_status_panel.set_live_time(_live_sim_t)
		return

	_live_frame_count += 1
	if _live_frame_count == 1:
		print("[live] first frame: %d samples, %d signals: %s" % [
			samples.size(), names.size(), Array(names).slice(0, 10)])

	# Use the LAST (most recent) sample for wire colour / transistor glow.
	var last_sample: PackedFloat64Array = samples.back() as PackedFloat64Array
	_anim_player.apply_live_sample(names, last_sample)

	# Build the set of nets we actually display so the buffer loop can skip everything else.
	# Signals containing '#' are internal device currents (branch, body, sbody, dbody) — never voltages.
	var tracked_nets: Dictionary = {}
	for wd: Dictionary in _wire_cursors:
		tracked_nets[str(wd["net"])] = true

	# Pre-compute which signal indices are worth buffering (voltage signals on tracked nets).
	# Done once per frame-call since names are stable across samples.
	var wanted_indices: PackedInt32Array = PackedInt32Array()
	var time_index: int = -1
	for i: int in range(names.size()):
		var raw: String = str(names[i]).to_lower()
		if raw == "time":
			time_index = i
			wanted_indices.append(i)
			continue
		if "#" in raw:   # internal device current — skip entirely
			continue
		var norm: String = VisGeomUtils.normalize_vec_name(str(names[i]))
		if norm == "" or norm == "time":
			continue
		if tracked_nets.has(norm):
			wanted_indices.append(i)

	# Append samples to rolling waveform buffers — only the wanted signals.
	for s_idx: int in range(samples.size()):
		var sample: PackedFloat64Array = samples[s_idx] as PackedFloat64Array
		var t: float = _live_sim_t
		for i: int in wanted_indices:
			if i >= sample.size():
				continue
			var raw: String = str(names[i]).to_lower()
			if raw == "time":
				t = float(sample[i])
				continue
			var norm: String = VisGeomUtils.normalize_vec_name(str(names[i]))
			if not _live_volt_bufs.has(norm):
				_live_volt_bufs[norm] = []
			(_live_volt_bufs[norm] as Array).append(float(sample[i]))
		_live_time_buf.append(t)

	if _live_time_buf.size() > MAX_LIVE_SAMPLES * 2:
		_live_time_buf = _live_time_buf.slice(MAX_LIVE_SAMPLES)
		for net: String in _live_volt_bufs.keys():
			_live_volt_bufs[net] = (_live_volt_bufs[net] as Array).slice(MAX_LIVE_SAMPLES)

	# Update status panel.
	if _status_panel != null:
		_status_panel.set_live_time(_live_sim_t)
		_status_panel.set_sim_info(_live_time_buf.size(), _net_nodes.size(), names.size())

	# Update waveform panel if a net is selected.
	if _waveform_panel != null and _waveform_panel.visible:
		var net: String = _waveform_panel._net_name
		if _live_volt_bufs.has(net) and _live_time_buf.size() >= 2:
			var t_win: Array = _live_time_buf.slice(-MAX_LIVE_SAMPLES)
			var v_win: Array = (_live_volt_bufs[net] as Array).slice(-MAX_LIVE_SAMPLES)
			_waveform_panel.update_live_data(t_win, v_win, VisAnimPlayer.VMAX)


## ── Returns squared distance from point p to segment (a, b) in 2D.
static func _point_to_seg_dist_sq(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq: float = ab.length_squared()
	if len_sq < 1.0:
		return p.distance_squared_to(a)
	var t: float = clamp((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_squared_to(a + ab * t)
