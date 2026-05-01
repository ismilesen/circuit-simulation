class_name AnimControlOverlay
extends CanvasLayer

## In-game overlay panel for live animation speed controls.
##
## Usage:
##   In your scene tree, add a new node of type AnimControlOverlay (this script
##   extends CanvasLayer, so search for that base type and attach this script).
##   It will auto-find the 3DSchVisualizer node by looking for load_schematic().
##   Press [H] to show / hide the panel while the simulation is running.
##
## Theme:
##   The overlay tracks the upload panel's dark/light theme by subscribing to
##   its `dark_mode_changed(dark_mode)` signal. The upload panel's "Dark Theme"
##   / "Light Theme" button is the single source of truth.

## Key that toggles the panel visibility.
@export var toggle_key: Key = KEY_H

## Width of the control panel in pixels.
@export var panel_width: float = 300.0

# --- XP Luna palette (light) ---
const XP_FACE              := Color("ECE9D8")
const XP_WHITE             := Color(1, 1, 1)
const XP_TEXT              := Color(0, 0, 0)
const XP_SUBTEXT           := Color("404040")
const XP_CTRL_BORDER       := Color("7F9DB9")
const XP_CTRL_SHADOW       := Color("404D5B")
const XP_BTN_FACE          := Color("ECEBE7")
const XP_BTN_HOVER_FACE    := Color("FFECC6")
const XP_BTN_HOVER_BORDER  := Color("E2A936")
const XP_BTN_PRESSED_FACE  := Color("B6CFE6")
const XP_BTN_PRESSED_BORDER := Color("2A5CAA")
const XP_SEL_BLUE          := Color("316AC5")
const XP_SEL_BLUE_DARK     := Color("1C3F7C")
const XP_TITLE_BLUE        := Color("0A246A")

# --- Dark variant (matches upload_panel.gd dark palette) ---
const DK_FACE              := Color("1C1B18")
const DK_WHITE             := Color("1A1918")
const DK_TEXT              := Color("E0DDD4")
const DK_SUBTEXT           := Color("8A8880")
const DK_CTRL_BORDER       := Color("4A5468")
const DK_CTRL_SHADOW       := Color("606878")
const DK_BTN_FACE          := Color("302E2A")
const DK_BTN_HOVER_FACE    := Color("3D300E")
const DK_BTN_HOVER_BORDER  := Color("907020")
const DK_BTN_PRESSED_FACE  := Color("152040")
const DK_BTN_PRESSED_BORDER := Color("204870")
const DK_SEL_BLUE          := Color("4A82D0")
const DK_SEL_BLUE_DARK     := Color("2A5090")
const DK_TITLE_BLUE        := Color("8AAED8")

# Reference to the 3DSchVisualizer (resolved at runtime).
var _vis: Node = null
var _panel: PanelContainer = null
var _content_vbox: VBoxContainer = null   # the slider area (hidden when minimized)
var _separator: HSeparator = null
var _title_label: Label = null
var _hint_label: Label = null
var _minimize_button: Button = null
var _upload_panel: Node = null

var _dark_mode: bool = false
var _collapsed: bool = false

# Tracked widgets we re-skin on theme change.
var _slider_rows: Array = []   # each: {row, header, label, value_label, slider}


func _ready() -> void:
	layer = 20  # renders above the sidebar (which uses layer 10)
	_resolve_visualizer()
	_resolve_upload_panel()
	_build_ui()
	_apply_theme()
	# Size the panel to fit its content once layout has settled.
	call_deferred("_resize_to_content")


## Pin the panel's bottom edge to bottom-right of the screen and grow upward
## to whatever height the current content needs.
func _resize_to_content() -> void:
	if _panel == null:
		return
	var min_h: float = _panel.get_combined_minimum_size().y
	_panel.offset_top = -12.0 - min_h
	_panel.offset_bottom = -12.0


func _unhandled_key_input(event: InputEvent) -> void:
	var ke := event as InputEventKey
	if ke and ke.pressed and not ke.echo and ke.keycode == toggle_key:
		if _panel != null:
			_panel.visible = not _panel.visible
		get_viewport().set_input_as_handled()


