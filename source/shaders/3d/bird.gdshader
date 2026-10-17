shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, specular_disabled;

// Flapping birds drawn from one MultiMesh (source/match/environment/Wildlife.gd). The mesh is
// built with its wings along X, COLOR.r = 1 on wing vertices (0 on the body) and COLOR.g
// rising towards the wing tips, which are darker. Per instance:
// INSTANCE_CUSTOM.x flap phase (radians), .y flap strength (0 glide .. 1 full beat),
// .z fold (0 spread .. 1 folded on the ground), .w wing beats per second.

uniform vec3 body_color : source_color = vec3(0.22, 0.2, 0.19);
uniform vec3 wing_tip_color : source_color = vec3(0.12, 0.11, 0.1);
uniform float flap_angle = 0.75; // radians at full strength
uniform float glide_dihedral = 0.12; // wings held slightly up while gliding

void vertex()
{
  float wing = COLOR.r;
  if (wing > 0.0)
  {
    float side = sign(VERTEX.x);
    float span = abs(VERTEX.x);
    float reach = span;
    float beat = sin(TIME * INSTANCE_CUSTOM.w * 6.2831853 + INSTANCE_CUSTOM.x);
    float angle = glide_dihedral + beat * flap_angle * INSTANCE_CUSTOM.y;
    float fold = INSTANCE_CUSTOM.z;
    // folded: the wing lies along the body, tucked over the back
    reach *= mix(1.0, 0.22, fold);
    angle = mix(angle, 0.35, fold);
    VERTEX.z += fold * span * 0.6;
    VERTEX.x = side * reach * cos(angle);
    VERTEX.y += reach * sin(angle);
  }
}

void fragment()
{
  ALBEDO = mix(body_color, wing_tip_color, COLOR.g);
  ROUGHNESS = 0.9;
}
