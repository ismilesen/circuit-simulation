## SimStatusPanel — compact HUD overlay showing the current simulation stage,
## animation loop progress, current sim time, and key metrics.
##
## Instantiated programmatically by 3Dschvisualizer and added to its CanvasLayer.
## Call set_stage(), update_anim_progress(), and set_sim_info() to drive it.
class_name SimStatusPanel
extends PanelContainer

# Stage → indicator color
const _STAGE_COLORS: Dictionary = {
	"idle":       Color(0.45, 0.45, 0.45),
	"loading":    Color(1.00, 0.85, 0.00),
	"simulating": Color(1.00, 0.50, 0.10),
	"playing":    Color(0.20, 1.00, 0.40),
	"error":      Color(1.00, 0.20, 0.20),
}

var _stage:        String  = "idle"
var _pulse_t:      float   = 0.0

# Child node references — built in _build_ui().
var _dot:       ColorRect
var _stage_lbl: Label
var _bar:       ProgressBar
var _time_lbl:  Label
var _stats_lbl: Label


func _ready() -> void:
	_build_ui()
	set_stage("idle")


func _build_ui() -> void:
	custom_minimum_size = Vector2(230, 0)

	# Outer margin
	add_theme_constant_override("margin_left",   10)
	add_theme_constant_override("margin_right",  10)
	add_theme_constant_override("margin_top",     8)
	add_theme_constant_override("margin_bottom",  8)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	add_child(vbox)

	# ── Row 1: status dot + stage label ───────────────────────────────
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vbox.add_child(header)

	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2(10, 10)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(_dot)

	_stage_lbl = Label.new()
	_stage_lbl.text = "Idle"
	_stage_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage_lbl.add_theme_font_size_override("font_size", 12)
	header.add_child(_stage_lbl)

	# ── Row 2: loop progress bar ───────────────────────────────────────
	_bar = ProgressBar.new()
	_bar.min_value        = 0.0
	_bar.max_value        = 100.0
	_bar.value            = 0.0
	_bar.show_percentage  = false
	_bar.custom_minimum_size = Vector2(0, 6)
	vbox.add_child(_bar)

	# ── Row 3: current sim time ────────────────────────────────────────
	_time_lbl = Label.new()
	_time_lbl.text = "— ns  /  — ns"
	_time_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(_time_lbl)

	# ── Row 4: stats (pts · nets · vectors) ───────────────────────────
	_stats_lbl = Label.new()
	_stats_lbl.text = "—"
	_stats_lbl.add_theme_font_size_override("font_size", 10)
	_stats_lbl.modulate = Color(0.7, 0.7, 0.7)
	vbox.add_child(_stats_lbl)


func _process(delta: float) -> void:
	# Pulse the dot for transient stages.
	if _stage == "loading" or _stage == "simulating":
		_pulse_t += delta * 4.0
		var alpha: float = 0.5 + 0.5 * sin(_pulse_t)
		var base: Color  = _STAGE_COLORS.get(_stage, Color.GRAY)
		_dot.color = base.lerp(Color.WHITE, alpha * 0.35)


# ── Public API ────────────────────────────────────────────────────────

## Set the current simulation stage.
## Valid values: "idle" | "loading" | "simulating" | "playing" | "error"
func set_stage(stage: String) -> void:
	_stage  = stage.to_lower()
	_stage_lbl.text = stage.capitalize()
	_dot.color      = _STAGE_COLORS.get(_stage, Color.GRAY)
	if _stage != "playing":
		_bar.value = 0.0
		_time_lbl.text = "— ns  /  — ns"


## Update the loop progress bar and current-time label each frame.
## sim_t and sim_duration are both in seconds (ngspice SI units).
func update_anim_progress(sim_t: float, sim_duration: float) -> void:
	if sim_duration > 0.0:
		_bar.value = (sim_t / sim_duration) * 100.0
	_time_lbl.text = "%.1f ns  /  %.0f ns" % [sim_t * 1e9, sim_duration * 1e9]


## Display loaded simulation metrics.
func set_sim_info(time_pts: int, net_count: int, vec_count: int) -> void:
	_stats_lbl.text = "%d pts  ·  %d nets  ·  %d vecs" % [time_pts, net_count, vec_count]


## Live-mode time display — replaces the fixed "X / Y ns" label with a
## scrolling counter so the user knows continuous data is arriving.
func set_live_time(sim_t: float) -> void:
	_time_lbl.text = "%.1f ns  (live)" % (sim_t * 1e9)