# ---------- UI construction ----------

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "AnimControlPanel"

	# Pin to the bottom-right corner and let the panel size to its content
	# (so the minimize button can actually shrink the panel's drawn bounds).
	_panel.anchor_left   = 1.0
	_panel.anchor_top    = 1.0
	_panel.anchor_right  = 1.0
	_panel.anchor_bottom = 1.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.grow_vertical   = Control.GROW_DIRECTION_BEGIN
	_panel.offset_left   = -(panel_width + 12.0)
	_panel.offset_right  = -12.0
	_panel.offset_top    = -12.0   # placeholder; updated by _reposition_panel()
	_panel.offset_bottom = -12.0
	_panel.custom_minimum_size = Vector2(panel_width, 0)
	_panel.size_flags_vertical = Control.SIZE_SHRINK_END

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	_panel.add_child(outer)

	# ── Title row ──────────────────────────────────────────────
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	outer.add_child(title_row)

	_title_label = Label.new()
	_title_label.text = "Animation Controls"
	_title_label.add_theme_font_size_override("font_size", 13)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_title_label)

	_hint_label = Label.new()
	_hint_label.text = "[H] hide"
	_hint_label.add_theme_font_size_override("font_size", 10)
	title_row.add_child(_hint_label)

	_minimize_button = Button.new()
	_minimize_button.text = "−"   # U+2212 minus sign
	_minimize_button.tooltip_text = "Minimize"
	_minimize_button.focus_mode = Control.FOCUS_NONE
	_minimize_button.custom_minimum_size = Vector2(22, 18)
	_minimize_button.add_theme_font_size_override("font_size", 12)
	_minimize_button.pressed.connect(_on_minimize_pressed)
	title_row.add_child(_minimize_button)

	# ── Collapsible content ────────────────────────────────────
	_content_vbox = VBoxContainer.new()
	_content_vbox.add_theme_constant_override("separation", 8)
	outer.add_child(_content_vbox)

	_separator = HSeparator.new()
	_content_vbox.add_child(_separator)

	# Overall playback loop duration (1 – 60 s).  Higher = slower.
	_add_slider(_content_vbox,
		"Loop duration", "s",
		1.0, 60.0, 0.5,
		_get_vis_float("anim_playback_duration", 5.0),
		func(v: float) -> void: _set_vis("anim_playback_duration", v))

	# How many real seconds the cursor takes to cross one wire (0.2 – 5 s).
	_add_slider(_content_vbox,
		"Cursor traverse", "s",
		0.2, 5.0, 0.1,
		_get_vis_float("cursor_traverse_seconds", 1.5),
		func(v: float) -> void: _set_vis("cursor_traverse_seconds", v))

	# Minimum ΔV/Vmax per sample required to show a cursor (sensitivity).
	_add_slider(_content_vbox,
		"Cursor sensitivity", "ΔV/Vmax",
		0.01, 0.50, 0.01,
		_get_vis_float("dv_anim_threshold", 0.04),
		func(v: float) -> void: _set_vis("dv_anim_threshold", v))

	add_child(_panel)


## Adds a labelled HSlider row to the given VBoxContainer.
func _add_slider(
		parent: VBoxContainer,
		label_text: String,
		unit: String,
		min_v: float, max_v: float, step_v: float, init_v: float,
		on_change: Callable) -> void:

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	parent.add_child(row)

	# Header: name on the left, live value on the right
	var header := HBoxContainer.new()
	row.add_child(header)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(lbl)

	var val_lbl := Label.new()
	val_lbl.text = _fmt(init_v, unit)
	val_lbl.add_theme_font_size_override("font_size", 11)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.custom_minimum_size.x = 80.0
	header.add_child(val_lbl)

	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step      = step_v
	slider.value     = init_v
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	slider.value_changed.connect(func(v: float) -> void:
		val_lbl.text = _fmt(v, unit)
		on_change.call(v)
	)

	_slider_rows.append({
		"row": row,
		"header": header,
		"label": lbl,
		"value_label": val_lbl,
		"slider": slider,
	})


# ---------- Minimize ----------

