"""The left ring finger's cross-section on a hands mesh, in its bone's frame."""
import math
import sys

import bpy
import numpy as np

if 'io_scene_nifly' not in bpy.context.preferences.addons:
    bpy.ops.preferences.addon_enable(module='io_scene_nifly')
hands = sys.argv[sys.argv.index('--') + 1]
bone_name = 'NPC Finger30.L'
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.import_scene.pynifly(filepath=hands, import_collisions=False, import_tris=False)
mesh = next(o for o in bpy.data.objects if o.type == 'MESH' and bone_name in o.vertex_groups)
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
bone = arm.data.bones[bone_name]
to_bone = (arm.matrix_world @ bone.matrix_local).inverted()
gi = mesh.vertex_groups[bone_name].index
pts = []
for v in mesh.data.vertices:
    w = next((g.weight for g in v.groups if g.group == gi), 0.0)
    if w > 0.5:
        pts.append(to_bone @ (mesh.matrix_world @ v.co))
P = np.array([[p.x, p.y, p.z] for p in pts])
print('FINGER verts', len(P), 'z (along finger) %.3f..%.3f' % (P[:, 2].min(), P[:, 2].max()))
for z in (0.6, 0.9, 1.2, 1.5, 1.8, 2.2):
    sl = P[np.abs(P[:, 2] - z) < 0.2]
    if len(sl) < 6:
        continue
    cx, cy = (sl[:, 0].min() + sl[:, 0].max()) / 2, (sl[:, 1].min() + sl[:, 1].max()) / 2
    r = np.hypot(sl[:, 0] - cx, sl[:, 1] - cy)
    print('SLICE z=%.1f n=%d centre=(%.3f, %.3f) half-width x=%.3f y=%.3f radius max=%.3f mean=%.3f' % (
        z, len(sl), cx, cy, (sl[:, 0].max() - sl[:, 0].min()) / 2, (sl[:, 1].max() - sl[:, 1].min()) / 2, r.max(), r.mean()))
