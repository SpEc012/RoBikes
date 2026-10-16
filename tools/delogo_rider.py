# Paint out the stray boot-shin logo in the rider texture. Usage: python3 delogo.py in.blend out.blend
import bpy, sys, bmesh, numpy as np
src, dst = sys.argv[-2], sys.argv[-1]
bpy.ops.wm.open_mainfile(filepath=src)
img = next(i for i in bpy.data.images if i.name == 'Image_0')
W, H = img.size
px = np.array(img.pixels[:], dtype=np.float32).reshape(H, W, 4)
mask = np.zeros((H, W), bool)
for o in bpy.data.objects:
    if o.type != 'MESH' or not o.name.endswith(('LowerLeg_Geo', 'Foot_Geo')): continue
    bm = bmesh.new(); bm.from_mesh(o.data); uv = bm.loops.layers.uv.active
    for f in bm.faces:
        c = o.matrix_world @ f.calc_center_median(); n = (o.matrix_world.to_3x3() @ f.normal).normalized()
        if not (0.215 < c.z < 0.37 and n.y < -0.15): continue
        pts = np.array([[l[uv].uv.x * W, l[uv].uv.y * H] for l in f.loops])
        for i in range(1, len(pts) - 1):
            tri = pts[[0, i, i + 1]]
            x0, y0 = np.floor(tri.min(0)).astype(int) - 1; x1, y1 = np.ceil(tri.max(0)).astype(int) + 1
            xs, ys = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
            p = np.stack([xs + .5, ys + .5], -1)
            a, b, cc = tri
            d = (b[1]-cc[1])*(a[0]-cc[0]) + (cc[0]-b[0])*(a[1]-cc[1])
            if abs(d) < 1e-9: continue
            l1 = ((b[1]-cc[1])*(p[...,0]-cc[0]) + (cc[0]-b[0])*(p[...,1]-cc[1])) / d
            l2 = ((cc[1]-a[1])*(p[...,0]-cc[0]) + (a[0]-cc[0])*(p[...,1]-cc[1])) / d
            ins = (l1 > -.05) & (l2 > -.05) & (1 - l1 - l2 > -.05)
            yy, xx = ys[ins] % H, xs[ins] % W
            mask[yy, xx] = True
    bm.free()
# dilate 2 px
for _ in range(2):
    m = mask.copy(); m[1:] |= mask[:-1]; m[:-1] |= mask[1:]; m[:, 1:] |= mask[:, :-1]; m[:, :-1] |= mask[:, 1:]; mask = m
rgb = px[..., :3]; luma = rgb @ np.array([.2126, .7152, .0722])
inm = luma[mask]; dark = np.percentile(inm, 35)
fill = np.median(rgb[mask & (luma <= dark)], axis=0)
light = mask & (luma > dark * 1.25)
rng = np.random.default_rng(1)
rgb[light] = fill * (1 + rng.normal(0, .04, (light.sum(), 1)))
px[..., :3] = rgb
print('masked texels', mask.sum(), 'repainted', light.sum(), 'fill', fill)
img.pixels[:] = px.ravel(); img.update()
import os
p = os.path.join(os.path.dirname(dst), 'rider_texture_clean.png')
img.filepath_raw = p; img.file_format = 'PNG'; img.save()
img.unpack(method='REMOVE') if img.packed_file else None
img.filepath = p; img.reload(); img.pack()
bpy.ops.wm.save_as_mainfile(filepath=dst)
