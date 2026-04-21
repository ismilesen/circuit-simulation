shader_type spatial;
render_mode cull_disabled, unshaded;

// Full length of the wire box in local space (= BoxMesh size.x). Set once per wire.
uniform float wire_length = 1.0;

// Base voltage color and steady emission energy for the whole wire.
uniform vec3  color_behind  : source_color = vec3(0.0, 0.0, 0.0);
uniform float energy_behind = 0.0;

// Kept for API compat — unused now that fill_fraction is always 1.
uniform vec3  color_ahead   : source_color = vec3(0.0, 0.0, 0.0);
uniform float energy_ahead  = 0.0;
uniform float fill_fraction : hint_range(0.0, 1.0) = 1.0;
uniform int   fill_from_p1  = 1;

// Traveling flow dot — moves from p1 (0.0) to p2 (1.0) continuously.
// flow_pos  : current normalized position of the dot center.
// flow_amt  : 0 = invisible (0 V net), 1 = full brightness (Vmax).
// flow_boost: extra emission multiplier at the dot center.
uniform float flow_pos   = 0.0;
uniform float flow_amt   = 0.0;
uniform float flow_boost = 2.0;

varying float wire_pos;

void vertex() {
	wire_pos = VERTEX.x / wire_length + 0.5;
}

void fragment() {
	vec3  col = color_behind;
	float ene = energy_behind;

	// Gaussian bright dot centered at flow_pos.
	// sigma^2 = 0.008 → FWHM ≈ 15 % of wire length, soft edges.
	float d    = wire_pos - flow_pos;
	float spot = exp(-(d * d) / 0.008);
	ene += flow_amt * spot * flow_boost * energy_behind;

	ALBEDO = vec3(0.06, 0.06, 0.06) + col * ene;
}
