# Blender script: builds a realistic open, empty cardboard box, bakes its
# cardboard textures, and exports it as a GLB for the site's 3D viewer.
# Usage: blender --background --factory-startup --python boxmodel.py -- <out.glb>
import bpy, bmesh, math, sys, random
from mathutils import Vector, Matrix

OUT = sys.argv[sys.argv.index('--') + 1:][0]
random.seed(4)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = 4

W, D, H = 1.2, 0.9, 0.82      # width (x), depth (y), height (z)
T = 0.012                     # board thickness
CENTER = Vector((0, 0, H / 2))

def mark_inside(bm, layer, center=CENTER):
    for f in bm.faces:
        c = f.calc_center_median()
        to_c = center - c
        to_c.z = 0 if abs(c.z - H / 2) < H / 2 - 1e-4 or c.z > H else to_c.z
        f[layer] = 1.0 if f.normal.dot(to_c) > 0 else 0.0

def new_bm():
    bm = bmesh.new()
    return bm, bm.faces.layers.float.new('inside')

parts = []

# --- walls + floor (open top) ---
bm, lay = new_bm()
bmesh.ops.create_cube(bm, size=1.0)
bmesh.ops.scale(bm, vec=(W, D, H), verts=bm.verts)
bmesh.ops.translate(bm, vec=(0, 0, H / 2), verts=bm.verts)
bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.z > 0.9], context='FACES')
bmesh.ops.solidify(bm, geom=bm.faces[:], thickness=T)
bm.normal_update()
for f in bm.faces:
    c = f.calc_center_median()
    if f.normal.z < -0.9 and c.z < 0.001:
        f[lay] = 0.0                                  # underside
    elif f.normal.z > 0.9:
        f[lay] = 1.0 if c.z < 0.1 else 0.0            # floor top = inside; wall rims = outside
    else:
        f[lay] = 1.0 if f.normal.dot(Vector((-c.x, -c.y, 0))) > 0 else 0.0
parts.append(bm)

# --- flaps, built upright, then swung open about their hinge ---
def flap(axis, sign, length, open_deg, droop):
    bm, lay = new_bm()
    if axis == 'y':   # front/back flaps span x
        y = sign * D / 2
        vs = [(-W / 2, y, H), (W / 2, y, H), (W / 2, y, H + length), (-W / 2, y, H + length)]
    else:             # side flaps span y
        x = sign * W / 2
        vs = [(x, -D / 2 + .004, H), (x, D / 2 - .004, H), (x, D / 2 - .004, H + length), (x, -D / 2 + .004, H + length)]
    bv = [bm.verts.new(v) for v in vs]
    f = bm.faces.new(bv); bm.normal_update()
    out = Vector((0, sign, 0)) if axis == 'y' else Vector((sign, 0, 0))
    if f.normal.dot(out) < 0:
        f.normal_flip()
    bmesh.ops.solidify(bm, geom=bm.faces[:], thickness=T)
    bm.normal_update()
    for f in bm.faces:
        f[lay] = 1.0 if f.normal.dot(out) < -0.5 else 0.0
    # hinge along the top edge of the wall, swing outward
    ang = math.radians(open_deg + droop)
    if axis == 'y':
        R = Matrix.Rotation(sign * -ang, 4, 'X') if True else None
        R = Matrix.Rotation(ang if sign < 0 else -ang, 4, 'X')
        pivot = Vector((0, sign * D / 2, H))
    else:
        R = Matrix.Rotation(-ang if sign < 0 else ang, 4, 'Y')
        pivot = Vector((sign * W / 2, 0, H))
    M = Matrix.Translation(pivot) @ R @ Matrix.Translation(-pivot)
    bmesh.ops.transform(bm, matrix=M, verts=bm.verts)
    return bm

parts.append(flap('y', -1, D / 2, 112, random.uniform(-4, 4)))
parts.append(flap('y', 1, D / 2, 118, random.uniform(-4, 4)))
parts.append(flap('x', -1, D / 2 * 0.95, 104, random.uniform(-4, 4)))
parts.append(flap('x', 1, D / 2 * 0.95, 100, random.uniform(-4, 4)))

me = bpy.data.meshes.new('Box')
bm_all = bmesh.new()
for b in parts:
    tmp = bpy.data.meshes.new('tmp'); b.to_mesh(tmp); b.free()
    bm_all.from_mesh(tmp); bpy.data.meshes.remove(tmp)
