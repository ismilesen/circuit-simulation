class_name OscilloscopeWaveform
extends Control

var panel: Control = null

const BG_COLOR    := Color(0.013, 0.03, 0.013, 1.0)
const GRID_COLOR  := Color(0.259, 0.24, 0.135, 1.0)
const AXIS_COLOR  := Color(0.504, 0.582, 0.537, 1.0)
const WAVE_COLOR  := Color(0.855, 0.878, 0.0, 1.0)
const LABEL_COLOR := Color(0.721, 0.8, 0.577, 1.0)
const WAIT_COLOR  := Color(0.20, 0.45, 0.20, 1.0)

const PAD_LEFT   := 46.0
const PAD_RIGHT  := 10.0
const PAD_TOP    := 10.0
const PAD_BOTTOM := 22.0
const VMAX       := 1.8


func _draw() -> void:
	var sz := size
	draw_rect(Rect2(Vector2.ZERO, sz), BG_COLOR)
	if panel == null:
		return

	var pw := sz.x - PAD_LEFT - PAD_RIGHT
	var ph := sz.y - PAD_TOP  - PAD_BOTTOM
	var ox := PAD_LEFT
	var oy := PAD_TOP
	var font := ThemeDB.fallback_font

	# Border
	draw_rect(Rect2(ox, oy, pw, ph), AXIS_COLOR, false, 1.0)

	# Horizontal grid: 0 V, 0.6 V, 1.2 V, 1.8 V
	for i: int in range(4):
		var frac := float(i) / 3.0
		var y := oy + ph * (1.0 - frac)
		var col := AXIS_COLOR if (i == 0 or i == 3) else GRID_COLOR
		draw_line(Vector2(ox, y), Vector2(ox + pw, y), col, 1.0)
		draw_string(font, Vector2(2.0, y + 4.0), "%.1fV" % (frac * VMAX),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, LABEL_COLOR)

	# Vertical grid: 4 divisions
	for i: int in range(5):
		var frac := float(i) / 4.0
		var x := ox + pw * frac
		var col := AXIS_COLOR if (i == 0 or i == 4) else GRID_COLOR
		draw_line(Vector2(x, oy), Vector2(x, oy + ph), col, 1.0)

	# Time axis label
	draw_string(font, Vector2(ox + pw * 0.5 - 18.0, sz.y - 4.0),
			"time →", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, LABEL_COLOR)

	var n: int = panel._time_data.size()
	if n < 2:
		draw_string(font, Vector2(ox + pw * 0.5 - 48.0, oy + ph * 0.5 + 5.0),
				"waiting for data...", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, WAIT_COLOR)
		return

	var t_min: float = panel._time_data[0]
	var t_max: float = panel._time_data[n - 1]
	var t_range: float = t_max - t_min

	var pts := PackedVector2Array()
	pts.resize(n)
	for i: int in range(n):
		var tx: float = float(i) / float(n - 1) if t_range <= 1e-15 \
				else (panel._time_data[i] - t_min) / t_range
		var vy := clamp(panel._voltage_data[i] / VMAX, 0.0, 1.0)
		pts[i] = Vector2(ox + tx * pw, oy + (1.0 - vy) * ph)

	draw_polyline(pts, WAVE_COLOR, 1.5, true)

	# Live voltage readout – top-right corner
	draw_string(font, Vector2(ox + pw - 42.0, oy + 14.0),
			"%.3fV" % panel._voltage_data[n - 1],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, WAVE_COLOR)

	# Time range – bottom-right corner
	if t_range > 1e-15:
		draw_string(font, Vector2(ox + pw - 95.0, sz.y - 4.0),
				_fmt_time(t_min) + " – " + _fmt_time(t_max),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, LABEL_COLOR)


func _fmt_time(t: float) -> String:
	if t < 1e-6:
		return "%.1fns" % (t * 1e9)
	if t < 1e-3:
		return "%.1fμs" % (t * 1e6)
	if t < 1.0:
		return "%.1fms" % (t * 1e3)
	return "%.2fs" % t
