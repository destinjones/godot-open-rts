"""Makes an AI-generated GLB (Higgsfield: GPT Image 2.5 concept, then Tripo H3.1 image-to-3D)
play-ready for Ironbound.

The concept images paint every team-colour surface flat bright cobalt blue. This script:
  * joins the meshes, turns the model so its front faces Blender +Y (Godot -Z), stands it on
    z = 0 centred on its footprint and scales its longest side to --length metres;
  * moves the faces whose texture is that blue into a "TeamColor" material with the albedo
    the game swaps for the player's colour (Unit.MATERIAL_ALBEDO_TO_REPLACE), and greys the
    blue texels left in the texture so seams do not show blue;
  * only faces that face up (normal z above --team-up) take team colour, so hull and turret
    sides stay in the model's own paint (docs/art-direction.md: top-facing surfaces only);
  * keeps the base colour and normal textures (resized to --tex pixels, JPEG), drops the ORM
    map and makes the material matte, as in the Grounded look (--no-normal drops the normal
    map too);
  * decimates down to --max-tris when over;
  * with --turret Z, cuts the faces above Z metres (the hull roof) into a separate "Turret"
    object with its origin on the turret ring, so TurretAim.gd can traverse it; faces in
    front of --turret-front (metres along +Y) stay on the hull unless they are within
    --barrel-width of the centre line (the gun); the rest is "Hull"; --barrel-scale
    thickens the gun;
  * --team-smooth N fills holes in, and drops specks from, the team-colour panels (N passes);
  * --saturation pulls dusty generated paint back toward its hue so it does not sink into
    the sand;
  * with --rotors, adds spinning "RotorMain" and "RotorTail" blades (see RotorSpin.gd) at the
    rotor hub and the tail, for helicopters generated without blades.

  python3 tools/blender/clean_generated.py -- --in raw.glb --out model.glb --yaw 90 \
      --length 3.2 [--rotors] [--turret 0.55 --turret-front 0.3] [--render previews/dir]
"""

import math
import os
import sys

import bpy  # noqa: I001 (bpy must load before bmesh)
import bmesh
import numpy as np
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

TEAM_COLOR_SRGB = (0.99, 0.81, 0.48)


def _args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = {"yaw": 0.0, "length": 0.0, "tex": 1024, "max_tris": 9000, "rotors": False,
            "render": None, "blue": 0.16, "team_up": 0.5, "normal": True, "turret": None,
            "turret_front": 1e9, "barrel_width": 0.06, "team_smooth": 0,
            "saturation": 1.0, "barrel_scale": 1.0}
    i = 0
    while i < len(argv):
        key = argv[i].lstrip("-").replace("-", "_")
        if key in ("rotors", "no_normal"):
            opts[key.replace("no_", "")] = key == "rotors"
            i += 1
            continue
        value = argv[i + 1]
        if key in ("yaw", "length", "blue", "team_up", "turret", "turret_front", "barrel_width",
                   "saturation", "barrel_scale"):
            value = float(value)
        elif key in ("tex", "max_tris", "team_smooth"):
            value = int(value)
        opts[key] = value
        i += 2
    return opts


def _srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _import(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(path))
    meshes = [ob for ob in bpy.context.scene.objects if ob.type == "MESH"]
    for ob in bpy.context.scene.objects:
        ob.select_set(ob in meshes)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.parent = None
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for other in list(bpy.context.scene.objects):
        if other != ob:
            bpy.data.objects.remove(other)
    ob.name = "Model"
    return ob


