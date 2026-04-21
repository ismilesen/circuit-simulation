class_name VisAnimPlayer
extends RefCounted

const VMAX:              float = 1.8
const WIRE_BASE_ENERGY:  float = 1.6   # steady emission at Vmax
const FLOW_SPEED:        float = 0.45  # wire traversals per second (same for all nets)

## Untyped reference to the main SchVis3D Node3D.
var _vis


func _init(vis) -> void:
	_vis = vis


# ---------- Voltage helpers ----------

func get_net_voltage_at(net_name: String, idx: int) -> float:
	match net_name:
		"vpwr", "vdd", "vcc":
			return VMAX
		"vgnd", "gnd", "vss", "0":
			return 0.0
	if not _vis._sim_vectors.has(net_name):
		return 0.0
	var vec: Array = _vis._sim_vectors[net_name]
	if idx >= vec.size():
		return 0.0
	return float(vec[idx])


## Maps 0–1.8 V to a spectral color driven by ngspice voltage.
## Yellow voltage ramp — dark amber (off/GND) → bright white-yellow (VPWR/high)
## 0.00 V → near-black warm dark  (off)
## 0.45 V → dark amber            (weak signal)
## 0.90 V → medium yellow         (mid-rail)
## 1.35 V → bright yellow         (strong signal)
## 1.80 V → white-yellow          (full rail)
func voltage_to_color(v: float) -> Color:
	var t: float = clamp(v / VMAX, 0.0, 1.0)
	if t < 0.25:
		var s: float = t / 0.25
		return Color(0.06, 0.04, 0.00).lerp(Color(0.38, 0.26, 0.00), s)
	elif t < 0.5:
		var s: float = (t - 0.25) / 0.25
		return Color(0.38, 0.26, 0.00).lerp(Color(0.76, 0.62, 0.00), s)
	elif t < 0.75:
		var s: float = (t - 0.5) / 0.25
		return Color(0.76, 0.62, 0.00).lerp(Color(1.00, 0.88, 0.08), s)
	else:
		var s: float = (t - 0.75) / 0.25
		return Color(1.00, 0.88, 0.08).lerp(Color(1.00, 1.00, 0.72), s)


func voltage_to_energy(v: float) -> float:
	return 0.4 + 2.6 * clamp(v / VMAX, 0.0, 1.0)


# ---------- Live / continuous-transient update ----------

## Called once per sample from simulation_data_ready.
## Updates wire colors and transistor glow immediately from the latest voltages
## without touching the batch _sim_time / _anim_active state.
func apply_live_sample(names: PackedStringArray, sample: PackedFloat64Array) -> void:
	for i: int in range(mini(names.size(), sample.size())):
		var norm: String = VisGeomUtils.normalize_vec_name(str(names[i]))
		if norm == "time" or norm == "":
			continue
		_vis._sim_vectors[norm] = [float(sample[i])]
	_update_wire_colors(0)
	_update_transistor_glow(0)


# ---------- Simulation data loading ----------

func load_sim_data(all_vecs: Dictionary) -> void:
	_vis._sim_time.clear()
	_vis._sim_vectors.clear()
	_vis._anim_active = false

	for key: String in all_vecs.keys():
		if key.to_lower() == "time":
			_vis._sim_time = Array(all_vecs[key])
			break

	var mapped: int = 0
	for key: String in all_vecs.keys():
		var norm: String = VisGeomUtils.normalize_vec_name(key)
		if norm == "time" or norm == "":
			continue
		_vis._sim_vectors[norm] = Array(all_vecs[key])
		if _vis._net_nodes.has(norm):
			mapped += 1

	if _vis._sim_time.size() > 1 and mapped > 0:
		_vis._anim_sim_elapsed = 0.0
		_vis._anim_active = true
		var t_start: float = float(_vis._sim_time[0])
		var t_end: float   = float(_vis._sim_time[_vis._sim_time.size() - 1])
		print("Simulation animation ready: ", _vis._sim_time.size(), " time steps (",
			t_start, " s to ", t_end, " s), ", mapped, " nets mapped.")
	else:
		if _vis._sim_time.size() <= 1:
			push_warning("Visualizer: time vector missing or has only " + str(_vis._sim_time.size()) + " point(s)")
		print("Visualizer: no matching nets (mapped=", mapped, ", time_pts=", _vis._sim_time.size(), ")")
		print("  Available vectors: ", all_vecs.keys())
		print("  Schematic nets tracked: ", _vis._net_nodes.keys())


