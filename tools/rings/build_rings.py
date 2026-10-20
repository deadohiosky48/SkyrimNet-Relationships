"""Build Relationships' engagement ring and wedding ring NIFs from the resource.

Run in the background with the ring's .blend open (never saved):
  blender -b --factory-startup --disable-autoexec "Ring Gold.blend" --python build_rings.py -- <vanilla dir> <out dir> <metal>

Makes, per ring: <Name><Metal>.nif (worn, skinned to the left ring finger)
and <Name><Metal>GO.nif (on the ground, with collision), using vanilla's ring
shader and texture sheet (textures\\armor\\amuletsandrings\\Genericrings.dds).
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

if 'io_scene_nifly' not in bpy.context.preferences.addons:
    bpy.ops.preferences.addon_enable(module='io_scene_nifly')

VANILLA, OUT, METAL, SKELETONS = sys.argv[sys.argv.index('--') + 1:]
os.makedirs(OUT, exist_ok=True)

# In the finger bone's frame the finger runs along local z and the back of the
# hand is +y (measured from vanilla's worn ring, GoldRingDiamond_1.nif).
# Vanilla's hole (0.72) is for vanilla's thin male fingers; measured on the
# installed hands at the ring's place, the female ring finger is about 0.8 to
# 0.92 from its centre and the male about 0.86 to 0.98, so the hole is 0.97 and
# centred where both fingers are.
INNER_RADIUS = 0.97       # the hole the finger passes through
BAND_CENTRE = (0.03, -0.22)  # x, y off the bone's axis
ALONG_FINGER = 1.75       # the engagement ring's centre, from the knuckle
FINGER_BONE = 'NPC Finger30.L'  # left ring finger, first segment
TRIS = {'EngagementRing': 1600, 'WeddingRing': 2800, 'WeddingBand': 1200}

# THE METAL'S COLOUR IS A VERTEX COLOUR. Vanilla's gold and silver rings share
# one grey sheet; GoldRingDiamondGO.nif tints its metal vertices (1.0, 0.8,
# 0.51) and its stone (0.97, 0.97, 0.97). Without them the ring is the sheet's
# grey (seen in game, 2026-10-18).
METAL_COLOURS = {'Gold': (1.0, 0.8, 0.51, 1.0)}
STONE_COLOUR = (0.97, 0.97, 0.97, 1.0)

# Where the two materials go on vanilla's ring sheet, in Blender UV space
# (v up): the band strip on the left, the cut stone bottom right.
METAL_UV = (0.15, 0.10, 0.40, 0.90)          # u0, v0, u1, v1
STONE_UV = (0.80, 0.21, 0.20)                # centre u, centre v, size


def log(*a):
    print('RINGS', *a)


# ---------------------------------------------------------------- the meshes
src = bpy.data.objects['Ring']
dg = bpy.context.evaluated_depsgraph_get()
full = bpy.data.meshes.new_from_object(src.evaluated_get(dg))
stone_index = [m.name for m in full.materials].index('Diamond')


def islands(bm):
    seen, out = set(), []
    for f in bm.faces:
        if f in seen:
            continue
        stack, group = [f], []
        seen.add(f)
        while stack:
            cur = stack.pop()
            group.append(cur)
            for e in cur.edges:
                for nb in e.link_faces:
                    if nb not in seen:
                        seen.add(nb)
                        stack.append(nb)
        out.append(group)
    return out


def build_mesh(name, part):
    """part 'engagement': the engagement ring alone; 'both': with its band;
    'band': the band alone (2.5: the wedding band the player is given at the
    wedding), left where it sits beside the engagement ring, nearer the hand.
    Centred, scaled to fit, reduced, and mapped onto vanilla's sheet. Returns
    (mesh, scale, z of the engagement ring's centre after scaling)."""
    bm = bmesh.new()
    bm.from_mesh(full)
    bm.faces.ensure_lookup_table()
    parts = islands(bm)
    # The engagement ring is the piece whose stone stands proud of the band.
    engagement = max(parts, key=lambda g: max(v.co.y for f in g for v in f.verts))
    band = [g for g in parts if g is not engagement]
    eng_verts = {v for f in engagement for v in f.verts}
    ez = sum(v.co.z for v in eng_verts) / len(eng_verts)
    inner = min(math.hypot(v.co.x, v.co.y) for f in engagement for v in f.verts if f.material_index != stone_index)
    if part == 'engagement':
        bmesh.ops.delete(bm, geom=[f for g in band for f in g], context='FACES')
    elif part == 'band':
        bmesh.ops.delete(bm, geom=list(engagement), context='FACES')
    scale = INNER_RADIUS / inner
    bmesh.ops.scale(bm, vec=(scale, scale, scale), verts=bm.verts)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in full.materials:
        me.materials.append(m)
    log(name, 'inner radius', round(inner, 3), 'scale', round(scale, 4), 'tris before', len(me.polygons))
    return me, scale, ez * scale


def reduce(obj, target):
    tris = len(obj.data.polygons)
    if tris <= target:
        return
    mod = obj.modifiers.new('reduce', 'DECIMATE')
    mod.ratio = target / tris
    mod.use_collapse_triangulate = True
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=mod.name)