def _place(ob, yaw, length):
    ob.data.transform(Matrix.Rotation(math.radians(yaw), 4, "Z"))
    co = np.empty(len(ob.data.vertices) * 3)
    ob.data.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    lo, hi = co.min(axis=0), co.max(axis=0)
    centre = Vector(((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, lo[2]))
    ob.data.transform(Matrix.Translation(-centre))
    if length > 0:
        side = max(hi[0] - lo[0], hi[1] - lo[1])
        ob.data.transform(Matrix.Scale(length / side, 4))
    ob.data.update()


def _base_image(ob):
    mat = ob.data.materials[0]
    for node in mat.node_tree.nodes:
        if node.type == "BSDF_PRINCIPLED":
            link = node.inputs["Base Color"].links
            if link:
                return link[0].from_node.image
    raise SystemExit("no base colour texture")


def _blue_mask(pixels, threshold):
    """pixels: (h, w, 4) floats in sRGB; True where the texel is the team-colour blue"""
    r, g, b = pixels[..., 0], pixels[..., 1], pixels[..., 2]
    return (b - np.maximum(r, g) > threshold) & (b > 0.3)


def _face_neighbours(mesh):
    """faces sharing a corner position (glTF imports split vertices along UV seams, so
    shared vertex indices would miss neighbours across a seam)"""
    by_pos = {}
    for poly in mesh.polygons:
        for vi in poly.vertices:
            key = tuple(round(c, 4) for c in mesh.vertices[vi].co)
            by_pos.setdefault(key, set()).add(poly.index)
    neighbours = [set() for _ in mesh.polygons]
    for faces in by_pos.values():
        for f in faces:
            neighbours[f] |= faces
    for f, n in enumerate(neighbours):
        n.discard(f)
    return neighbours


def _smooth_team(mesh, team, team_up, passes):
    """fills the olive holes the concept's dirt leaves in a team-colour panel and drops
    stray specks, so the panels read as clean shapes at play zoom"""
    neighbours = _face_neighbours(mesh)
    up = {p.index for p in mesh.polygons if p.normal.z >= team_up}
    team = set(team)
    for _ in range(passes):
        changed = set(team)
        for f in up:
            near = [n for n in neighbours[f] if n in up]
            if len(near) < 3:
                continue
            share = sum(n in team for n in near) / len(near)
            if f not in team and share >= 0.5:
                changed.add(f)
            elif f in team and share < 0.2:
                changed.discard(f)
        team = changed
    return sorted(team)


def _saturate(image, amount):
    """the generated paint is dusty brown and sinks into the sand; pulls it back to olive"""
    if amount == 1.0:
        return
    w, h = image.size
    px = np.empty(w * h * 4, dtype=np.float32)
    image.pixels.foreach_get(px)
    px = px.reshape(h, w, 4)
    lum = (0.3 * px[..., 0] + 0.59 * px[..., 1] + 0.11 * px[..., 2])[..., None]
    px[..., :3] = np.clip(lum + (px[..., :3] - lum) * amount, 0.0, 1.0)
    image.pixels.foreach_set(px.ravel())
    image.update()


def _split_team_colour(ob, image, threshold, team_up, smooth):
    w, h = image.size
    px = np.empty(w * h * 4, dtype=np.float32)
    image.pixels.foreach_get(px)
    px = px.reshape(h, w, 4)
    mask = _blue_mask(px, threshold)

    mesh = ob.data
    uv = np.empty(len(mesh.loops) * 2)
    mesh.uv_layers.active.data.foreach_get("uv", uv)
    uv = uv.reshape(-1, 2)

    def sample(u, v):
        x = np.clip((u % 1.0) * w, 0, w - 1).astype(int)
        y = np.clip((v % 1.0) * h, 0, h - 1).astype(int)
        return mask[y, x]

    team_faces = []
    for poly in mesh.polygons:
        if poly.normal.z < team_up:
            continue
        loops = list(poly.loop_indices)
        pts = uv[loops]
        samples = [pts.mean(axis=0)] + [(p * 2 + pts.mean(axis=0)) / 3 for p in pts]
        votes = sum(bool(sample(s[0], s[1])) for s in samples)
        if votes * 2 > len(samples):
            team_faces.append(poly.index)
    if smooth:
        team_faces = _smooth_team(mesh, team_faces, team_up, smooth)

    team = bpy.data.materials.new("TeamColor")
    team.use_nodes = True
    bsdf = team.node_tree.nodes["Principled BSDF"]
    lin = [_srgb_to_linear(c) for c in TEAM_COLOR_SRGB]
    bsdf.inputs["Base Color"].default_value = (*lin, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.6
    bsdf.inputs["Metallic"].default_value = 0.0
    team.diffuse_color = (*lin, 1.0)
    mesh.materials.append(team)
    for i in team_faces:
        mesh.polygons[i].material_index = 1

    # grey out the blue texels so the edges of the split faces do not show blue
    lum = (0.3 * px[..., 0] + 0.59 * px[..., 1] + 0.11 * px[..., 2]) * 0.9
    for c in range(3):
        px[..., c] = np.where(mask, lum, px[..., c])
    image.pixels.foreach_set(px.ravel())
    image.update()
    return len(team_faces), len(mesh.polygons)


def _normal_image(mat):
    for node in mat.node_tree.nodes:
        if node.type == "NORMAL_MAP" and node.inputs["Color"].links:
            return node.inputs["Color"].links[0].from_node.image
    return None


def _flatten_material(ob, image, tex, keep_normal):
    """base colour (and normal) only, matte, resized; named "Textured" so GameData does not
    treat it as the vertex-coloured "Body" of the hand-built models"""
    mat = ob.data.materials[0]
    mat.name = "Textured"
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    normal = _normal_image(mat) if keep_normal else None
    bsdf = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")
    unlink = ("Metallic", "Roughness") if normal is not None else ("Metallic", "Roughness", "Normal")
    for name in unlink:
        for link in list(bsdf.inputs[name].links):
            links.remove(link)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 0.85
    for node in list(nodes):
        if node.type == "TEX_IMAGE" and node.image not in (image, normal):
            nodes.remove(node)
        elif node.type in ("SEPRGB", "SEPARATE_COLOR"):
            nodes.remove(node)
        elif node.type == "NORMAL_MAP" and normal is None:
            nodes.remove(node)
    for img, name in ((image, "Color"), (normal, "Normal")):
        if img is None:
            continue
        if max(img.size) > tex:
            img.scale(tex, tex)
        img.file_format = "JPEG"
        img.name = name  # Godot extracts it beside the GLB as <model>_<name>.jpg
    for m in ob.data.materials:
        m.use_backface_culling = True
    return normal is not None


def _decimate(ob, max_tris):
    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    if tris <= max_tris:
        return tris
    mod = ob.modifiers.new("Decimate", "DECIMATE")
    mod.ratio = max_tris / tris
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.modifier_apply(modifier=mod.name)
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def _split_turret(ob, above, front, barrel_width, barrel_scale):
    """moves the turret faces into their own "Turret" object pivoting on the turret ring;
    what is left becomes "Hull" """
    mesh = ob.data
    picked = []
    body = []
    for poly in mesh.polygons:
        c = poly.center
        if c.z <= above:
            continue
        if c.y > front and abs(c.x) > barrel_width:
            continue
        picked.append(poly.index)
        if abs(c.x) > barrel_width:
            body.append(c.copy())
    if not body:
        raise SystemExit("--turret: no faces above %.2f m" % above)
    ys = [c.y for c in body]
    pivot = Vector((0.0, (min(ys) + max(ys)) / 2, above))
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bm.faces.ensure_lookup_table()
    chosen = set(picked)
    hull_bm = bm.copy()
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.index not in chosen], context="FACES")
    hull_bm.faces.ensure_lookup_table()
    bmesh.ops.delete(hull_bm, geom=[f for f in hull_bm.faces if f.index in chosen],
                     context="FACES")
    turret_mesh = bpy.data.meshes.new("Turret")
    bm.to_mesh(turret_mesh)
    bm.free()
    hull_bm.to_mesh(mesh)
    hull_bm.free()
    for m in mesh.materials:
        turret_mesh.materials.append(m)
    if barrel_scale != 1.0:  # a thin generated gun vanishes at play zoom; thicken it
        gun = [v for v in turret_mesh.vertices if v.co.y > front and abs(v.co.x) <= barrel_width]
        if gun:
            axis_z = float(np.median([v.co.z for v in gun]))
            for v in gun:
                v.co.x *= barrel_scale
                v.co.z = axis_z + (v.co.z - axis_z) * barrel_scale
    turret_mesh.transform(Matrix.Translation(-pivot))
    turret = bpy.data.objects.new("Turret", turret_mesh)
    turret.location = pivot
    bpy.context.scene.collection.objects.link(turret)
    ob.name = "Hull"
    return turret, len(turret_mesh.polygons), pivot