# ---------- Transistor cursor triggering ----------

## Checks conductance from ngspice voltages and arms the gate cursor.
## Gate cursor completion fires the channel cursor.
## If no gate cursor exists, fires the channel cursor directly.
func try_trigger_transistor_cursor(comp_name: String, sim_idx: int) -> void:
	if not _vis._transistor_cursor_map.has(comp_name):
		return

	var tdata: Dictionary = _vis._transistor_data[comp_name]
	var is_pmos: bool = str(tdata["type"]) == "pfet"
	var vg: float = get_net_voltage_at(str(tdata["g"]), sim_idx)
	var vs: float = get_net_voltage_at(str(tdata["s"]), sim_idx)
	var vth: float = VisGeomUtils.vth_for_model(str(tdata.get("model", "")))
	var conductance: float = clampf(
		(vs - vg - vth) / vth if is_pmos \
		else (vg - vs - vth) / vth,
		0.0, 1.0)
	if conductance < 0.05:
		return

	if _vis._gate_cursor_map.has(comp_name):
		var gc_idx: int      = int(_vis._gate_cursor_map[comp_name])
		var gc: Dictionary   = _vis._gate_cursors[gc_idx]
		var gc_age: float    = _vis._real_elapsed - float(gc["trigger_t"])
		var g_trav: float    = float(gc.get("traverse", _vis.cursor_traverse_seconds * 0.35))
		if gc_age >= 0.0 and gc_age <= g_trav:
			return  # gate cursor already traveling
		gc["trigger_t"] = _vis._real_elapsed
		return  # channel cursor fires when gate cursor finishes

	_fire_channel_cursor(comp_name, sim_idx)


## Fires the channel cursor if the transistor is still conducting.
func _fire_channel_cursor(comp_name: String, sim_idx: int) -> void:
	if not _vis._transistor_cursor_map.has(comp_name):
		return
	var tc_idx: int = int(_vis._transistor_cursor_map[comp_name])
	var age: float  = _vis._real_elapsed - float(_vis._transistor_cursors[tc_idx]["trigger_t"])
	if age >= 0.0 and age <= _vis.cursor_traverse_seconds:
		return  # already active
	var tdata: Dictionary = _vis._transistor_data[comp_name]
	var is_pmos: bool     = str(tdata["type"]) == "pfet"
	var vg: float = get_net_voltage_at(str(tdata["g"]), sim_idx)
	var vs: float = get_net_voltage_at(str(tdata["s"]), sim_idx)
	var vth: float = VisGeomUtils.vth_for_model(str(tdata.get("model", "")))
	var conductance: float = clampf(
		(vs - vg - vth) / vth if is_pmos \
		else (vg - vs - vth) / vth,
		0.0, 1.0)
	if conductance < 0.05:
		return
	_vis._transistor_cursors[tc_idx]["trigger_t"] = _vis._real_elapsed


## Re-seeds a net's wire cursor BFS from a transistor pin world position.
func cascade_net_from_pin(comp_name: String, pin_name: String, sim_idx: int) -> void:
	if not _vis._transistor_data.has(comp_name) or not _vis._transistor_nodes.has(comp_name):
		return
	var tdata: Dictionary  = _vis._transistor_data[comp_name]
	var target_net: String = str(tdata[pin_name.to_lower()])
	if not _vis._net_cascade.has(target_net):
		return
	var sym: CircuitSymbol = _vis._transistor_nodes[comp_name] as CircuitSymbol
	var pin_local: Vector3 = _vis.to_local(sym.get_pin_position(pin_name))
	var max_hop: int       = WireGraph.reseed_net(_vis._wire_cursors, target_net, pin_local, _vis.scale_factor)
	var nc: Dictionary     = _vis._net_cascade[target_net]
	nc["max_hop"]   = max_hop
	nc["trigger_t"] = _vis._real_elapsed
	var v_new: float = get_net_voltage_at(target_net, mini(sim_idx + 1, _vis._sim_time.size() - 1))
	var v_old: float = get_net_voltage_at(target_net, sim_idx)
	nc["color_old"]  = voltage_to_color(v_old)
	nc["energy_old"] = voltage_to_energy(v_old)
	nc["color_new"]  = voltage_to_color(v_new)
	nc["energy_new"] = voltage_to_energy(v_new)


