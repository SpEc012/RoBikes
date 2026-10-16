# Split the Trellis bike mesh (bike_450.glb) into the parts that move, aligned to RoBikes' design frame.
# Usage: python3 bike_split.py <bike_450.glb> <out_dir> [preview]
# Design frame (metres): forward f, up u, side s (+ = rider's right); origin = ground under the rear axle at static sag.
import bpy, bmesh, sys, os, math, json
import numpy as np
from mathutils import Vector, Matrix
args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
src, out = args[0], args[1]
preview = len(args) > 2

# RoBikes geometry (RobikesConfig GEOM + BikeData tyres, 450xf): wheelbase 1.47, front R 0.335, rear R 0.325
WB, RF, RR = 1.47, 0.335, 0.325
PIVOT = (0.48, 0.42)  # swingarm pivot used by BikeRenderer

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
o = next(o for o in bpy.data.objects if o.type == 'MESH')
o.parent = None
bpy.context.view_layer.objects.active = o; o.select_set(True)
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
for e in [e for e in bpy.data.objects if e.type == 'EMPTY']:
    bpy.data.objects.remove(e)

V = np.array([v.co[:] for v in o.data.vertices])
x, y, z = V.T

def circle_fit(px, pz):
    A = np.c_[2 * px, 2 * pz, np.ones_like(px)]
    cx, cz, c = np.linalg.lstsq(A, px ** 2 + pz ** 2, rcond=None)[0]
    return cx, cz, math.sqrt(c + cx * cx + cz * cz)

def find_wheel(sel):
    m = sel & (np.abs(y) < 0.035) & (z < 0.0)
    cx, cz, r = circle_fit(x[m], z[m])
    for _ in range(4):
        ang = np.arctan2(z - cz, x - cx); d = np.hypot(x - cx, z - cz)
        mm = sel & (np.abs(y) < 0.05) & (d < r * 1.3)
        pts = []
        for a0 in np.linspace(-math.pi, math.pi, 72, endpoint=False):
            k = mm & (ang >= a0) & (ang < a0 + 2 * math.pi / 72)
            if k.any():
                pts.append(np.where(k)[0][np.argmax(d[k])])
        pts = np.array(pts); dd = np.hypot(x[pts] - cx, z[pts] - cz)
        keep = pts[np.abs(dd - np.median(dd)) < 0.02]
        cx, cz, r = circle_fit(x[keep], z[keep])
    return np.array([cx, cz]), r

# the generated bike faces -X (front wheel at -X), up +Z, its right side at +Y
cF, rF = find_wheel(x < -0.15)
cR, rR = find_wheel(x > 0.15)
# mesh side coords (forward, up) = (-x, z)
qF, qR = np.array([-cF[0], cF[1]]), np.array([-cR[0], cR[1]])
k = WB / np.linalg.norm(qF - qR)
theta = math.atan2(RF - RR, WB) - math.atan2(*(qF - qR)[::-1])
c, s_ = math.cos(theta), math.sin(theta)
Rot = np.array([[c, -s_], [s_, c]])
def to_design(P):  # P: (n,3) mesh -> (n,3) design (f,u,s)
    q = np.c_[-P[:, 0], P[:, 2]] - qR
    fu = (k * (Rot @ q.T)).T + np.array([0.0, RR])
    return np.c_[fu, P[:, 1] * k]
D = to_design(V)
axF, axR = np.array([WB, RF]), np.array([0.0, RR])
rFd, rRd = rF * k, rR * k
print('scale', k, 'pitch deg', math.degrees(theta), 'mesh wheel radii (m)', rFd, rRd)

# fork line: PCA of the fork-tube points beside the front wheel
f_, u_, s3 = D.T
d0 = np.array([-math.sin(math.radians(24)), math.cos(math.radians(24))])  # up the fork, leaning back
for _ in range(4):
    n0 = np.array([d0[1], -d0[0]])  # forward-pointing normal
    rel = np.c_[f_, u_] - axF; t = rel @ d0; off = rel @ n0
    m = (t > 0.1) & (t < 0.8) & (np.abs(off) < 0.09) & (np.abs(s3) > 0.06) & (np.abs(s3) < 0.2)
    P = np.c_[f_[m], u_[m]]; cen = P.mean(0)
    _, _, vt = np.linalg.svd(P - cen); d0 = vt[0] * np.sign(vt[0][1])
forkUp = d0; forkN = np.array([forkUp[1], -forkUp[0]])
forkPt = cen  # a point on the fork-tube line
rake = math.degrees(math.atan2(-forkUp[0], forkUp[1]))
print('fork rake deg', rake, 'fork pts', m.sum())

def classify(Dc):
    f, u, s = Dc
    p = np.array([f, u])
    dF, dR = np.linalg.norm(p - axF), np.linalg.norm(p - axR)
    relF = p - forkPt; t_ax = (p - axF) @ forkUp; off = relF @ forkN
    in_fork_band = abs(off) < 0.06 and abs(s) > 0.055
    # swingarm band: pivot -> rear axle
    piv = np.array(PIVOT); sa = axR - piv; L = np.linalg.norm(sa); sd = sa / L
    ts = (p - piv) @ sd; os_ = abs((p - piv) @ np.array([sd[1], -sd[0]]))
    in_swing = (-0.06 < ts < L + 0.07) and os_ < 0.075 and (abs(s) > 0.06 or ts < L - rRd)
    if dF < rFd * 1.03 and not in_fork_band:
        return 'FrontWheel'
    if dR < rRd * 1.03 and not in_swing:
        return 'RearWheel'
    if in_swing and u < 0.62:
        return 'Swingarm'
    steer = (off > -0.07 and t_ax > -0.12 and u > RF - 0.15) or (u > 1.15 and off > -0.32)
    if steer:
        if in_fork_band and t_ax < 0.42:
            return 'ForkLower'
        return 'Steer'
    return 'Frame'

