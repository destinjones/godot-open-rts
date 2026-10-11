# Blender script: renders the NOTHING empty box.
# Usage: blender --background --factory-startup --python boxrender.py -- <mode> <out>
#   mode: gold | gold2 | blue  -> transparent PNG with Super Saiyan aura
#         spin                 -> 360° turntable MP4 on the site's background colour
import bpy, bmesh, math, random, sys
from mathutils import Vector

argv = sys.argv[sys.argv.index('--') + 1:]
MODE, OUT = argv[0], argv[1]
random.seed(7)

# ---------- scene ----------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
for eng in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE'):
    try:
        scene.render.engine = eng
        break
    except TypeError:
        pass
try:
    scene.view_settings.view_transform = 'Standard'
except TypeError:
    pass
for attr, val in (('use_raytracing', True), ('taa_render_samples', 48), ('use_shadows', True)):
    try:
        setattr(scene.eevee, attr, val)
    except Exception:
        pass

world = bpy.data.worlds.new('W')
scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes['Background']

def srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

# ---------- materials ----------
def mat_cardboard():
    m = bpy.data.materials.new('Cardboard'); m.use_nodes = True
    nt = m.node_tree; n = nt.nodes; l = nt.links
    p = n['Principled BSDF']
    p.inputs['Roughness'].default_value = 0.85
    noise = n.new('ShaderNodeTexNoise'); noise.inputs['Scale'].default_value = 18; noise.inputs['Detail'].default_value = 6
    ramp = n.new('ShaderNodeValToRGB')
    ramp.color_ramp.elements[0].color = (0.42, 0.21, 0.07, 1)
    ramp.color_ramp.elements[1].color = (0.62, 0.34, 0.12, 1)
    l.new(noise.outputs['Fac'], ramp.inputs['Fac'])
    l.new(ramp.outputs['Color'], p.inputs['Base Color'])
    return m

def mat_emit(name, color, strength):
    m = bpy.data.materials.new(name); m.use_nodes = True
    n = m.node_tree.nodes; n.clear()
    o = n.new('ShaderNodeOutputMaterial'); e = n.new('ShaderNodeEmission')
    e.inputs['Color'].default_value = (*color, 1); e.inputs['Strength'].default_value = strength
    m.node_tree.links.new(e.outputs[0], o.inputs[0])
    return m

def mat_ink():
    m = bpy.data.materials.new('Ink'); m.use_nodes = True
    p = m.node_tree.nodes['Principled BSDF']
    p.inputs['Base Color'].default_value = (0.09, 0.04, 0.015, 1)
    p.inputs['Roughness'].default_value = 0.9
    return m

def set_blended(m):
    for attr, val in (('surface_render_method', 'BLENDED'), ('blend_method', 'BLEND')):
        try:
            setattr(m, attr, val)
        except Exception:
            pass
    try:
        m.use_backface_culling = False
    except Exception:
        pass

