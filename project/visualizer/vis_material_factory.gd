class_name VisMaterialFactory
extends RefCounted


## Builds and returns the shared material dictionary keyed by component type.
static func build_materials() -> Dictionary:
	var materials: Dictionary = {}
	var defs := {
		"pmos":         Color(1.0, 0.2, 0.8),
		"nmos":         Color(0.2, 0.8, 1.0),
		"input_pin":    Color(0.2, 1.0, 0.3),
		"ipin":         Color(0.2, 1.0, 0.3),
		"output_pin":   Color(1.0, 0.2, 0.2),
		"opin":         Color(1.0, 0.2, 0.2),
		"label":        Color(1.0, 1.0, 0.3),
		"resistor":     Color(1.0, 0.6, 0.1),
		"capacitor":    Color(0.4, 0.6, 1.0),
		"poly_resistor":Color(1.0, 0.6, 0.1),
		"primitive":    Color(0.3, 0.8, 0.9),
		"unknown":      Color(0.5, 0.5, 0.5),
		"wire":         Color(0.9, 0.9, 0.9),
	}
	for type: String in defs:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = defs[type]
		mat.emission_enabled = true
		mat.emission = defs[type]
		mat.emission_energy_multiplier = 0.3
		materials[type] = mat
	return materials


## Creates and adds the floor plane to parent, returns the MeshInstance3D.
static func create_floor(parent: Node3D) -> MeshInstance3D:
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(50, 50)
	floor.mesh = plane
	floor.position = Vector3(0, -0.01, 0)

	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 bg_color    : source_color = vec4(0.035, 0.040, 0.055, 1.0);
uniform vec4 minor_color : source_color = vec4(0.075, 0.085, 0.115, 1.0);
uniform vec4 major_color : source_color = vec4(0.110, 0.125, 0.165, 1.0);
uniform float minor_spacing = 0.5;
uniform float major_every   = 4.0;
uniform float line_px       = 1.2;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz;
	float minor = minor_spacing;
	float major = minor * major_every;

	// Width of a grid line in world units, scaled by derivative for AA.
	vec2 deriv = fwidth(p);
	float px = max(deriv.x, deriv.y);

	vec2 gm = abs(fract(p / major + 0.5) - 0.5) * major;
	float major_line = min(gm.x, gm.y);

	vec2 gn = abs(fract(p / minor + 0.5) - 0.5) * minor;
	float minor_line = min(gn.x, gn.y);

	float t_major = 1.0 - smoothstep(0.0, px * line_px * 1.5, major_line);
	float t_minor = 1.0 - smoothstep(0.0, px * line_px,       minor_line);
	t_minor *= (1.0 - t_major);

	vec3 col = bg_color.rgb;
	col = mix(col, minor_color.rgb, t_minor);
	col = mix(col, major_color.rgb, t_major);
	ALBEDO = col;
	ALPHA  = 1.0;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	floor.material_override = mat
	floor.name = "Floor"
	parent.add_child(floor)
	return floor


## Returns the material for type, falling back to "unknown".
static func get_material(materials: Dictionary, type: String) -> StandardMaterial3D:
	if materials.has(type):
		return materials[type]
	return materials["unknown"]


## Returns the Y offset for a component label based on its type.
static func get_label_height(type: String) -> float:
	match type:
		"pmos": return 0.08
		"nmos": return 0.08
		"resistor", "poly_resistor": return 0.08
		"label": return 0.04
		"ipin", "input_pin": return 0.06
		"opin", "output_pin": return 0.06
		"primitive": return 0.10
		_: return 0.07
