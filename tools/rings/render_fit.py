"""Render a worn ring on a hands mesh, close up, from two sides."""
import math
import sys

import bpy
from mathutils import Vector

if 'io_scene_nifly' not in bpy.context.preferences.addons:
    bpy.ops.preferences.addon_enable(module='io_scene_nifly')
hands, ring_path, out_prefix = sys.argv[sys.argv.index('--') + 1:]

for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)


def import_nif(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.pynifly(filepath=path, import_collisions=False, import_tris=False)
    return [o for o in bpy.data.objects if o not in before]


hand_objs = [o for o in import_nif(hands) if o.type == 'MESH']
ring_objs = [o for o in import_nif(ring_path) if o.type == 'MESH']

for o in hand_objs:
    o.color = (0.85, 0.7, 0.6, 1)
for o in ring_objs:
    o.color = (0.95, 0.75, 0.15, 1)

pts = [r.matrix_world @ Vector(c) for r in ring_objs for c in r.bound_box]
ctr = sum(pts, Vector()) / len(pts)
print('FIT ring centre', tuple(round(v, 3) for v in ctr))

scene = bpy.context.scene
scene.render.engine = 'BLENDER_WORKBENCH'
scene.display.shading.color_type = 'OBJECT'
scene.display.shading.light = 'STUDIO'
scene.render.resolution_x = 700
scene.render.resolution_y = 700
scene.world = bpy.data.worlds.new('w') if not scene.world else scene.world

cam_data = bpy.data.cameras.new('cam')
cam_data.lens = 85
cam = bpy.data.objects.new('cam', cam_data)
scene.collection.objects.link(cam)
scene.camera = cam

views = {'back': Vector((-1.0, 0.2, 0.6)), 'side': Vector((0.1, 1.0, 0.3)), 'end': Vector((-0.3, 0.3, -1.0)),
         # The back of the left hand, straight on: Finger30.L's +y in the skeleton.
         'top': Vector((-0.957, -0.079, -0.28))}
for name, d in views.items():
    cam.location = ctr + d.normalized() * 14
    direction = ctr - cam.location
    cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    scene.render.filepath = f'{out_prefix}_{name}.png'
    bpy.ops.render.render(write_still=True)
    print('FIT wrote', scene.render.filepath)
