extends Camera3D


@export var speed: float = 2.0
@export var zoom_speed: float = 2.0
@export var scroll_zoom_speed: float = 0.5
@export var mouse_sensitivity: float = 0.3
@export var min_height: float = 0.3
@export var max_height: float = 20.0
@export var bounds_limit: float = 15.0
@export var drag_sensitivity: float = 0.005


var rotation_x := 0.0   # pitch
var rotation_y := 0.0   # yaw
var _right_mouse_held := false
var _left_mouse_held := false


func _ready() -> void:
	rotation_x = rotation_degrees.x
	rotation_y = rotation_degrees.y


func _unhandled_input(event):
	# Track mouse buttons
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_left_mouse_held = event.pressed
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_right_mouse_held = event.pressed

		# Scroll wheel zoom — moves camera along its forward direction
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				var new_pos = position + -transform.basis.z * scroll_zoom_speed
				if new_pos.y >= min_height:
					position = new_pos
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				var new_pos = position + transform.basis.z * scroll_zoom_speed
				if new_pos.y <= max_height:
					position = new_pos

	if event is InputEventMouseMotion:
		# Left-click drag — pan camera along its local X and Y axes
		if _left_mouse_held:
			position -= transform.basis.x * event.relative.x * drag_sensitivity
			position += transform.basis.y * event.relative.y * drag_sensitivity

		# Right-click drag — rotate camera
		elif _right_mouse_held:
			rotation_y -= event.relative.x * mouse_sensitivity
			rotation_x -= event.relative.y * mouse_sensitivity
			rotation_x = clamp(rotation_x, -90, 90)
			rotation_degrees = Vector3(rotation_x, rotation_y, 0)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	var input_vector := Vector2.ZERO
	
	if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
		input_vector.y += 1
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
		input_vector.y -= 1
	if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
		input_vector.x -= 1
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
		input_vector.x += 1
	if Input.is_key_pressed(KEY_Q):
		position.z += zoom_speed * delta #zoom out
	if Input.is_key_pressed(KEY_E):
		position.z -= zoom_speed * delta #zoom in
	
	# Normalize to avoid faster diagonal movement
	if input_vector.length() > 0:
		input_vector = input_vector.normalized()
	
	# Move in X-Y plane
	position.x += input_vector.x * speed * delta
	position.y += input_vector.y * speed * delta

	# Clamp height between floor and max zoom-out
	position.y = clamp(position.y, min_height, max_height)

	# Clamp XZ position to keep camera within bounds
	position.x = clamp(position.x, -bounds_limit, bounds_limit)
	position.z = clamp(position.z, -bounds_limit, bounds_limit)