bm_all.to_mesh(me); bm_all.free()
box = bpy.data.objects.new('Box', me); scene.collection.objects.link(box)

# --- UVs ---
bpy.context.view_layer.objects.active = box; box.select_set(True)
bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.01)
bpy.ops.object.mode_set(mode='OBJECT')

# --- bake material: kraft board with fibres and faint corrugation ---
RES = 1024
img_col = bpy.data.images.new('box_color', RES, RES)
img_nrm = bpy.data.images.new('box_normal', RES, RES); img_nrm.colorspace_settings.name = 'Non-Color'
m = bpy.data.materials.new('Cardboard'); m.use_nodes = True
nt = m.node_tree; n = nt.nodes; l = nt.links
p = n['Principled BSDF']; p.inputs['Roughness'].default_value = 0.88
tc = n.new('ShaderNodeTexCoord')
fib = n.new('ShaderNodeTexNoise'); fib.inputs['Scale'].default_value = 140; fib.inputs['Detail'].default_value = 8
mp = n.new('ShaderNodeMapping'); mp.inputs['Scale'].default_value = (1, 6, 1); l.new(tc.outputs['Object'], mp.inputs['Vector'])
l.new(mp.outputs['Vector'], fib.inputs['Vector'])
blot = n.new('ShaderNodeTexNoise'); blot.inputs['Scale'].default_value = 4; blot.inputs['Detail'].default_value = 3
l.new(tc.outputs['Object'], blot.inputs['Vector'])
wave = n.new('ShaderNodeTexWave'); wave.inputs['Scale'].default_value = 28; wave.inputs['Distortion'].default_value = 0.4
l.new(tc.outputs['Object'], wave.inputs['Vector'])
attr = n.new('ShaderNodeAttribute'); attr.attribute_name = 'inside'
try:
    attr.attribute_type = 'GEOMETRY'
except Exception:
    pass

def ramp(c0, c1):
    r = n.new('ShaderNodeValToRGB')
    r.color_ramp.elements[0].color = (*c0, 1); r.color_ramp.elements[1].color = (*c1, 1)
    return r

outer = ramp((0.40, 0.21, 0.08), (0.56, 0.32, 0.13)); l.new(fib.outputs['Fac'], outer.inputs['Fac'])
inner = ramp((0.30, 0.17, 0.07), (0.42, 0.25, 0.11)); l.new(fib.outputs['Fac'], inner.inputs['Fac'])
mix_io = n.new('ShaderNodeMix'); mix_io.data_type = 'RGBA'
l.new(attr.outputs['Fac'], mix_io.inputs['Factor']); l.new(outer.outputs['Color'], mix_io.inputs['A']); l.new(inner.outputs['Color'], mix_io.inputs['B'])
# blotchy tone variation
dark = n.new('ShaderNodeMix'); dark.data_type = 'RGBA'; dark.blend_type = 'MULTIPLY'
l.new(mix_io.outputs['Result'], dark.inputs['A'])
br = ramp((0.82, 0.82, 0.82), (1, 1, 1)); l.new(blot.outputs['Fac'], br.inputs['Fac'])
l.new(br.outputs['Color'], dark.inputs['B']); dark.inputs['Factor'].default_value = 1.0
l.new(dark.outputs['Result'], p.inputs['Base Color'])
# bump: fibres + corrugation ridges
bump_mix = n.new('ShaderNodeMath'); bump_mix.operation = 'ADD'
w2 = n.new('ShaderNodeMath'); w2.operation = 'MULTIPLY'; w2.inputs[1].default_value = 0.35
l.new(wave.outputs['Fac'], w2.inputs[0]); l.new(fib.outputs['Fac'], bump_mix.inputs[0]); l.new(w2.outputs[0], bump_mix.inputs[1])
bump = n.new('ShaderNodeBump'); bump.inputs['Strength'].default_value = 0.18; bump.inputs['Distance'].default_value = 0.02
l.new(bump_mix.outputs[0], bump.inputs['Height']); l.new(bump.outputs['Normal'], p.inputs['Normal'])
tex = n.new('ShaderNodeTexImage')
box.data.materials.append(m)

def bake(kind, img, **kw):
    tex.image = img; n.active = tex; tex.select = True
    bpy.ops.object.bake(type=kind, margin=8, use_clear=True, **kw)