PARTS = ['Frame', 'Steer', 'ForkLower', 'FrontWheel', 'RearWheel', 'Swingarm']
bm = bmesh.new(); bm.from_mesh(o.data)
owner = {}
for fc in bm.faces:
    cc = to_design(np.array([fc.calc_center_median()[:]]))[0]
    owner[fc.index] = classify(cc)
bm.free()

# bake the design transform into the vertices: Blender coords = (s, -f, u)  (forward = -Y, right = +X, up = +Z)
Dw = D.copy()
for i, vtx in enumerate(o.data.vertices):
    f, u, s = Dw[i]
    vtx.co = Vector((s, -f, u))
o.data.update()

# wheels: rescale each wheel about its axle to the physics tyre radius
objs = {}
counts = {}
for pname in PARTS:
    ob = o.copy(); ob.data = o.data.copy(); ob.name = pname; ob.data.name = pname
    bpy.context.collection.objects.link(ob)
    bm = bmesh.new(); bm.from_mesh(ob.data); bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[fc for fc in bm.faces if owner[fc.index] != pname], context='FACES')
    if pname in ('FrontWheel', 'RearWheel'):
        ax, rr, R = (axF, rFd, RF) if pname == 'FrontWheel' else (axR, rRd, RR)
        cen3 = Vector((0, -ax[0], ax[1])); sc = R / rr
        for vv in bm.verts:
            d = vv.co - cen3
            vv.co = cen3 + Vector((d.x, d.y * sc, d.z * sc))
    bm.to_mesh(ob.data); counts[pname] = len(bm.faces); bm.free()
    objs[pname] = ob
bpy.data.objects.remove(o)
print('TRIS', counts)

# orientation / origin markers (tiny cubes) so the game can recover the design frame after import
def marker(name, loc):
    bpy.ops.mesh.primitive_cube_add(size=0.01, location=loc)
    m = bpy.context.active_object; m.name = name; m.data.name = name
    m.data.materials.append(objs['Frame'].data.materials[0])
marker('Origin', (0, 0, 0)); marker('MarkFwd', (0, -1, 0)); marker('MarkUp', (0, 0, 1))
# set each part's object origin at the bounding-box centre (the importer recentres MeshParts anyway)

# rider contact points from the mesh itself
def dverts(name):
    ob = objs[name]; return np.array([(-v.co.y, v.co.z, v.co.x) for v in ob.data.vertices])
St = dverts('Steer'); bar = St[np.abs(St[:, 2]) > 0.30]
grip = [float(np.median(bar[:, 0])), float(np.median(bar[:, 1])), float(np.percentile(np.abs(bar[:, 2]), 70))]
Fr = dverts('Frame'); seatz = Fr[(Fr[:, 0] > 0.45) & (Fr[:, 0] < 0.70) & (np.abs(Fr[:, 2]) < 0.08)]
seatTop = float(seatz[:, 1].max())
print('grip', grip, 'seatTop', seatTop)
data = {
    'grip': grip, 'seatTop': seatTop,
    'wheelbase': WB, 'frontAxle': list(axF), 'rearAxle': list(axR),
    'frontRadius': RF, 'rearRadius': RR,
    'forkPoint': list(map(float, forkPt)), 'forkUp': list(map(float, forkUp)), 'rakeDeg': rake,
    'swingarmPivot': list(PIVOT), 'scale': k, 'tris': counts,
}
os.makedirs(out, exist_ok=True)
json.dump(data, open(os.path.join(out, 'bike_450_parts.json'), 'w'), indent=1)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out, 'bike_450_parts.blend'))
bpy.ops.export_scene.fbx(filepath=os.path.join(out, 'bike_450_parts.fbx'), object_types={'MESH'},
    axis_forward='-Z', axis_up='Y', apply_unit_scale=True, apply_scale_options='FBX_SCALE_ALL',
    path_mode='COPY', embed_textures=True, mesh_smooth_type='FACE')
bpy.ops.export_scene.gltf(filepath=os.path.join(out, 'bike_450_parts.glb'), export_format='GLB')

if preview:
    import random
    sc = bpy.context.scene
    w = bpy.data.worlds.new('w'); sc.world = w; w.use_nodes = True
    w.node_tree.nodes['Background'].inputs[1].default_value = 2.0
    cols = {'Frame': (.6, .6, .6), 'Steer': (.1, .4, 1), 'ForkLower': (0, 1, 1), 'FrontWheel': (1, .2, .1),
            'RearWheel': (1, .8, 0), 'Swingarm': (.2, 1, .2)}
    for pn, ob in objs.items():
        mt = bpy.data.materials.new(pn + 'c'); mt.use_nodes = True
        mt.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (*cols[pn], 1)
        ob.data.materials.clear(); ob.data.materials.append(mt)
    cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
    cam.data.type = 'ORTHO'; cam.data.ortho_scale = 2.4
    sc.render.engine = 'CYCLES'; sc.cycles.samples = 16; sc.render.resolution_x = 1200; sc.render.resolution_y = 800
    for i, (loc, rot) in enumerate([((5, -0.75, 0.6), (90, 0, 90)), ((-3, 1.2, 1.6), (70, 0, -130)), ((0, -0.75, 5), (0, 0, 0))]):
        cam.location = loc; cam.rotation_euler = [math.radians(a) for a in rot]
        sc.render.filepath = os.path.join(out, f'split_{i}.png'); bpy.ops.render.render(write_still=True)