def _blade_object(name, length, chord, count, axis, hub, material):
    """`count` thin blades around `axis` ("Z" spins flat like a main rotor, "X" like a tail
    rotor), with the object's origin at the hub"""
    bm = bmesh.new()
    for k in range(count):
        a = 2 * math.pi * k / count
        geom = bmesh.ops.create_cube(bm, size=1.0)["verts"]
        bmesh.ops.scale(bm, verts=geom, vec=(length, chord, chord * 0.12))
        bmesh.ops.translate(bm, verts=geom, vec=(length / 2, 0, 0))
        bmesh.ops.rotate(bm, verts=geom, cent=(0, 0, 0), matrix=Matrix.Rotation(a, 3, "Z"))
    hub_geom = bmesh.ops.create_cone(bm, cap_ends=True, segments=8, radius1=chord * 0.9,
                                     radius2=chord * 0.9, depth=chord * 0.5)["verts"]
    if axis == "X":
        bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0),
                         matrix=Matrix.Rotation(math.radians(90), 3, "Y"))
    del hub_geom
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(material)
    ob = bpy.data.objects.new(name, mesh)
    ob.location = hub
    bpy.context.scene.collection.objects.link(ob)
    return ob


def _add_rotors(ob):
    co = np.empty(len(ob.data.vertices) * 3)
    ob.data.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    length = co[:, 1].max() - co[:, 1].min()
    # main hub: the highest vertices in the middle third of the fuselage
    mid = co[np.abs(co[:, 1] - np.median(co[:, 1])) < length / 4]
    top = mid[mid[:, 2] > mid[:, 2].max() - length * 0.03]
    hub = Vector((0.0, float(top[:, 1].mean()), float(mid[:, 2].max()) + length * 0.01))
    # tail: the rear-most vertices; the tail rotor sits on the left side of the fin
    rear = co[co[:, 1] < co[:, 1].min() + length * 0.08]
    tail = Vector((float(rear[:, 0].min()) - length * 0.01, float(rear[:, 1].mean()),
                   float(rear[:, 2].mean())))
    blade = bpy.data.materials.new("Rotor")
    blade.use_nodes = True
    blade.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (
        0.035, 0.035, 0.03, 1.0)
    blade.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.7
    blade.use_backface_culling = False
    main = _blade_object("RotorMain", length * 0.52, length * 0.045, 4, "Z", hub, blade)
    tail_rotor = _blade_object("RotorTail", length * 0.11, length * 0.025, 2, "X", tail, blade)
    for rotor in (main, tail_rotor):
        rotor.parent = ob
    return hub, tail