scene.render.bake.use_pass_direct = False
scene.render.bake.use_pass_indirect = False
scene.render.bake.use_pass_color = True
bake('DIFFUSE', img_col)
bake('NORMAL', img_nrm)

# --- final material for export: baked textures ---
fm = bpy.data.materials.new('CardboardBaked'); fm.use_nodes = True
fn = fm.node_tree.nodes; fl = fm.node_tree.links
fp = fn['Principled BSDF']; fp.inputs['Roughness'].default_value = 0.9
tcol = fn.new('ShaderNodeTexImage'); tcol.image = img_col
tnrm = fn.new('ShaderNodeTexImage'); tnrm.image = img_nrm
nm = fn.new('ShaderNodeNormalMap'); nm.inputs['Strength'].default_value = 1.0
fl.new(tcol.outputs['Color'], fp.inputs['Base Color'])
fl.new(tnrm.outputs['Color'], nm.inputs['Color']); fl.new(nm.outputs['Normal'], fp.inputs['Normal'])
box.data.materials.clear(); box.data.materials.append(fm)

# --- printing: stamp, side label ---
ink = bpy.data.materials.new('Ink'); ink.use_nodes = True
ink.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.03, 0.015, 0.01, 1)
ink.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value = 0.95
paper = bpy.data.materials.new('Label'); paper.use_nodes = True
paper.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.82, 0.8, 0.74, 1)
paper.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value = 0.7
pink = bpy.data.materials.new('Pink'); pink.use_nodes = True
pink.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (1.0, 0.03, 0.3, 1)

def text_mesh(body, size, loc, rot, mat, space=1.0):
    cu = bpy.data.curves.new('t', 'FONT'); cu.body = body; cu.size = size
    cu.align_x = 'CENTER'; cu.align_y = 'CENTER'; cu.space_character = space
    o = bpy.data.objects.new('t', cu); scene.collection.objects.link(o)
    o.location = loc; o.rotation_euler = rot
    bpy.context.view_layer.objects.active = o
    for ob in scene.objects:
        ob.select_set(ob is o)
    bpy.ops.object.convert(target='MESH')
    o = bpy.context.active_object
    o.data.materials.clear(); o.data.materials.append(mat)
    return o

eps = 0.0015
front = (math.radians(90), 0, 0)
text_mesh('NOTHING', 0.2, (0, -D / 2 - T - eps, H * 0.56), front, ink, 1.12)
text_mesh('CONTENTS: 0', 0.065, (0, -D / 2 - T - eps, H * 0.4), front, ink, 1.3)
text_mesh('NOTHING', 0.2, (0, D / 2 + T + eps, H * 0.56), (math.radians(90), 0, math.radians(180)), ink, 1.12)
# shipping label on the right side
bpy.ops.mesh.primitive_plane_add(size=1)
lab = bpy.context.active_object; lab.scale = (0.42, 0.26, 1)
lab.location = (W / 2 + T + eps, 0.05, H * 0.5); lab.rotation_euler = (math.radians(90), 0, math.radians(90))
lab.data.materials.append(paper)
side = (math.radians(90), 0, math.radians(90))
text_mesh('FRAGILE', 0.06, (W / 2 + T + 2 * eps, 0.05, H * 0.5 + 0.075), side, pink, 1.2)
text_mesh('CONTAINS NOTHING', 0.032, (W / 2 + T + 2 * eps, 0.05, H * 0.5 + 0.005), side, ink, 1.1)
text_mesh('HANDLE WITH INDIFFERENCE', 0.022, (W / 2 + T + 2 * eps, 0.05, H * 0.5 - 0.05), side, ink, 1.05)
text_mesh('THIS SIDE UP', 0.05, (-W / 2 - T - eps, 0, H * 0.72), (math.radians(90), 0, math.radians(-90)), ink, 1.2)

# --- export: centre the box on its middle so it spins about its own centre ---
for ob in scene.objects:
    ob.select_set(ob.type == 'MESH')
bpy.context.view_layer.objects.active = box
bpy.ops.object.join()
box = bpy.context.active_object
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
for v in box.data.vertices:
    v.co.z -= H / 2
bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB', use_selection=True,
                          export_image_format='JPEG', export_jpeg_quality=82,
                          export_yup=True, export_apply=True)
open(OUT + '.done', 'w').write('ok')
