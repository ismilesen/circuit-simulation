class_name SidebarPanel extends Control

signal schematic_requested(path: String)
signal spice_paired(path: String)
signal pdk_component_selected(component: Dictionary)

const UPLOAD_PANEL_SCENE := "res://ui/upload_panel.tscn"
const MIN_PANEL_WIDTH: float = 400.0
const MAX_PANEL_WIDTH: float = 720.0
const BUTTON_WIDTH: float = 32.0
const SLIDE_DURATION: float = 0.25

var _upload_panel: Control = null
var _toggle_button: Button = null
var _panel_visible: bool = true
var _pending_pdk_manifest: Variant = null
var _panel_width: float = MIN_PANEL_WIDTH
var _slide_tween: Tween = null


func _ready() -> void:
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 1.0

	_setup_panel()
	_setup_toggle_button()
	_sync_layout()
	call_deferred("_sync_layout")


func _process(_delta: float) -> void:
	if _panel_visible:
		_sync_layout(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_sync_layout()


func _setup_panel() -> void:
	var packed = load(UPLOAD_PANEL_SCENE)
	if packed == null:
		push_warning("Upload panel scene not found at: " + UPLOAD_PANEL_SCENE)
		return

	_upload_panel = (packed as PackedScene).instantiate()
	_upload_panel.anchor_left = 0.0
	_upload_panel.anchor_top = 0.0
	_upload_panel.anchor_right = 0.0
	_upload_panel.anchor_bottom = 1.0
	_upload_panel.offset_left = 0.0
	_upload_panel.offset_top = 0.0
	_upload_panel.offset_right = _panel_width
	_upload_panel.offset_bottom = 0.0
	_upload_panel.clip_contents = true
	add_child(_upload_panel)

	if _upload_panel.has_signal("schematic_requested"):
		_upload_panel.schematic_requested.connect(func(path: String): schematic_requested.emit(path))
	if _upload_panel.has_signal("spice_paired"):
		_upload_panel.spice_paired.connect(func(path: String): spice_paired.emit(path))
	if _upload_panel.has_signal("pdk_component_selected"):
		_upload_panel.pdk_component_selected.connect(func(component: Dictionary): pdk_component_selected.emit(component))

	if _pending_pdk_manifest != null and _upload_panel.has_method("set_pdk_manifest"):
		_upload_panel.set_pdk_manifest(_pending_pdk_manifest)


func set_pdk_manifest(manifest: Variant) -> void:
	_pending_pdk_manifest = manifest
	if _upload_panel != null and _upload_panel.has_method("set_pdk_manifest"):
		_upload_panel.set_pdk_manifest(manifest)


func _setup_toggle_button() -> void:
	_toggle_button = Button.new()
	_toggle_button.name = "ToggleSidebar"
	_toggle_button.text = "<"
	_toggle_button.anchor_left = 0.0
	_toggle_button.anchor_top = 0.0
	_toggle_button.anchor_right = 0.0
	_toggle_button.anchor_bottom = 0.0
	_toggle_button.offset_top = 8.0
	_toggle_button.offset_bottom = 44.0

	var btn_style = StyleBoxFlat.new()
	btn_style.bg_color = Color(0.15, 0.15, 0.2, 0.85)
	btn_style.corner_radius_top_right = 6
	btn_style.corner_radius_bottom_right = 6
	btn_style.content_margin_left = 4
	btn_style.content_margin_right = 4
	_toggle_button.add_theme_stylebox_override("normal", btn_style)

	var btn_hover = btn_style.duplicate() as StyleBoxFlat
	btn_hover.bg_color = Color(0.25, 0.25, 0.35, 0.9)
	_toggle_button.add_theme_stylebox_override("hover", btn_hover)

	var btn_pressed = btn_style.duplicate() as StyleBoxFlat
	btn_pressed.bg_color = Color(0.1, 0.1, 0.15, 0.9)
	_toggle_button.add_theme_stylebox_override("pressed", btn_pressed)

	_toggle_button.add_theme_color_override("font_color", Color(1, 1, 1))
	_toggle_button.add_theme_font_size_override("font_size", 18)
	_toggle_button.pressed.connect(_on_toggle)
	add_child(_toggle_button)
	_position_toggle_button()


func _on_toggle() -> void:
	_panel_visible = !_panel_visible

	if _slide_tween != null:
		_slide_tween.kill()

	_slide_tween = create_tween()
	_slide_tween.set_ease(Tween.EASE_OUT)
	_slide_tween.set_trans(Tween.TRANS_CUBIC)

	if _panel_visible:
		if _upload_panel != null:
			_upload_panel.visible = true
		_slide_tween.tween_property(self, "offset_left", 0.0, SLIDE_DURATION)
		_toggle_button.text = "<"
	else:
		_slide_tween.tween_property(self, "offset_left", -_panel_width, SLIDE_DURATION)
		_slide_tween.tween_callback(_hide_upload_panel_if_collapsed)
		_toggle_button.text = ">"


func _sync_layout(force_position: bool = true) -> void:
	var target_width := _calculate_panel_width()
	if not force_position and is_equal_approx(target_width, _panel_width):
		return
	_panel_width = target_width

	offset_right = _panel_width + BUTTON_WIDTH + 4.0
	if _upload_panel != null:
		_upload_panel.offset_left = 0.0
		_upload_panel.offset_top = 0.0
		_upload_panel.offset_right = _panel_width
		_upload_panel.offset_bottom = 0.0
		_upload_panel.visible = _panel_visible
	_position_toggle_button()

	if force_position:
		if not _panel_visible:
			offset_left = -_panel_width
		else:
			offset_left = 0.0


func _calculate_panel_width() -> float:
	var content_width := MIN_PANEL_WIDTH
	if _upload_panel != null:
		content_width = maxf(content_width, _upload_panel.get_combined_minimum_size().x)
		content_width = maxf(content_width, _measure_upload_content_width())

	var viewport_width := get_viewport_rect().size.x
	var max_width := MAX_PANEL_WIDTH
	if viewport_width > 0.0:
		max_width = minf(MAX_PANEL_WIDTH, maxf(MIN_PANEL_WIDTH, viewport_width - BUTTON_WIDTH - 16.0))
	return clampf(content_width, MIN_PANEL_WIDTH, max_width)


func _measure_upload_content_width() -> float:
	if _upload_panel == null or not is_inside_tree():
		return 0.0

	var panel_left := _upload_panel.global_position.x
	var content_right := _upload_panel.global_position.x + _upload_panel.get_combined_minimum_size().x
	content_right = _measure_control_tree_right(_upload_panel, content_right)
	return maxf(0.0, ceilf(content_right - panel_left))


func _measure_control_tree_right(control: Control, current_right: float) -> float:
	var rect := control.get_global_rect()
	var max_right := maxf(current_right, rect.position.x + rect.size.x)

	for child: Node in control.get_children():
		if child is Control:
			max_right = maxf(max_right, _measure_control_tree_right(child as Control, max_right))
	return max_right


func _position_toggle_button() -> void:
	if _toggle_button == null:
		return
	_toggle_button.offset_left = _panel_width + 2.0
	_toggle_button.offset_right = _panel_width + 2.0 + BUTTON_WIDTH


func _hide_upload_panel_if_collapsed() -> void:
	if not _panel_visible and _upload_panel != null:
		_upload_panel.visible = false
