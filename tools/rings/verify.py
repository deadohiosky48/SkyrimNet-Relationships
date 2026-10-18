"""Re-import each built NIF and check what a game needs from it."""
import sys

import bpy

if 'io_scene_nifly' not in bpy.context.preferences.addons:
    bpy.ops.preferences.addon_enable(module='io_scene_nifly')

for path in sys.argv[sys.argv.index('--') + 1:]:
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    bpy.ops.import_scene.pynifly(filepath=path, import_tris=False)
    print('=== VERIFY', path.replace('\\', '/').rsplit('/', 1)[-1])
    for o in bpy.data.objects:
        if o.type == 'MESH' and o.get('pynBlockName') == 'BSTriShape':
            me = o.data
            uv = me.uv_layers.active.data
            us = [d.uv.x for d in uv]
            vs = [d.uv.y for d in uv]
            mat = me.materials[0] if me.materials else None
            print('  SHAPE', o.name, 'tris', len(me.polygons), 'groups', [g.name for g in o.vertex_groups],
                  'uv u %.2f..%.2f v %.2f..%.2f' % (min(us), max(us), min(vs), max(vs)))
            if mat:
                print('  SHADER', {k: mat[k] for k in mat.keys() if k.startswith('BSShaderTextureSet') or k.startswith('BSLSP')})
        elif o.type == 'ARMATURE':
            print('  BONES', [b.name for b in o.data.bones])
        elif o.rigid_body:
            print('  COLLISION', o.name, tuple(round(d, 3) for d in o.dimensions))