## Called when a transistor channel cursor finishes — cascades the output net.
func on_transistor_cursor_done(comp_name: String, sim_idx: int) -> void:
	if not _vis._transistor_data.has(comp_name):
		return
	var tc_idx: int  = _vis._transistor_cursor_map.get(comp_name, -1)
	var dest_pin: String = "D"
	if tc_idx >= 0 and tc_idx < _vis._transistor_cursors.size():
		dest_pin = str(_vis._transistor_cursors[tc_idx].get("dest_spice_pin", "d")).to_upper()
	cascade_net_from_pin(comp_name, dest_pin, sim_idx)


# ---------- Per-frame animation ----------

func process_frame(delta: float) -> void:
	_vis._real_elapsed += delta

	if not _vis._anim_active or _vis._sim_time.size() < 2:
		return

	var sim_start: float    = float(_vis._sim_time[0])
	var sim_end: float      = float(_vis._sim_time[_vis._sim_time.size() - 1])
	var sim_duration: float = sim_end - sim_start
	if sim_duration <= 0.0:
		return

	_vis._anim_sim_elapsed = fmod(
		_vis._anim_sim_elapsed + delta * (sim_duration / _vis.anim_playback_duration),
		sim_duration
	)
	var sim_t: float = sim_start + _vis._anim_sim_elapsed

	# Binary search for current time index.
	var lo: int = 0
	var hi: int = _vis._sim_time.size() - 1
	while lo < hi:
		var mid: int = (lo + hi + 1) / 2
		if float(_vis._sim_time[mid]) <= sim_t:
			lo = mid
		else:
			hi = mid - 1

	# Color wires from ngspice voltage with synchronized pulse.
	_update_wire_colors(lo)
	# Transistor body glow from ngspice conductance.
	_update_transistor_glow(lo)
	# Gate sphere animation; fires channel cursor on completion.
	_update_gate_cursors(lo)
	# Channel sphere animation; cascades output net on completion.
	_update_channel_cursors(lo)
	# Arm transistor cursors wherever conductance > threshold.
	_trigger_transistors_from_voltage(lo)


# ---------- Animation sub-sections ----------

## Colors every tracked wire from its ngspice voltage.
## Labeled wires (ShaderMaterial) also get a traveling flow dot whose speed
## scales with voltage — stopped at 0 V, full speed at Vmax.
func _update_wire_colors(lo: int) -> void:
	# ── StandardMaterial3D wires (unlabeled segments, component pins) ─────
	for net_name: String in _vis._sim_vectors.keys():
		if not _vis._net_materials.has(net_name):
			continue
		var vec: Array = _vis._sim_vectors[net_name]
		if lo >= vec.size():
			continue
		var voltage: float = float(vec[lo])
		var v_norm:  float = clampf(voltage / VMAX, 0.0, 1.0)
		var mat: StandardMaterial3D = _vis._net_materials[net_name]
		mat.emission = voltage_to_color(voltage)
		mat.emission_energy_multiplier = v_norm * WIRE_BASE_ENERGY

	# ── ShaderMaterial wires (labeled segments using wire_fill.gdshader) ──
	for wd: Dictionary in _vis._wire_cursors:
		var wire_shader: ShaderMaterial = wd["wire_shader"] as ShaderMaterial
		if wire_shader == null:
			continue
		var cvec: Array  = _vis._sim_vectors.get(str(wd["net"]), [])
		var voltage: float = float(cvec[lo]) if lo < cvec.size() else 0.0
		var v_norm:  float = clampf(voltage / VMAX, 0.0, 1.0)
		var color:   Color = voltage_to_color(voltage)
		var energy:  float = v_norm * WIRE_BASE_ENERGY

		# Advance flow dot — fixed speed, hidden on 0 V nets via flow_amt.
		var flow_pos: float = fmod(_vis._real_elapsed * FLOW_SPEED, 1.0)

		wire_shader.set_shader_parameter("fill_fraction", 1.0)
		wire_shader.set_shader_parameter("color_behind",  color)
		wire_shader.set_shader_parameter("color_ahead",   color)
		wire_shader.set_shader_parameter("energy_behind", energy)
		wire_shader.set_shader_parameter("energy_ahead",  energy)
		wire_shader.set_shader_parameter("flow_pos",      flow_pos)
		wire_shader.set_shader_parameter("flow_amt",      v_norm)