def _export(path):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=os.path.abspath(path), export_format="GLB",
                              use_selection=True, export_yup=True, export_animations=False,
                              export_image_format="JPEG", export_jpeg_quality=85)


def _render(out_dir, ob):
    import mesh_kit  # noqa: E402 (only for the preview renders)

    co = np.empty(len(ob.data.vertices) * 3)
    ob.data.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    size = float(max(co.max(axis=0) - co.min(axis=0)))
    height = float(co[:, 2].max())
    for m in ob.data.materials:  # show team colour as blue in the previews
        if m.name.startswith("TeamColor"):
            m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (
                0.05, 0.12, 0.6, 1.0)
    views = [
        ("three_quarter", 35, 30, size * 1.5, (800, 800)),
        ("side", 90, 0, size * 1.3, (800, 800)),
        ("front", 0, 10, size * 1.3, (800, 800)),
        ("top", 0, 89, size * 1.3, (800, 800)),
    ]
    mesh_kit.render_views(out_dir, views, target=(0, 0, height / 2), samples=24)


def main():
    opts = _args()
    ob = _import(opts["in"])
    _place(ob, opts["yaw"], opts["length"])
    image = _base_image(ob)
    team, faces = _split_team_colour(ob, image, opts["blue"], opts["team_up"],
                                     opts["team_smooth"])
    _saturate(image, opts["saturation"])
    has_normal = _flatten_material(ob, image, opts["tex"], opts["normal"])
    tris = _decimate(ob, opts["max_tris"])
    if opts["rotors"]:
        _add_rotors(ob)
    co = np.empty(len(ob.data.vertices) * 3)
    ob.data.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    dims = co.max(axis=0) - co.min(axis=0)
    if opts["turret"] is not None:
        _, turret_faces, pivot = _split_turret(ob, opts["turret"], opts["turret_front"],
                                               opts["barrel_width"], opts["barrel_scale"])
        print("Turret: %d faces, pivot %.2f %.2f %.2f" % (turret_faces, *pivot))
    _export(opts["out"])
    print("%s: %d tris, %d of %d faces team colour, %.2f x %.2f x %.2f m (x, y, z), %s"
          % (opts["out"], tris, team, faces, dims[0], dims[1], dims[2],
             "base colour + normal" if has_normal else "base colour only"))
    if opts["render"]:
        _render(opts["render"], ob)


main()