def mat_aura(name, core, edge, height, seed, strength=5.0, alpha_gain=1.0):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; n = nt.nodes; l = nt.links; n.clear()
    out = n.new('ShaderNodeOutputMaterial')
    mix = n.new('ShaderNodeMixShader')
    tr = n.new('ShaderNodeBsdfTransparent')
    em = n.new('ShaderNodeEmission'); em.inputs['Strength'].default_value = strength
    tc = n.new('ShaderNodeTexCoord')
    sep = n.new('ShaderNodeSeparateXYZ'); l.new(tc.outputs['Object'], sep.inputs[0])
    # colour: hot core at the bottom, aura colour above
    zr = n.new('ShaderNodeMapRange'); zr.inputs['From Min'].default_value = 0.4; zr.inputs['From Max'].default_value = height * 0.7
    l.new(sep.outputs['Z'], zr.inputs['Value'])
    cr = n.new('ShaderNodeValToRGB')
    cr.color_ramp.elements[0].color = (*core, 1); cr.color_ramp.elements[1].color = (*edge, 1)
    l.new(zr.outputs['Result'], cr.inputs['Fac']); l.new(cr.outputs['Color'], em.inputs['Color'])
    # alpha: rim (facing) x vertical fade x flame streaks
    lw = n.new('ShaderNodeLayerWeight'); lw.inputs['Blend'].default_value = 0.45
    rim = n.new('ShaderNodeMath'); rim.operation = 'POWER'; rim.inputs[1].default_value = 1.7
    l.new(lw.outputs['Facing'], rim.inputs[0])
    fade = n.new('ShaderNodeMapRange'); fade.inputs['From Min'].default_value = height * 0.25; fade.inputs['From Max'].default_value = height
    fade.inputs['To Min'].default_value = 1.0; fade.inputs['To Max'].default_value = 0.0
    l.new(sep.outputs['Z'], fade.inputs['Value'])
    mp = n.new('ShaderNodeMapping'); mp.inputs['Scale'].default_value = (5.0, 5.0, 0.9)
    mp.inputs['Location'].default_value = (seed, seed * 0.7, 0)
    l.new(tc.outputs['Object'], mp.inputs['Vector'])
    nz = n.new('ShaderNodeTexNoise'); nz.inputs['Scale'].default_value = 2.5; nz.inputs['Detail'].default_value = 4
    l.new(mp.outputs['Vector'], nz.inputs['Vector'])
    st = n.new('ShaderNodeMapRange'); st.inputs['From Min'].default_value = 0.35; st.inputs['From Max'].default_value = 0.7
    st.inputs['To Min'].default_value = 0.35; st.inputs['To Max'].default_value = 1.0
    l.new(nz.outputs['Fac'], st.inputs['Value'])
    a1 = n.new('ShaderNodeMath'); a1.operation = 'MULTIPLY'; l.new(rim.outputs[0], a1.inputs[0]); l.new(fade.outputs['Result'], a1.inputs[1])
    a2 = n.new('ShaderNodeMath'); a2.operation = 'MULTIPLY'; l.new(a1.outputs[0], a2.inputs[0]); l.new(st.outputs['Result'], a2.inputs[1])
    bot = n.new('ShaderNodeMapRange'); bot.inputs['From Min'].default_value = 0.1; bot.inputs['From Max'].default_value = 0.9
    l.new(sep.outputs['Z'], bot.inputs['Value'])
    a25 = n.new('ShaderNodeMath'); a25.operation = 'MULTIPLY'; l.new(a2.outputs[0], a25.inputs[0]); l.new(bot.outputs['Result'], a25.inputs[1])
    a3 = n.new('ShaderNodeMath'); a3.operation = 'MULTIPLY'; a3.use_clamp = True; a3.inputs[1].default_value = alpha_gain
    l.new(a25.outputs[0], a3.inputs[0])
    l.new(a3.outputs[0], mix.inputs['Fac'])
    l.new(tr.outputs[0], mix.inputs[1]); l.new(em.outputs[0], mix.inputs[2])
    l.new(mix.outputs[0], out.inputs[0])
    set_blended(m)
    return m

CARD = mat_cardboard()

# ---------- box ----------
root = bpy.data.objects.new('BoxRoot', None); scene.collection.objects.link(root)

def link(obj):
    scene.collection.objects.link(obj); obj.parent = root; return obj

me = bpy.data.meshes.new('Box'); bm = bmesh.new()
bmesh.ops.create_cube(bm, size=1.0)
bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, 0.5))
top = [f for f in bm.faces if f.normal.z > 0.9]
bmesh.ops.delete(bm, geom=top, context='FACES')
bm.to_mesh(me); bm.free()
box = link(bpy.data.objects.new('Box', me)); box.data.materials.append(CARD)
sol = box.modifiers.new('Solid', 'SOLIDIFY'); sol.thickness = 0.025; sol.offset = -1
bev = box.modifiers.new('Bevel', 'BEVEL'); bev.width = 0.006; bev.segments = 2

def flap(name, loc, length, axis, angle, width):
    m = bpy.data.meshes.new(name); bm = bmesh.new()
    if axis == 'X':
        vs = [(-width / 2, 0, 0), (width / 2, 0, 0), (width / 2, 0, length), (-width / 2, 0, length)]
    else:
        vs = [(0, -width / 2, 0), (0, width / 2, 0), (0, width / 2, length), (0, -width / 2, length)]
    bv = [bm.verts.new(v) for v in vs]; bm.faces.new(bv); bm.to_mesh(m); bm.free()
    o = link(bpy.data.objects.new(name, m)); o.data.materials.append(CARD)
    o.location = loc
    o.rotation_euler = (angle, 0, 0) if axis == 'X' else (0, angle, 0)
    s = o.modifiers.new('Solid', 'SOLIDIFY'); s.thickness = 0.02
    return o

flap('FlapFront', (0, -0.5, 1), 0.48, 'X', math.radians(104), 0.99)
flap('FlapBack', (0, 0.5, 1), 0.48, 'X', math.radians(-112), 0.99)
flap('FlapLeft', (-0.5, 0, 1), 0.46, 'Y', math.radians(-108), 0.99)
flap('FlapRight', (0.5, 0, 1), 0.46, 'Y', math.radians(108), 0.99)