def remap_uv(me):
    """Our UVs (0..1, made for the resource's own textures) squeezed into the
    band strip and the stone of vanilla's sheet."""
    uv = me.uv_layers.active.data
    u0, v0, u1, v1 = METAL_UV
    cu, cv, size = STONE_UV
    for poly in me.polygons:
        for li in poly.loop_indices:
            u, v = uv[li].uv
            u, v = u % 1.0, v % 1.0
            if poly.material_index == stone_index:
                uv[li].uv = (cu + size * (u - 0.5), cv + size * (v - 0.5))
            else:
                uv[li].uv = (u0 + (u1 - u0) * u, v0 + (v1 - v0) * v)


def paint(me):
    """Vertex colours as vanilla's: the metal's tint, the stones white. A
    vertex takes the colour of most of the faces around it."""
    metal = METAL_COLOURS[METAL]
    attr = me.color_attributes.get('VERTEX_COLOR') or me.color_attributes.new('VERTEX_COLOR', 'FLOAT_COLOR', 'POINT')
    votes = [[0, 0] for _ in me.vertices]
    for poly in me.polygons:
        k = 1 if poly.material_index == stone_index else 0
        for vi in poly.vertices:
            votes[vi][k] += 1
    for i, (m, s) in enumerate(votes):
        attr.data[i].color = STONE_COLOUR if s > m else metal


# --------------------------------------------------------------- templates
def import_nif(path, **options):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.pynifly(filepath=path, **options)
    return [o for o in bpy.data.objects if o not in before]


for o in list(bpy.data.objects):
    if o.name in ('Camera', 'Light'):
        bpy.data.objects.remove(o, do_unlink=True)
src.hide_set(True)


def select_only(objs, active):
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active


def remove(objs):
    for o in objs:
        try:
            bpy.data.objects.remove(o, do_unlink=True)
        except ReferenceError:
            pass   # already gone


