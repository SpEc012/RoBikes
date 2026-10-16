# Convert the Meshy-rigged rider (rider_rigged.glb) into a Roblox R15 skinned character.
# Usage: python3 to_r15.py <in.glb> <out_dir>
import bpy, bmesh, sys, os
from mathutils import Vector
src, out = sys.argv[-2], sys.argv[-1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
for o in list(bpy.data.objects):
    if o.type == 'MESH' and o.name.startswith('Icosphere'):
        bpy.data.objects.remove(o)
for a in list(bpy.data.actions):
    bpy.data.actions.remove(a)
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
me = next(o for o in bpy.data.objects if o.type == 'MESH')
arm.animation_data_clear()

# freeze transforms (Meshy armature carries a 0.01 scale)
mw = me.matrix_world.copy()
me.parent = None
me.matrix_world = mw
for o in (arm, me):
    bpy.ops.object.select_all(action='DESELECT')
    o.select_set(True); bpy.context.view_layer.objects.active = o
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# Meshy bone -> R15 part. Bones not listed as keys of RENAME get their weights merged into MERGE[bone].
RENAME = {
    'Hips': 'LowerTorso', 'Spine02': 'UpperTorso', 'neck': 'Head',
    'LeftArm': 'LeftUpperArm', 'LeftForeArm': 'LeftLowerArm', 'LeftHand': 'LeftHand',
    'RightArm': 'RightUpperArm', 'RightForeArm': 'RightLowerArm', 'RightHand': 'RightHand',
    'LeftUpLeg': 'LeftUpperLeg', 'LeftLeg': 'LeftLowerLeg', 'LeftFoot': 'LeftFoot',
    'RightUpLeg': 'RightUpperLeg', 'RightLeg': 'RightLowerLeg', 'RightFoot': 'RightFoot',
}
MERGE = {
    'Spine01': 'Spine02', 'Spine': 'Spine02', 'LeftShoulder': 'Spine02', 'RightShoulder': 'Spine02',
    'Head': 'neck', 'head_end': 'neck', 'headfront': 'neck',
    'LeftToeBase': 'LeftFoot', 'RightToeBase': 'RightFoot',
}
PARENT = {
    'LowerTorso': 'HumanoidRootNode', 'UpperTorso': 'LowerTorso', 'Head': 'UpperTorso',
    'LeftUpperArm': 'UpperTorso', 'LeftLowerArm': 'LeftUpperArm', 'LeftHand': 'LeftLowerArm',
    'RightUpperArm': 'UpperTorso', 'RightLowerArm': 'RightUpperArm', 'RightHand': 'RightLowerArm',
    'LeftUpperLeg': 'LowerTorso', 'LeftLowerLeg': 'LeftUpperLeg', 'LeftFoot': 'LeftLowerLeg',
    'RightUpperLeg': 'LowerTorso', 'RightLowerLeg': 'RightUpperLeg', 'RightFoot': 'RightLowerLeg',
}

# --- weights: merge, then rename groups
vg = me.vertex_groups
for srcb, dst in MERGE.items():
    s, d = vg.get(srcb), vg.get(dst)
    if s is None: continue
    for v in me.data.vertices:
        for g in v.groups:
            if g.group == s.index and g.weight > 0:
                d.add([v.index], g.weight, 'ADD')
    vg.remove(s)
for old, new in RENAME.items():
    if vg.get(old): vg[old].name = new

# --- skeleton
heads = {b.name: (arm.matrix_world @ b.head_local).copy() for b in arm.data.bones}
toe = {'LeftFoot': heads['LeftToeBase'], 'RightFoot': heads['RightToeBase']}
bpy.ops.object.select_all(action='DESELECT')
arm.select_set(True); bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode='EDIT')
eb = arm.data.edit_bones
for name in MERGE:
    if name in eb: eb.remove(eb[name])
for old, new in RENAME.items():
    eb[old].name = new
root = eb.new('Root'); root.head = Vector((0, 0, 0)); root.tail = Vector((0, 0, 0.2))
hrn = eb.new('HumanoidRootNode'); hrn.head = eb['LowerTorso'].head.copy(); hrn.tail = hrn.head + Vector((0, 0, 0.2))
hrn.parent = root
for child, par in PARENT.items():
    eb[child].use_connect = False
    eb[child].parent = eb[par]
