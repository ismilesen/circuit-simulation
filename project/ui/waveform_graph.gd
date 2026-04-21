## WaveformGraph — Control node that renders a voltage-vs-time waveform
## using Godot's _draw() API.  Owned and driven by WaveformPanel.
##
## Call set_data() once when a net is selected, then set_cursor() + queue_redraw()
## every frame to animate the playback cursor.
class_name WaveformGraph
extends Control

# ── Visual constants ──────────────────────────────────────────────────
const BG_COLOR:     Color = Color(0.05, 0.05, 0.07, 1.0)
const GRID_COLOR:   Color = Color(0.20, 0.20, 0.22, 1.0)
const AXIS_COLOR:   Color = Color(0.55, 0.55, 0.55, 1.0)
const WAVE_COLOR:   Color = Color(1.00, 0.88, 0.08, 1.0)
const CURSOR_COLOR: Color = Color(1.00, 1.00, 0.72, 0.95)
const ZERO_COLOR:   Color = Color(0.30, 0.30, 0.35, 1.0)

# Padding: left for Y labels, bottom for X labels, right/top margin.
const PAD_L: float = 38.0
const PAD_B: float = 18.0
const PAD_R: float =  6.0
const PAD_T: float =  6.0

# ── Data ─────────────────────────────────────────────────────────────
var _time_vec: Array  = []
var _volt_vec: Array  = []
var _vmax:     float  = 1.8
var _t_start:  float  = 0.0
var _t_end:    float  = 1.0

# Cursor position in simulation seconds.
var _cursor_t: float  = 0.0


func set_data(time_vec: Array, volt_vec: Array, vmax: float) -> void:
	_time_vec = time_vec
	_volt_vec = volt_vec
	_vmax     = vmax if vmax > 0.0 else 1.8
	if time_vec.size() >= 2:
		_t_start = float(time_vec[0])
		_t_end   = float(time_vec[time_vec.size() - 1])
	queue_redraw()


func set_cursor(sim_t: float) -> void:
	_cursor_t = sim_t


# ── Coordinate helpers ────────────────────────────────────────────────

func _plot_w() -> float:
	return size.x - PAD_L - PAD_R

func _plot_h() -> float:
	return size.y - PAD_T - PAD_B

func _t_to_x(t: float) -> float:
	var dur: float = _t_end - _t_start
	if dur <= 0.0:
		return PAD_L
	return PAD_L + (_plot_w() * (t - _t_start) / dur)

func _v_to_y(v: float) -> float:
	return PAD_T + _plot_h() * (1.0 - clamp(v / _vmax, 0.0, 1.0))


# ── Drawing ───────────────────────────────────────────────────────────

func _draw() -> void:
	var w := _plot_w()
	var h := _plot_h()

	# Background
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)

	if _time_vec.size() < 2:
		_draw_no_data()
		return

	_draw_grid(w, h)
	_draw_waveform()
	_draw_cursor(h)
	_draw_axes(w, h)


func _draw_no_data() -> void:
	draw_string(
		ThemeDB.fallback_font,
		Vector2(size.x * 0.5 - 40, size.y * 0.5),
		"No data",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, AXIS_COLOR)


func _draw_grid(w: float, h: float) -> void:
	# Horizontal voltage grid lines: 0 V, Vmax/2, Vmax
	var v_levels: Array = [0.0, _vmax * 0.5, _vmax]
	for v in v_levels:
		var y := _v_to_y(v)
		draw_line(Vector2(PAD_L, y), Vector2(PAD_L + w, y),
			ZERO_COLOR if v == 0.0 else GRID_COLOR, 1.0)

	# Vertical time grid lines: 25 %, 50 %, 75 %
	for frac: float in [0.25, 0.5, 0.75]:
		var x: float = PAD_L + w * frac
		draw_line(Vector2(x, PAD_T), Vector2(x, PAD_T + h), GRID_COLOR, 1.0)


func _draw_axes(w: float, h: float) -> void:
	var font := ThemeDB.fallback_font

	# Y-axis labels
	var v_levels: Array = [0.0, _vmax * 0.5, _vmax]
	for v in v_levels:
		var y := _v_to_y(v)
		var label := "%.2fV" % v
		draw_string(font, Vector2(0.0, y + 4.0),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, AXIS_COLOR)

	# X-axis labels at 0 %, 25 %, 50 %, 75 %, 100 %
	var dur: float = _t_end - _t_start
	for frac: float in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var t_ns: float = (_t_start + dur * frac) * 1e9
		var label: String = "%.0fns" % t_ns
		var x: float = PAD_L + w * frac
		draw_string(font, Vector2(x - 10.0, PAD_T + h + 13.0),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, AXIS_COLOR)


func _draw_waveform() -> void:
	var count: int = mini(_time_vec.size(), _volt_vec.size())
	if count < 2:
		return
	var pts := PackedVector2Array()
	pts.resize(count)
	for i in count:
		pts[i] = Vector2(_t_to_x(float(_time_vec[i])), _v_to_y(float(_volt_vec[i])))
	draw_polyline(pts, WAVE_COLOR, 1.5, true)


func _draw_cursor(h: float) -> void:
	# Wrap cursor into [t_start, t_end] to match the looping animation.
	var dur: float = _t_end - _t_start
	var ct: float  = _t_start + fmod(_cursor_t - _t_start, dur) if dur > 0.0 else _t_start
	var cx: float  = _t_to_x(ct)
	draw_line(Vector2(cx, PAD_T), Vector2(cx, PAD_T + h), CURSOR_COLOR, 1.5)
	draw_rect(Rect2(cx - 3.5, PAD_T - 3.5, 7.0, 7.0), CURSOR_COLOR)