# "NOTHING" stamped on the front
cu = bpy.data.curves.new('Stamp', 'FONT'); cu.body = 'NOTHING'; cu.size = 0.17; cu.align_x = 'CENTER'; cu.align_y = 'CENTER'
cu.space_character = 1.15; cu.extrude = 0.002
txt = link(bpy.data.objects.new('Stamp', cu)); txt.data.materials.append(mat_ink())
txt.location = (0, -0.503, 0.42); txt.rotation_euler = (math.radians(90), 0, 0)
cu2 = bpy.data.curves.new('Sub', 'FONT'); cu2.body = 'CONTENTS: 0'; cu2.size = 0.065; cu2.align_x = 'CENTER'; cu2.align_y = 'CENTER'; cu2.space_character = 1.3
t2 = link(bpy.data.objects.new('Sub', cu2)); t2.data.materials.append(mat_ink())
t2.location = (0, -0.503, 0.25); t2.rotation_euler = (math.radians(90), 0, 0)

# ---------- lights ----------
def light(kind, loc, rot, energy, color=(1, 1, 1), size=None):
    ld = bpy.data.lights.new(kind, kind); ld.energy = energy; ld.color = color
    if size is not None:
        if kind == 'SUN':
            ld.angle = size
        else:
            ld.shadow_soft_size = size
    o = bpy.data.objects.new(kind, ld); scene.collection.objects.link(o)
    o.location = loc; o.rotation_euler = [math.radians(a) for a in rot]
    return o

light('SUN', (0, 0, 5), (38, 0, -30), 3.2, (1.0, 0.96, 0.9), math.radians(6))
light('AREA', (3, -3, 2.5), (60, 0, 45), 120, (1.0, 0.85, 0.75), 2.0)

# ---------- camera ----------
cam_d = bpy.data.cameras.new('Cam'); cam_d.lens = 50
cam = bpy.data.objects.new('Cam', cam_d); scene.collection.objects.link(cam); scene.camera = cam
target = bpy.data.objects.new('Target', None); scene.collection.objects.link(target)
tt = cam.constraints.new('TRACK_TO'); tt.target = target; tt.track_axis = 'TRACK_NEGATIVE_Z'; tt.up_axis = 'UP_Y'

def place_cam(dist, elev, azim, tz):
    e, a = math.radians(elev), math.radians(azim)
    target.location = (0, 0, tz)
    cam.location = (dist * math.cos(e) * math.sin(a), -dist * math.cos(e) * math.cos(a), tz + dist * math.sin(e))

# ---------- aura ----------
def aura_mesh(name, r0, hbase, hspike, cols=44, rows=14, seed=0):
    rnd = random.Random(seed)
    heights = []
    for i in range(cols):
        if i % 2 == 0:
            heights.append(hbase + hspike * (0.55 + 0.45 * rnd.random()))
        else:
            heights.append(hbase + hspike * 0.15 * rnd.random())
    m = bpy.data.meshes.new(name); bm = bmesh.new(); grid = []
    for i in range(cols):
        ang = 2 * math.pi * i / cols; col = []
        for r in range(rows + 1):
            t = r / rows
            rad = r0 * (1 + 0.22 * math.sin(math.pi * t)) * (1 - 0.6 * t ** 1.6)
            col.append(bm.verts.new((rad * math.cos(ang), rad * math.sin(ang), -0.05 + t * heights[i])))
        grid.append(col)
    for i in range(cols):
        a, b = grid[i], grid[(i + 1) % cols]
        for r in range(rows):
            bm.faces.new((a[r], b[r], b[r + 1], a[r + 1]))
    bm.to_mesh(m); bm.free()
    o = bpy.data.objects.new(name, m); scene.collection.objects.link(o)
    for p in o.data.polygons:
        p.use_smooth = True
    return o

def bolt(name, start, steps, mat, seed):
    rnd = random.Random(seed)
    cu = bpy.data.curves.new(name, 'CURVE'); cu.dimensions = '3D'; cu.bevel_depth = 0.012
    sp = cu.splines.new('POLY'); sp.points.add(len(steps))
    p = Vector(start); sp.points[0].co = (*p, 1)
    for k, st in enumerate(steps):
        p = p + Vector(st) + Vector((rnd.uniform(-.05, .05), rnd.uniform(-.05, .05), 0))
        sp.points[k + 1].co = (*p, 1)
    o = bpy.data.objects.new(name, cu); scene.collection.objects.link(o); o.data.materials.append(mat)
    return o

def sparks(mat, n=14, seed=3):
    rnd = random.Random(seed)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=8, ring_count=6, radius=1)
    base = bpy.context.active_object; base.data.materials.append(mat)
    base.scale = (0.018, 0.018, 0.07)
    ang0 = 0
    for k in range(n):
        o = base if k == 0 else base.copy()
        if k:
            scene.collection.objects.link(o)
        ang = rnd.uniform(0, 2 * math.pi); rad = rnd.uniform(0.75, 1.15)
        o.location = (rad * math.cos(ang), rad * math.sin(ang), rnd.uniform(0.3, 2.3))
        o.scale = (0.012, 0.012, rnd.uniform(0.035, 0.07))