# tails: point each bone at its chain child so rolls/axes are sane in Studio
chain = {'LowerTorso': 'UpperTorso', 'UpperTorso': 'Head',
         'LeftUpperArm': 'LeftLowerArm', 'LeftLowerArm': 'LeftHand',
         'RightUpperArm': 'RightLowerArm', 'RightLowerArm': 'RightHand',
         'LeftUpperLeg': 'LeftLowerLeg', 'LeftLowerLeg': 'LeftFoot',
         'RightUpperLeg': 'RightLowerLeg', 'RightLowerLeg': 'RightFoot'}
for b, c in chain.items():
    eb[b].tail = eb[c].head.copy()
eb['Head'].tail = eb['Head'].head + Vector((0, 0, 0.30))
for s in ('Left', 'Right'):
    h = eb[s + 'Hand']; d = (h.head - eb[s + 'LowerArm'].head).normalized()
    h.tail = h.head + d * 0.09
    f = eb[s + 'Foot']; f.tail = toe[s + 'Foot']
for b in eb: b.roll = 0
bpy.ops.object.mode_set(mode='OBJECT')
arm.name = 'Rider'; arm.data.name = 'Rider'

# --- clean weights: max 4 influences, normalised, nothing on Root / HumanoidRootNode
bpy.ops.object.select_all(action='DESELECT')
me.select_set(True); bpy.context.view_layer.objects.active = me
bpy.ops.object.vertex_group_clean(group_select_mode='ALL', limit=0.01)
bpy.ops.object.vertex_group_limit_total(group_select_mode='ALL', limit=4)
bpy.ops.object.vertex_group_normalize_all(group_select_mode='ALL', lock_active=False)

# --- split into the 15 R15 body-part meshes by each face's dominant bone
parts = list(PARENT.keys())
idx = {vg[p].index: p for p in parts if vg.get(p)}
bm = bmesh.new(); bm.from_mesh(me.data)
dl = bm.verts.layers.deform.active
owner = {}
for f in bm.faces:
    tot = {}
    for v in f.verts:
        for gi, w in v[dl].items():
            if gi in idx: tot[idx[gi]] = tot.get(idx[gi], 0) + w
    owner[f.index] = max(tot, key=tot.get) if tot else 'UpperTorso'
bm.free()
counts = {}
for p in parts:
    o = me.copy(); o.data = me.data.copy(); o.name = p + '_Geo'; o.data.name = p + '_Geo'
    bpy.context.collection.objects.link(o)
    bm = bmesh.new(); bm.from_mesh(o.data); bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if owner[f.index] != p], context='FACES')
    bm.to_mesh(o.data); counts[p] = len(bm.faces); bm.free()
    o.parent = arm
    o.modifiers[0].object = arm if o.modifiers else None
bpy.data.objects.remove(me)
for o in bpy.data.objects:
    if o.type == 'MESH':
        m = o.modifiers.get('Armature') or (o.modifiers[0] if o.modifiers else o.modifiers.new('Armature', 'ARMATURE'))
        m.object = arm
print('TRIS', counts, sum(counts.values()))

os.makedirs(out, exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out, 'rider_r15.blend'))
bpy.ops.object.select_all(action='SELECT')
bpy.ops.export_scene.fbx(filepath=os.path.join(out, 'rider_r15.fbx'), use_selection=False,
    object_types={'ARMATURE', 'MESH'}, add_leaf_bones=False, bake_anim=False,
    axis_forward='-Z', axis_up='Y', apply_unit_scale=True, apply_scale_options='FBX_SCALE_ALL',
    path_mode='COPY', embed_textures=True, mesh_smooth_type='FACE', use_armature_deform_only=False)
bpy.ops.export_scene.gltf(filepath=os.path.join(out, 'rider_r15.glb'), export_format='GLB', export_animations=False)
for b in arm.data.bones:
    print('BONE', b.name, b.parent.name if b.parent else '-', [round(x, 3) for x in b.head_local])