func _on_minimize_pressed() -> void:
	_collapsed = not _collapsed
	if _content_vbox != null:
		_content_vbox.visible = not _collapsed
	if _minimize_button != null:
		_minimize_button.text = "▢" if _collapsed else "−"
		_minimize_button.tooltip_text = "Restore" if _collapsed else "Minimize"
	# Force the PanelContainer to recompute its size now that its child's
	# minimum height has changed; otherwise it would keep its previous bounds.
	if _panel != null:
		_panel.reset_size()
	# Defer so Godot has a frame to recompute combined_minimum_size after
	# the visibility change propagates through the container hierarchy.
	call_deferred("_resize_to_content")


# ---------- Theme construction ----------

## Build / rebuild the local theme & per-widget colors based on `_dark_mode`.
func _apply_theme() -> void:
	# Choose palette
	var face: Color
	var white: Color
	var text: Color
	var subtext: Color
	var ctrl_border: Color
	var btn_face: Color
	var btn_hover_face: Color
	var btn_hover_border: Color
	var btn_pressed_face: Color
	var btn_pressed_border: Color
	var sel_blue: Color
	var sel_blue_dark: Color
	var title_blue: Color

	if _dark_mode:
		face               = DK_FACE
		white              = DK_WHITE
		text               = DK_TEXT
		subtext            = DK_SUBTEXT
		ctrl_border        = DK_CTRL_BORDER
		btn_face           = DK_BTN_FACE
		btn_hover_face     = DK_BTN_HOVER_FACE
		btn_hover_border   = DK_BTN_HOVER_BORDER
		btn_pressed_face   = DK_BTN_PRESSED_FACE
		btn_pressed_border = DK_BTN_PRESSED_BORDER
		sel_blue           = DK_SEL_BLUE
		sel_blue_dark      = DK_SEL_BLUE_DARK
		title_blue         = DK_TITLE_BLUE
	else:
		face               = XP_FACE
		white              = XP_WHITE
		text               = XP_TEXT
		subtext            = XP_SUBTEXT
		ctrl_border        = XP_CTRL_BORDER
		btn_face           = XP_BTN_FACE
		btn_hover_face     = XP_BTN_HOVER_FACE
		btn_hover_border   = XP_BTN_HOVER_BORDER
		btn_pressed_face   = XP_BTN_PRESSED_FACE
		btn_pressed_border = XP_BTN_PRESSED_BORDER
		sel_blue           = XP_SEL_BLUE
		sel_blue_dark      = XP_SEL_BLUE_DARK
		title_blue         = XP_TITLE_BLUE

	# --- Panel background ---
	if _panel != null:
		var sb := StyleBoxFlat.new()
		sb.bg_color          = face
		sb.border_color      = ctrl_border
		sb.set_border_width_all(1)
		sb.corner_radius_top_left     = 3
		sb.corner_radius_top_right    = 3
		sb.corner_radius_bottom_left  = 3
		sb.corner_radius_bottom_right = 3
		sb.content_margin_left   = 14.0
		sb.content_margin_right  = 14.0
		sb.content_margin_top    = 10.0
		sb.content_margin_bottom = 12.0
		sb.shadow_color  = Color(0, 0, 0, 0.30)
		sb.shadow_size   = 4
		sb.shadow_offset = Vector2(0, 2)
		_panel.add_theme_stylebox_override("panel", sb)

	# --- Local theme for sliders & buttons inside the panel ---
	var t := Theme.new()

	# Slider track
	var sb_groove := StyleBoxFlat.new()
	sb_groove.bg_color     = white
	sb_groove.border_color = ctrl_border
	sb_groove.set_border_width_all(1)
	sb_groove.corner_radius_top_left     = 2
	sb_groove.corner_radius_top_right    = 2
	sb_groove.corner_radius_bottom_left  = 2
	sb_groove.corner_radius_bottom_right = 2
	sb_groove.content_margin_top    = 2
	sb_groove.content_margin_bottom = 2

	var sb_grabber_area := sb_groove.duplicate() as StyleBoxFlat
	sb_grabber_area.bg_color     = sel_blue
	sb_grabber_area.border_color = sel_blue_dark

	var sb_grabber_area_hl := sb_grabber_area.duplicate() as StyleBoxFlat
	sb_grabber_area_hl.bg_color     = btn_hover_face
	sb_grabber_area_hl.border_color = btn_hover_border

	t.set_stylebox("slider", "HSlider", sb_groove)
	t.set_stylebox("grabber_area",           "HSlider", sb_grabber_area)
	t.set_stylebox("grabber_area_highlight", "HSlider", sb_grabber_area_hl)

	# Buttons (the minimize button picks these up automatically)
	var sb_btn := StyleBoxFlat.new()
	sb_btn.bg_color     = btn_face
	sb_btn.border_color = ctrl_border
	sb_btn.set_border_width_all(1)
	sb_btn.corner_radius_top_left     = 3
	sb_btn.corner_radius_top_right    = 3
	sb_btn.corner_radius_bottom_left  = 3
	sb_btn.corner_radius_bottom_right = 3
	sb_btn.content_margin_left   = 4
	sb_btn.content_margin_right  = 4
	sb_btn.content_margin_top    = 1
	sb_btn.content_margin_bottom = 1

	var sb_btn_hover := sb_btn.duplicate() as StyleBoxFlat
	sb_btn_hover.bg_color     = btn_hover_face
	sb_btn_hover.border_color = btn_hover_border

	var sb_btn_pressed := sb_btn.duplicate() as StyleBoxFlat
	sb_btn_pressed.bg_color     = btn_pressed_face
	sb_btn_pressed.border_color = btn_pressed_border

	t.set_stylebox("normal",  "Button", sb_btn)
	t.set_stylebox("hover",   "Button", sb_btn_hover)
	t.set_stylebox("pressed", "Button", sb_btn_pressed)
	t.set_color("font_color",         "Button", text)
	t.set_color("font_hover_color",   "Button", text)
	t.set_color("font_pressed_color", "Button", text)

	# Default Label color
	t.set_color("font_color", "Label", text)
	t.set_constant("separation", "HSeparator", 6)

	if _panel != null:
		_panel.theme = t

	# --- Per-widget color overrides ---
	if _title_label != null:
		_title_label.add_theme_color_override("font_color", title_blue)
	if _hint_label != null:
		_hint_label.add_theme_color_override("font_color", subtext)
	if _separator != null:
		_separator.add_theme_color_override("color", ctrl_border)

	for r in _slider_rows:
		var lbl: Label = r.get("label")
		var val_lbl: Label = r.get("value_label")
		if lbl != null:
			lbl.add_theme_color_override("font_color", text)
		if val_lbl != null:
			val_lbl.add_theme_color_override("font_color", title_blue)