if MODE in ('gold', 'gold2', 'blue', 'plain'):
    if MODE == 'blue':
        core, edge, sp = (0.85, 0.97, 1.0), (0.05, 0.35, 1.0), (0.7, 0.95, 1.0)
    else:
        core, edge, sp = (1.0, 0.95, 0.6), (1.0, 0.55, 0.02), (1.0, 0.95, 0.6)
    if MODE != 'plain':
        a1 = aura_mesh('AuraOuter', 1.05, 2.0, 1.3, seed=1)
        a1.data.materials.append(mat_aura('AuraOuterM', core, edge, 3.3, 0.0, 2.0, 1.0))
        a2 = aura_mesh('AuraInner', 0.85, 1.6, 0.9, cols=36, seed=2)
        a2.rotation_euler.z = math.radians(5)
        a2.data.materials.append(mat_aura('AuraInnerM', core, edge, 2.5, 3.0, 1.3, 0.7))
        sparks(mat_emit('Spark', sp, 3.0))
        if MODE in ('gold2', 'blue'):
            zap = mat_emit('Zap', (0.75, 0.9, 1.0), 14.0)
            bolt('Bolt1', (-0.95, -0.2, 2.2), [(0.12, 0, -0.25), (-0.15, 0, -0.2), (0.14, 0, -0.22), (-0.1, 0, -0.2), (0.1, 0, -0.18)], zap, 1)
            bolt('Bolt2', (0.9, -0.35, 1.9), [(-0.12, 0, -0.22), (0.15, 0, -0.2), (-0.13, 0, -0.24), (0.1, 0, -0.2)], zap, 2)
            bolt('Bolt3', (0.25, 0.6, 2.6), [(0.1, 0, -0.2), (-0.12, 0, -0.22), (0.12, 0, -0.18)], zap, 3)
    scene.render.film_transparent = True
    bg.inputs['Color'].default_value = (0.02, 0.01, 0.04, 1); bg.inputs['Strength'].default_value = 1.0
    place_cam(6.4, 26, -32, 1.15)
    scene.render.resolution_x, scene.render.resolution_y = 700, 820
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.filepath = OUT
    bpy.ops.render.render(write_still=True)

elif MODE in ('spin', 'frames'):
    # Neon ring under the box, on the site's #0d0327 background
    bpy.ops.mesh.primitive_torus_add(major_radius=1.05, minor_radius=0.01, location=(0, 0, 0.0))
    ring = bpy.context.active_object; ring.data.materials.append(mat_emit('Ring', (0.0, 0.85, 1.0), 6.0))
    bpy.ops.mesh.primitive_torus_add(major_radius=0.97, minor_radius=0.007, location=(0, 0, 0.0))
    ring2 = bpy.context.active_object; ring2.data.materials.append(mat_emit('Ring2', (1.0, 0.05, 0.35), 4.0))
    bgc = [srgb_to_lin(c / 255) for c in (13, 3, 39)]
    bg.inputs['Color'].default_value = (*bgc, 1); bg.inputs['Strength'].default_value = 1.0
    scene.render.film_transparent = False
    place_cam(3.9, 30, 0, 0.45)
    NF = 288 if MODE == 'spin' else 72
    scene.frame_start, scene.frame_end = 1, NF   # spin: 12 s at 24 fps; frames: one still every 5 degrees
    scene.render.fps = 24
    root.rotation_euler.z = 0; root.keyframe_insert('rotation_euler', index=2, frame=1)
    root.rotation_euler.z = 2 * math.pi; root.keyframe_insert('rotation_euler', index=2, frame=NF + 1)
    try:
        for fc in root.animation_data.action.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = 'LINEAR'
    except Exception:
        # Blender 5 layered actions
        for layer in root.animation_data.action.layers:
            for strip in layer.strips:
                for cb in strip.channelbags:
                    for fc in cb.fcurves:
                        for kp in fc.keyframe_points:
                            kp.interpolation = 'LINEAR'
    scene.render.resolution_x = scene.render.resolution_y = 720
    s = scene.render.image_settings
    if MODE == 'frames':
        scene.render.resolution_x = scene.render.resolution_y = 480
        s.file_format = 'PNG'; s.color_mode = 'RGB'
        scene.render.filepath = OUT + '/f_'
        bpy.ops.render.render(animation=True)
        open(OUT + '.done', 'w').write('ok')
        raise SystemExit
    try:
        s.media_type = 'VIDEO'
    except Exception:
        pass
    s.file_format = 'FFMPEG'
    scene.render.ffmpeg.format = 'MPEG4'
    scene.render.ffmpeg.codec = 'H264'
    scene.render.ffmpeg.constant_rate_factor = 'HIGH'
    scene.render.ffmpeg.gopsize = 24
    scene.render.ffmpeg.audio_codec = 'NONE'
    scene.render.filepath = OUT
    bpy.ops.render.render(animation=True)

open(OUT + '.done', 'w').write('ok')