## Detects voltage transitions on any tracked net and arms wire cursor animations.
## Phase 1: detect per-net transitions → arm cascade.
## Phase 2: animate cursor spheres along each wire segment.
func _update_wire_cursors(lo: int) -> void:
	var next_idx: int = mini(lo + 1, _vis._sim_time.size() - 1)

	# Phase 1: any net with a voltage transition above threshold self-triggers.
	for net: String in _vis._net_cascade.keys():
		if not _vis._sim_vectors.has(net):
			continue
		var cvec: Array = _vis._sim_vectors[net]
		if lo >= cvec.size() or next_idx >= cvec.size():
			continue
		var dv: float = float(cvec[next_idx]) - float(cvec[lo])
		if absf(dv) / VMAX < _vis.dv_anim_threshold:
			continue
		var nc: Dictionary = _vis._net_cascade[net]
		var done_t: float  = float(nc["trigger_t"]) + (int(nc["max_hop"]) + 1) * _vis.cursor_traverse_seconds
		if _vis._real_elapsed < done_t:
			continue  # previous animation still running — don't restart
		nc["trigger_t"]  = _vis._real_elapsed
		var v_old: float = float(cvec[lo])
		var v_new: float = float(cvec[next_idx])
		nc["color_old"]  = voltage_to_color(v_old)
		nc["energy_old"] = voltage_to_energy(v_old)
		nc["color_new"]  = voltage_to_color(v_new)
		nc["energy_new"] = voltage_to_energy(v_new)

	# Phase 2: move each cursor sphere along its wire segment.
	for cursor_data: Dictionary in _vis._wire_cursors:
		var net: String              = cursor_data["net"]
		var cursor: MeshInstance3D   = cursor_data["cursor"]
		var wire_shader: ShaderMaterial = cursor_data["wire_shader"] as ShaderMaterial

		if not _vis._net_cascade.has(net):
			cursor.visible = false
			continue

		var nc: Dictionary = _vis._net_cascade[net]
		var hop: int       = cursor_data.get("hop_dist", 0)
		if hop >= 999: hop = 0
		var src_end: int = cursor_data.get("source_end", 0)
		var age: float   = _vis._real_elapsed - float(nc["trigger_t"]) - hop * _vis.cursor_traverse_seconds

		if age < 0.0 or age > _vis.cursor_traverse_seconds:
			cursor.visible = false
			if wire_shader != null:
				# Keep wire lit at current ngspice voltage — no cursor, but color persists.
				var cvec: Array = _vis._sim_vectors.get(net, [])
				var v: float    = float(cvec[lo]) if lo < cvec.size() else 0.0
				var c: Color    = voltage_to_color(v)
				var e: float    = voltage_to_energy(v)
				wire_shader.set_shader_parameter("fill_fraction",  1.0)
				wire_shader.set_shader_parameter("color_behind",   c)
				wire_shader.set_shader_parameter("energy_behind",  e)
				wire_shader.set_shader_parameter("color_ahead",    c)
				wire_shader.set_shader_parameter("energy_ahead",   e)
			continue

		cursor.visible = true
		var phase: float    = clamp(age / _vis.cursor_traverse_seconds, 0.0, 1.0)
		var p_from: Vector3 = cursor_data["p1"] if src_end == 0 else cursor_data["p2"]
		var p_to:   Vector3 = cursor_data["p2"] if src_end == 0 else cursor_data["p1"]
		var base_pos: Vector3 = p_from.lerp(p_to, phase)
		cursor.position = Vector3(base_pos.x, base_pos.y + 0.013, base_pos.z)
		var fade: float     = 1.0 - smoothstep(0.8, 1.0, phase)
		var cursor_mat: StandardMaterial3D = cursor_data["cursor_mat"]
		cursor_mat.emission = nc["color_new"]
		cursor_mat.emission_energy_multiplier = (float(nc["energy_new"]) * 2.0 + 1.5) * fade

		if wire_shader != null:
			wire_shader.set_shader_parameter("fill_fraction", phase)
			wire_shader.set_shader_parameter("fill_from_p1",  1 if src_end == 0 else 0)
			wire_shader.set_shader_parameter("color_behind",  nc["color_new"])
			wire_shader.set_shader_parameter("color_ahead",   nc["color_old"])
			wire_shader.set_shader_parameter("energy_behind", nc["energy_new"])
			wire_shader.set_shader_parameter("energy_ahead",  nc["energy_old"])


