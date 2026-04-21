## VoltageKeyPanel — compact legend showing the yellow voltage-colour ramp.
## Instantiated by 3Dschvisualizer and added to its UILayer.
class_name VoltageKeyPanel
extends Control

const _STOPS: Array = [
	# [voltage, Color]  — ordered high → low so bar reads top=high, bottom=low
	[1.80, Color(1.00, 1.00, 0.72)],
	[1.35, Color(1.00, 0.88, 0.08)],
	[0.90, Color(0.76, 0.62, 0.00)],
	[0.45, Color(0.38, 0.26, 0.00)],
	[0.00, Color(0.06, 0.04, 0.00)],
]

const GRAD_STEPS: int  = 60
const BG_COLOR:   Color = Color(0.08, 0.08, 0.10, 0.92)
const BORDER_COLOR: Color = Color(0.25, 0.25, 0.28, 1.0)

var _vmax: float = 1.8


func _ready() -> void:
	custom_minimum_size = Vector2(160.0, 200.0)


func set_vmax(vmax: float) -> void:
	_vmax = vmax
	queue_redraw()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y

	# Background + border
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)
	draw_rect(Rect2(Vector2.ZERO, size), BORDER_COLOR, false, 1.0)

	var font := ThemeDB.fallback_font

	# ── Title ──────────────────────────────────────────────────────────────
	draw_string(font, Vector2(0.0, 16.0),
		"Net Voltage", HORIZONTAL_ALIGNMENT_CENTER, w, 11, Color(0.85, 0.85, 0.85))

	# ── Gradient bar ───────────────────────────────────────────────────────
	const BAR_X: float = 10.0
	const BAR_W: float = 18.0
	const BAR_T: float = 26.0
	const BAR_B: float = 186.0
	var bar_h: float = BAR_B - BAR_T

	for i: int in range(GRAD_STEPS):
		var t0: float   = float(i)     / float(GRAD_STEPS)
		var v_mid: float = _vmax * (1.0 - (t0 + 0.5 / float(GRAD_STEPS)))
		var c: Color    = _voltage_to_color(v_mid)
		var y0: float   = BAR_T + bar_h * t0
		var seg_h: float = bar_h / float(GRAD_STEPS) + 0.6
		draw_rect(Rect2(BAR_X, y0, BAR_W, seg_h), c)

	# Bar outline
	draw_rect(Rect2(BAR_X, BAR_T, BAR_W, bar_h), Color(0.45, 0.45, 0.45), false, 1.0)

	# ── Tick marks + voltage labels ────────────────────────────────────────
	const TICK_X0: float = BAR_X + BAR_W + 3.0
	const TICK_X1: float = BAR_X + BAR_W + 9.0
	const LABEL_X: float = BAR_X + BAR_W + 12.0

	for stop in _STOPS:
		var v: float    = float(stop[0]) * (_vmax / 1.8)
		var c: Color    = stop[1] as Color
		var frac: float = 1.0 - clamp(v / _vmax, 0.0, 1.0)
		var y: float    = BAR_T + bar_h * frac

		draw_line(Vector2(TICK_X0, y), Vector2(TICK_X1, y), Color(0.55, 0.55, 0.55), 1.0)
		draw_string(font, Vector2(LABEL_X, y + 5.0),
			"%.2f V" % v, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, c)


func _voltage_to_color(v: float) -> Color:
	var t: float = clamp(v / _vmax, 0.0, 1.0)
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
