class_name OscilloscopePanel
extends Panel

const MAX_POINTS := 1024

var _net_name: String = ""
var _time_data: PackedFloat64Array = PackedFloat64Array()
var _voltage_data: PackedFloat64Array = PackedFloat64Array()

var _waveform: OscilloscopeWaveform = null
var _title_label: Label = null
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO

signal close_requested


func _ready() -> void:
	custom_minimum_size = Vector2(500, 280)
	size = Vector2(500, 280)
	mouse_filter = Control.MOUSE_FILTER_STOP
	hide()

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.102, 0.09, 0.0, 0.95)
	style.border_color = Color(0.64, 0.606, 0.205, 1.0)
	style.set_border_width_all(1)
	style.corner_radius_top_left     = 4
	style.corner_radius_top_right    = 4
	style.corner_radius_bottom_left  = 4
	style.corner_radius_bottom_right = 4
	add_theme_stylebox_override("panel", style)

	_build_ui()


func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 0)
	add_child(vbox)

	# ── Title bar ──────────────────────────────────────────────────────────
	var bar := Panel.new()
	bar.custom_minimum_size.y = 28
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	var bar_style := StyleBoxFlat.new()
	bar_style.bg_color = Color(0.114, 0.143, 0.063, 1.0)
	bar.add_theme_stylebox_override("panel", bar_style)
	vbox.add_child(bar)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 4)
	bar.add_child(hbox)

	var dot := Label.new()
	dot.text = "◉"
	dot.custom_minimum_size.x = 22
	dot.add_theme_color_override("font_color", Color(0.2, 1.0, 0.35))
	dot.add_theme_font_size_override("font_size", 11)
	dot.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(dot)

	_title_label = Label.new()
	_title_label.text = "Oscilloscope"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.75, 1.0, 0.75))
	_title_label.add_theme_font_size_override("font_size", 12)
	hbox.add_child(_title_label)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.custom_minimum_size = Vector2(26, 26)
	close_btn.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	close_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.4, 0.4))
	close_btn.pressed.connect(_on_close_pressed)
	hbox.add_child(close_btn)

	bar.gui_input.connect(_on_bar_gui_input)

	# ── Waveform area ───────────────────────────────────────────────────────
	_waveform = OscilloscopeWaveform.new()
	_waveform.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_waveform.panel = self
	vbox.add_child(_waveform)


## Show panel monitoring the given net, clearing any previous trace.
func setup(net_name: String) -> void:
	_net_name = net_name
	_time_data.clear()
	_voltage_data.clear()
	if _title_label != null:
		_title_label.text = "Net:  %s" % net_name
	if _waveform != null:
		_waveform.queue_redraw()
	show()
	var vp := get_viewport_rect().size
	position = Vector2(vp.x - size.x - 20.0, vp.y - size.y - 20.0)


## Append one (time, voltage) sample to the rolling buffer.
func push_sample(time_val: float, voltage: float) -> void:
	_time_data.append(time_val)
	_voltage_data.append(voltage)
	while _time_data.size() > MAX_POINTS:
		_time_data.remove_at(0)
		_voltage_data.remove_at(0)
	if _waveform != null:
		_waveform.queue_redraw()


func _on_close_pressed() -> void:
	close_requested.emit()
	hide()


func _on_bar_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if event.pressed:
			_drag_offset = position - event.global_position


func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		position = event.global_position + _drag_offset
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and not event.pressed:
		_dragging = false