# ---------- Upload panel hookup ----------

func _resolve_upload_panel() -> void:
	if _upload_panel != null:
		return
	for c: Node in get_tree().root.find_children("*", "", true, false):
		if c.has_signal("dark_mode_changed") and c.has_method("is_dark_mode"):
			_upload_panel = c
			break
	if _upload_panel == null:
		return
	# Sync to current theme and listen for future toggles.
	_dark_mode = bool(_upload_panel.call("is_dark_mode"))
	_upload_panel.connect("dark_mode_changed", Callable(self, "_on_upload_theme_changed"))


func _on_upload_theme_changed(dark_mode: bool) -> void:
	_dark_mode = dark_mode
	_apply_theme()


# ---------- Helpers ----------

## Formats a value + unit label for the live readout.
func _fmt(v: float, unit: String) -> String:
	if absf(v) >= 100.0:
		return "%d %s" % [int(v), unit]
	elif absf(v) >= 1.0:
		return "%.1f %s" % [v, unit]
	else:
		return "%.2f %s" % [v, unit]


## Finds the 3DSchVisualizer by duck-typing: first node that has load_schematic().
func _resolve_visualizer() -> void:
	if _vis != null:
		return
	for c: Node in get_tree().root.find_children("*", "", true, false):
		if c.has_method("load_schematic"):
			_vis = c
			return
	push_warning("AnimControlOverlay: could not find a node with load_schematic(). " +
		"Make sure the 3DSchVisualizer is in the scene tree before this overlay.")


## Returns a float property from the visualizer, or a default if absent.
func _get_vis_float(prop: String, default_val: float) -> float:
	if _vis != null and prop in _vis:
		return float(_vis.get(prop))
	return default_val


## Sets a property on the visualizer (silently ignores unknown props).
func _set_vis(prop: String, value: float) -> void:
	if _vis != null and prop in _vis:
		_vis.set(prop, value)