## Transistor body glow driven directly by ngspice Vg/Vs conductance.
func _update_transistor_glow(lo: int) -> void:
	for comp_name: String in _vis._transistor_data.keys():
		if not _vis._transistor_materials.has(comp_name):
			continue
		var tdata: Dictionary = _vis._transistor_data[comp_name]
		var is_pmos: bool     = str(tdata["type"]) == "pfet"
		var vg: float = get_net_voltage_at(str(tdata["g"]), lo)
		var vs: float = get_net_voltage_at(str(tdata["s"]), lo)
		var vth: float = VisGeomUtils.vth_for_model(str(tdata.get("model", "")))
		var conductance: float
		if is_pmos:
			conductance = clampf((vs - vg - vth) / vth, 0.0, 1.0)
		else:
			conductance = clampf((vg - vs - vth) / vth, 0.0, 1.0)
		# PMOS idle: pink/magenta. NMOS idle: blue. Both hot: warm orange (conducting).
		var idle_color: Color = Color(0.9, 0.15, 0.7) if is_pmos else Color(0.1, 0.35, 1.0)
		var hot_color: Color  = Color(1.0, 0.45, 0.02)
		var tmat: StandardMaterial3D = _vis._transistor_materials[comp_name]
		tmat.emission = idle_color.lerp(hot_color, conductance)
		tmat.emission_energy_multiplier = 0.08 + conductance * 0.9


## Moves channel cursor spheres through transistor bodies.
## Calls on_transistor_cursor_done when each finishes — cascades the output net.
func _update_channel_cursors(lo: int) -> void:
	for i: int in range(_vis._transistor_cursors.size()):
		var tc:        Dictionary     = _vis._transistor_cursors[i]
		var tc_cursor: MeshInstance3D = tc["cursor"]
		var age:       float          = _vis._real_elapsed - float(tc["trigger_t"])
		var is_idle:   bool           = age < 0.0 or age > _vis.cursor_traverse_seconds
		var was_idle:  bool           = _vis._tc_was_done[i] if i < _vis._tc_was_done.size() else true
		_vis._tc_was_done[i] = is_idle

		if is_idle:
			tc_cursor.visible = false
			if not was_idle:
				on_transistor_cursor_done(str(tc["comp_name"]), lo)
			continue

		tc_cursor.visible = true
		var phase: float = age / _vis.cursor_traverse_seconds
		var fade:  float = 1.0 - smoothstep(0.8, 1.0, phase)
		tc_cursor.position = VisGeomUtils.path_eval(
			tc.get("path", [tc["p_from"], tc["p_to"]]) as Array,
			tc.get("cum",  []) as Array,
			phase)

		# Color channel cursor by the source-pin voltage (what's flowing through).
		var tdata: Dictionary = _vis._transistor_data.get(str(tc["comp_name"]), {})
		var from_pin: String  = str(tc.get("from_spice_pin", "s"))
		var v_src: float      = get_net_voltage_at(str(tdata.get(from_pin, "")), lo) if not tdata.is_empty() else 0.9
		var tc_mat: StandardMaterial3D = tc["cursor_mat"]
		tc_mat.emission = voltage_to_color(v_src)
		tc_mat.emission_energy_multiplier = (voltage_to_energy(v_src) + 1.0) * fade