results = []
for item, part in (('EngagementRing', 'engagement'), ('WeddingRing', 'both'), ('WeddingBand', 'band')):
    me, scale, eng_z = build_mesh(item, part)

    # ---------------- on the ground: vanilla's GO nif with our mesh in it
    go = import_nif(os.path.join(VANILLA, 'goldringdiamondgo.nif'))
    shape = next(o for o in go if o.type == 'MESH' and o.get('pynBlockName') == 'BSTriShape')
    box = next(o for o in go if o.rigid_body)
    mat = shape.data.materials[0]
    ground = me.copy()
    ground.name = item + METAL + 'GO'
    # Centre it on the origin the way vanilla's lies: flat, axis up.
    cx = sum(v.co.x for v in ground.vertices) / len(ground.vertices)
    cy = sum(v.co.y for v in ground.vertices) / len(ground.vertices)
    cz = sum(v.co.z for v in ground.vertices) / len(ground.vertices)
    ground.transform(Matrix.Translation((-cx, -cy, -cz)))
    old = shape.data
    shape.data = ground
    bpy.data.meshes.remove(old)
    reduce(shape, TRIS[item])
    remap_uv(shape.data)
    paint(shape.data)
    shape.data.materials.clear()
    shape.data.materials.append(mat)
    for p in shape.data.polygons:
        p.material_index = 0
    # The box: fitted to the new ring, a little inside it, as vanilla's is.
    xs = [v.co.x for v in shape.data.vertices]
    ys = [v.co.y for v in shape.data.vertices]
    zs = [v.co.z for v in shape.data.vertices]
    half = Vector(((max(xs) - min(xs)) * 0.41, (max(ys) - min(ys)) * 0.35, (max(zs) - min(zs)) * 0.19))
    # Corners keep their side of the OLD box's centre (vanilla's sits off the
    # origin) and move to the same side of the ring's own centre.
    old_c = sum((v.co for v in box.data.vertices), Vector()) / len(box.data.vertices)
    new_c = Vector(((max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2, (max(zs) + min(zs)) / 2))
    for v in box.data.vertices:
        d = v.co - old_c
        v.co = new_c + Vector((math.copysign(half.x, d.x), math.copysign(half.y, d.y), math.copysign(half.z, d.z)))
    box.data.update()   # face centres and normals, which PyNifly measures the box by
    root = next(o for o in go if o.get('pynRoot'))
    select_only(go, root)
    path = os.path.join(OUT, item + METAL + 'GO.nif')
    bpy.ops.export_scene.pynifly(filepath=path, target_game='SKYRIMSE')
    results.append((path, len(shape.data.polygons), tuple(round(d, 3) for d in shape.dimensions)))
    remove(go)

    # ---------------- worn: skinned to the left ring finger
    # Vanilla's worn ring for its material; a whole skeleton for the bone, since
    # a worn nif carries only the bones it uses (vanilla's: the right index).
    worn_tpl = import_nif(os.path.join(VANILLA, 'goldringdiamond_1.nif'))
    vshape = next(o for o in worn_tpl if o.type == 'MESH' and o.vertex_groups)
    wmat = vshape.data.materials[0]
    skel = import_nif(os.path.join(SKELETONS, 'skeleton_female.nif'), import_collisions=False)
    worn_tpl += skel
    arm = next(o for o in skel if o.type == 'ARMATURE')
    if FINGER_BONE not in arm.data.bones:
        raise SystemExit('the template armature has no ' + FINGER_BONE)
    worn = me.copy()
    worn.name = item + METAL
    # Ring frame -> bone frame: our axis (z) along the finger, but the band
    # toward the knuckle, so our +z is the finger's -z; our stone (+y) to the
    # back of the hand (+y); x follows for a proper rotation.
    to_bone = Matrix(((-1, 0, 0, 0), (0, 1, 0, 0), (0, 0, -1, 0), (0, 0, 0, 1)))
    place = Matrix.Translation((BAND_CENTRE[0], BAND_CENTRE[1], ALONG_FINGER + eng_z))
    bone = arm.data.bones[FINGER_BONE]
    worn.transform(arm.matrix_world @ bone.matrix_local @ place @ to_bone)
    obj = bpy.data.objects.new(item + METAL, worn)
    bpy.context.scene.collection.objects.link(obj)
    reduce(obj, TRIS[item])
    remap_uv(obj.data)
    paint(obj.data)
    obj.data.materials.clear()
    obj.data.materials.append(wmat)
    for p in obj.data.polygons:
        p.material_index = 0
    for prop in ('pynBlockName', 'pynVertexDesc', 'PYN_GAME'):
        if prop in vshape:
            obj[prop] = vshape[prop]
    obj.parent = arm
    mod = obj.modifiers.new('Armature', 'ARMATURE')
    mod.object = arm
    for gname in (FINGER_BONE, 'SBP_36_RING'):
        g = obj.vertex_groups.new(name=gname)
        g.add(list(range(len(worn.vertices))), 1.0, 'REPLACE')
    remove([vshape])
    select_only([obj], obj)
    path = os.path.join(OUT, item + METAL + '.nif')
    bpy.ops.export_scene.pynifly(filepath=path, target_game='SKYRIMSE')
    results.append((path, len(obj.data.polygons), tuple(round(d, 3) for d in obj.dimensions)))
    remove(worn_tpl + [obj])

for path, tris, dims in results:
    log('WROTE', os.path.basename(path), 'tris', tris, 'dims', dims, 'bytes', os.path.getsize(path))
