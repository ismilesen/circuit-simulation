## WaveformPanel — floating, draggable overlay showing voltage vs. time for one net.
##
## Usage:
##   panel.show_net(net_name, time_vec, volt_vec, vmax)
##   panel.update_sim_time(sim_t, sim_duration)   # call every frame while playing
##   panel.hide_panel()
class_name WaveformPanel
extends PanelContainer

# ── Layout constants ────────────────────────────────────────────────────
const TITLE_H:  float = 28.0
const PANEL_W:  float = 420.0
const GRAPH_H:  float = 220.0
const STATUS_H: float = 20.0

# ── Child refs ──────────────────────────────────────────────────────────
var _title_lbl:   Label
var _close_btn:   Button
var _graph:       WaveformGraph
var _volt_lbl:    Label

# ── Drag state ──────────────────────────────────────────────────────────
var _dragging:    bool    = false
var _drag_offset: Vector2 = Vector2.ZERO

# ── Simulation state ────────────────────────────────────────────────────
var _net_name:    String = ""
var _time_vec:    Array  = []
var _volt_vec:    Array  = []
var _sim_dur:     float  = 0.0


func _ready() -> void:
	_build_ui()
	hide()


func _build_ui() -> void:
	custom_minimum_size = Vector2(PANEL_W, TITLE_H + GRAPH_H + STATUS_H + 16.0)

	# Outer margin
	add_theme_constant_override("margin_left",   6)
	add_theme_constant_override("margin_right",  6)
	add_theme_constant_override("margin_top",    4)
	add_theme_constant_override("margin_bottom", 6)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	# ── Title bar ────────────────────────────────────────────────────────
	var title_row := HBoxContainer.new()
	title_row.custom_minimum_size = Vector2(0, TITLE_H)
	title_row.add_theme_constant_override("separation", 6)
	vbox.add_child(title_row)

	var drag_label := Label.new()
	drag_label.text = "⣿"
	drag_label.modulate = Color(0.5, 0.5, 0.5)
	drag_label.add_theme_font_size_override("font_size", 10)
	drag_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(drag_label)

	_title_lbl = Label.new()
	_title_lbl.text = "—"
	_title_lbl.add_theme_font_size_override("font_size", 12)
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	title_row.add_child(_title_lbl)

	_close_btn = Button.new()
	_close_btn.text = "✕"
	_close_btn.flat = true
	_close_btn.add_theme_font_size_override("font_size", 11)
	_close_btn.custom_minimum_size = Vector2(24, 24)
	_close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_close_btn.pressed.connect(hide_panel)
	title_row.add_child(_close_btn)

	# ── Waveform graph ────────────────────────────────────────────────────
	_graph = WaveformGraph.new()
	_graph.custom_minimum_size = Vector2(0, GRAPH_H)
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_graph)

	# ── Live voltage readout ──────────────────────────────────────────────
	_volt_lbl = Label.new()
	_volt_lbl.text = "cursor: — V  |  t = — ns"
	_volt_lbl.add_theme_font_size_override("font_size", 12)
	_volt_lbl.modulate = Color(0.75, 0.75, 0.75)
	vbox.add_child(_volt_lbl)


# ── Input: drag the panel by clicking its title bar ──────────────────────

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			# Only start drag if click is within the title row height.
			if mb.pressed and mb.position.y <= TITLE_H + 8.0:
				_dragging    = true
				_drag_offset = mb.global_position - global_position
				accept_event()
			elif not mb.pressed:
				_dragging = false

	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var new_pos: Vector2 = mm.global_position - _drag_offset
		# Clamp inside viewport.
		var vp_size: Vector2 = get_viewport_rect().size
		new_pos.x = clamp(new_pos.x, 0.0, vp_size.x - size.x)
		new_pos.y = clamp(new_pos.y, 0.0, vp_size.y - size.y)
		global_position = new_pos
		accept_event()


# ── Public API ────────────────────────────────────────────────────────────

## Display a net's waveform. time_vec and volt_vec are plain Arrays of floats.
## vmax is the Y-axis ceiling (typically 1.8 for sky130).
func show_net(net_name: String, time_vec: Array, volt_vec: Array, vmax: float) -> void:
	_net_name = net_name
	_time_vec = time_vec
	_volt_vec = volt_vec
	_sim_dur  = (float(time_vec[time_vec.size() - 1]) - float(time_vec[0])) if time_vec.size() >= 2 else 0.0

	_title_lbl.text = "net: " + net_name
	_graph.set_data(time_vec, volt_vec, vmax)
	_volt_lbl.text = "cursor: — V  |  t = — ns"
	show()


## Called every frame by 3Dschvisualizer while the animation is playing.
## sim_t is the current looped simulation time in seconds (SI).
func update_sim_time(sim_t: float) -> void:
	if not visible:
		return
	_graph.set_cursor(sim_t)
	_graph.queue_redraw()
	_update_volt_label(sim_t)


## Live mode: update the rolling waveform without resetting cursor or net name.
## Called once per Godot frame (from continuous_transient_frame) not per sample.
func update_live_data(time_vec: Array, volt_vec: Array, vmax: float) -> void:
	if not visible:
		return
	_time_vec = time_vec
	_volt_vec = volt_vec
	_graph.set_data(time_vec, volt_vec, vmax)
	# Cursor tracks the live edge — latest time in the rolling window.
	if time_vec.size() > 0:
		var latest_t: float = float(time_vec[time_vec.size() - 1])
		_graph.set_cursor(latest_t)
		_update_volt_label(latest_t)
	_graph.queue_redraw()


## Close and clear the panel.
func hide_panel() -> void:
	_net_name = ""
	_time_vec = []
	_volt_vec = []
	hide()


# ── Internal ──────────────────────────────────────────────────────────────

## Interpolates the volt_vec at sim_t and updates the readout label.
func _update_volt_label(sim_t: float) -> void:
	if _time_vec.size() < 2 or _volt_vec.size() < 2:
		return

	var t_start: float = float(_time_vec[0])
	var t_end:   float = float(_time_vec[_time_vec.size() - 1])
	var dur:     float = t_end - t_start
	if dur <= 0.0:
		return

	# Wrap sim_t to match the looping animation.
	var ct: float = t_start + fmod(sim_t - t_start, dur)

	# Binary search for the bracketing index.
	var lo: int = 0
	var hi: int = _time_vec.size() - 2
	while lo < hi:
		var mid: int = (lo + hi + 1) / 2
		if float(_time_vec[mid]) <= ct:
			lo = mid
		else:
			hi = mid - 1

	var t0: float = float(_time_vec[lo])
	var t1: float = float(_time_vec[lo + 1])
	var v0: float = float(_volt_vec[lo])
	var v1: float = float(_volt_vec[lo + 1])
	var frac: float = (ct - t0) / maxf(t1 - t0, 1e-15)
	var volt: float = lerp(v0, v1, frac)

	_volt_lbl.text = "cursor: %.3f V  |  t = %.1f ns" % [volt, ct * 1e9]