## Moves gate cursor spheres from wire to gate pin.
## On completion: fires contact flash, lights gap fill, fires channel cursor.
func _update_gate_cursors(lo: int) -> void:
	for i: int in range(_vis._gate_cursors.size()):
		var gc:        Dictionary     = _vis._gate_cursors[i]
		var gc_cursor: MeshInstance3D = gc["cursor"]
		var g_trav:    float          = float(gc.get("traverse", _vis.cursor_traverse_seconds * 0.35))
		var age:       float          = _vis._real_elapsed - float(gc["trigger_t"])
		var is_idle:   bool           = age < 0.0 or age > g_trav
		var was_idle:  bool           = _vis._gc_was_done[i] if i < _vis._gc_was_done.size() else true
		_vis._gc_was_done[i] = is_idle

		var cn: String = str(gc["comp_name"])

		# Read transistor body color — already updated by _update_transistor_glow.
		var tmat_color:  Color = Color(0.5, 0.5, 0.5)
		var tmat_energy: float = 1.0
		if _vis._transistor_materials.has(cn):
			var tmat: StandardMaterial3D = _vis._transistor_materials[cn]
			tmat_color  = tmat.emission
			tmat_energy = tmat.emission_energy_multiplier

		# Traveling gate cursor.
		if is_idle:
			gc_cursor.visible = false
			if not was_idle:
				gc["gbar_t"]   = _vis._real_elapsed
				gc["gflash_t"] = _vis._real_elapsed
				_fire_channel_cursor(cn, lo)
		else:
			gc_cursor.visible = true
			var phase: float = clamp(age / g_trav, 0.0, 1.0)
			var fade:  float = 1.0 - smoothstep(0.8, 1.0, phase)
			gc_cursor.position = (gc["p_from"] as Vector3).lerp(gc["p_to"] as Vector3, phase)
			var gc_mat: StandardMaterial3D = gc["cursor_mat"]
			# Gate cursor uses the gate net voltage color.
			var gate_net: String = str(gc["gate_net"])
			var v_gate: float = get_net_voltage_at(gate_net, lo)
			gc_mat.emission = voltage_to_color(v_gate)
			gc_mat.emission_energy_multiplier = tmat_energy * 2.0 * fade

		# Contact flash.
		var gflash: MeshInstance3D         = gc["gflash"]
		var gflash_mat: StandardMaterial3D = gc["gflash_mat"]
		var flash_age: float = _vis._real_elapsed - float(gc.get("gflash_t", -999.0))
		if flash_age >= 0.0 and flash_age <= 0.5:
			gflash.visible = true
			var fp: float      = flash_age / 0.5
			var flash_e: float = smoothstep(0.0, 0.15, fp) * (1.0 - smoothstep(0.6, 1.0, fp))
			gflash_mat.emission = tmat_color
			gflash_mat.emission_energy_multiplier = flash_e * 8.0
			if _vis._transistor_materials.has(cn):
				var tmat: StandardMaterial3D = _vis._transistor_materials[cn]
				tmat.emission_energy_multiplier = maxf(tmat.emission_energy_multiplier, flash_e * 3.5)
		else:
			gflash.visible = false

		# Gate oxide gap fill.
		var gbar: MeshInstance3D         = gc["gbar"]
		var gbar_mat: StandardMaterial3D = gc["gbar_mat"]
		var gbar_age: float = _vis._real_elapsed - float(gc.get("gbar_t", -999.0))
		if gbar_age < 0.0 or gbar_age > 1.0:
			gbar.visible = false
		else:
			gbar.visible = true
			gbar_mat.emission = tmat_color
			gbar_mat.emission_energy_multiplier = smoothstep(0.0, 0.1, gbar_age) * (1.0 - smoothstep(0.6, 1.0, gbar_age)) * tmat_energy


## Arms transistor gate cursors wherever ngspice conductance is above threshold.
## Replaces the old cascade-based trigger and unlabeled-gate trigger with a single
## direct voltage read per transistor per frame.
func _trigger_transistors_from_voltage(lo: int) -> void:
	var next_idx: int = mini(lo + 1, _vis._sim_time.size() - 1)
	for comp_name: String in _vis._transistor_data.keys():
		var tdata: Dictionary = _vis._transistor_data[comp_name]
		var gate_net: String  = str(tdata["g"])

		# Detect a transition on the gate net this frame.
		if _vis._sim_vectors.has(gate_net):
			var cvec: Array = _vis._sim_vectors[gate_net]
			if lo < cvec.size() and next_idx < cvec.size():
				var dv: float = absf(float(cvec[next_idx]) - float(cvec[lo]))
				if dv / VMAX >= _vis.dv_anim_threshold:
					try_trigger_transistor_cursor(comp_name, lo)
					continue

		# No transition — still trigger if currently conducting (keeps glow responsive).
		try_trigger_transistor_cursor(comp_name, lo)
