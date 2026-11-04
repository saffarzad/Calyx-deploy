# رندر سینمایی ویدئوی چرخشی با Blender Cycles (ray tracing واقعی) — کیفیت استودیویی غذا
#   pipeline/.venv/bin/python pipeline/render_cycles.py <model.glb> <out_dir> [--frames 150] [--size 720] [--samples 96]
# خروجی: فریم‌های PNG شفاف (با سایهٔ نرم روی زمین) در out_dir؛ ترکیب با رنگ پس‌زمینه و ساخت ویدئو در cinematic.js
import argparse
import math
import os
import sys

import bpy
from mathutils import Vector

p = argparse.ArgumentParser()
p.add_argument('glb')
p.add_argument('out')
p.add_argument('--frames', type=int, default=150)
p.add_argument('--size', type=int, default=720)
p.add_argument('--samples', type=int, default=96)
p.add_argument('--start', type=float, default=0.45, help='زاویهٔ شروع (رادیان)؛ سه‌رخ')
p.add_argument('--sway', type=float, default=0, help='اگر بیشتر از صفر: به‌جای ۳۶۰ درجه، غذا دور زاویهٔ start این‌قدر (درجه) نرم رفت‌وبرگشت می‌کند؛ همیشه سمت جذاب دیده می‌شود')
p.add_argument('--elev', type=float, default=0.3, help='ارتفاع دوربین؛ کمتر = زاویهٔ پایین‌تر و قهرمانانه‌تر')
p.add_argument('--fstop', type=float, default=5.6)
p.add_argument('--margin', type=float, default=1.18, help='فاصلهٔ دوربین نسبت به اندازهٔ غذا')
p.add_argument('--sss', type=float, default=0.12, help='پخش نور زیر سطح (نان، کاهو، گوجه)؛ حس واقعی غذا')
p.add_argument('--only', type=int, default=-1, help='فقط یک فریم (برای پیش‌نمایش)')
p.add_argument('--range', default='', help='فقط این بازه‌ها، مثل 0-31,94-124 (در حالت رفت‌وبرگشت نیمهٔ برگشت لازم نیست)')
p.add_argument('--view', default='Khronos PBR Neutral', help='Khronos PBR Neutral رنگ واقعی محصول را دقیق نگه می‌دارد')
p.add_argument('--look', default='None')
p.add_argument('--exposure', type=float, default=0.0)
p.add_argument('--light', type=float, default=0.5, help='ضریب شدت همهٔ نورها')
p.add_argument('--hdri', default='', help='نقشهٔ محیطی استودیو (HDRI) برای انعکاس‌های واقعی‌تر روی سطوح براق')
p.add_argument('--hdri-strength', type=float, default=0.6)
p.add_argument('--hdri-rot', type=float, default=0.0, help='چرخش HDRI (درجه)')
p.add_argument('--back', type=float, default=0.0, help='نور پشت پایین: کاهو و گوجه را از پشت روشن می‌کند (درخشش زیرسطحی)')
args = p.parse_args(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:])

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---------- مدل ----------
bpy.ops.import_scene.gltf(filepath=args.glb)
meshes = [o for o in scene.objects if o.type == 'MESH']
bpy.context.view_layer.update()
pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
lo = Vector((min(v.x for v in pts), min(v.y for v in pts), min(v.z for v in pts)))
hi = Vector((max(v.x for v in pts), max(v.y for v in pts), max(v.z for v in pts)))
size = hi - lo
# مقیاس یکسان: بلندترین بعد = ۱ واحد، تا نور و دوربین برای هر غذا یکسان باشد
k = 1.0 / max(size.x, size.y, size.z)

pivot = bpy.data.objects.new('pivot', None)
scene.collection.objects.link(pivot)
for o in scene.objects:
    if o.parent is None and o is not pivot:
        o.parent = pivot
pivot.scale = (k, k, k)
pivot.location = (-(lo.x + hi.x) / 2 * k, -(lo.y + hi.y) / 2 * k, -lo.z * k)
# چرخش حول مرکز مدل: یک empty والد در مبدأ
spin = bpy.data.objects.new('spin', None)
scene.collection.objects.link(spin)
pivot.parent = spin
H = size.z * k  # ارتفاع نهایی مدل
W = max(size.x, size.y) * k

# غذا فلزی نیست؛ فلزی بودنِ Meshy را صفر می‌کنیم و کمی براقیِ سطحی (coat) برای سس و روغن می‌دهیم
for m in bpy.data.materials:
    if not m.use_nodes:
        continue
    for n in m.node_tree.nodes:
        if n.type == 'BSDF_PRINCIPLED':
            mi = n.inputs['Metallic']
            for l in list(mi.links):
                m.node_tree.links.remove(l)
            mi.default_value = 0.0
            # براقیِ پلاستیکی کمتر و پخش نور زیر سطح مثل غذای واقعی
            if 'Specular IOR Level' in n.inputs:
                n.inputs['Specular IOR Level'].default_value = 0.35
            if args.sss > 0 and 'Subsurface Weight' in n.inputs:
                n.inputs['Subsurface Weight'].default_value = args.sss
                n.inputs['Subsurface Scale'].default_value = 0.012

# ---------- زمین: گیرندهٔ سایه (فقط سایه دیده می‌شود) ----------
bpy.ops.mesh.primitive_plane_add(size=20, location=(0, 0, 0))
floor = bpy.context.active_object
floor.is_shadow_catcher = True

# ---------- نورپردازی استودیو ----------
def area(name, loc, energy, size_, color=(1, 1, 1), shadow=True):
    light = bpy.data.lights.new(name, 'AREA')
    light.shape = 'DISK'
    light.size = size_
    light.energy = energy * args.light
    light.color = color
    light.use_shadow = shadow
    o = bpy.data.objects.new(name, light)
    scene.collection.objects.link(o)
    o.location = loc
    d = Vector((0, 0, H * 0.45)) - Vector(loc)
    o.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    return o

area('key', (-1.3, -1.6, 3.0), 420, 2.2, (1.0, 0.96, 0.9))     # سافت‌باکس اصلی بالا-چپ-جلو
area('fill', (2.0, -1.4, 2.2), 90, 2.6, (0.92, 0.95, 1.0))     # پرکننده‌ی ملایم سمت راست؛ بالا تا سایه‌اش کوتاه بماند
area('rim', (1.0, 2.0, 3.2), 300, 1.0, (1.0, 0.9, 0.8))  # نور پشتی بالا برای لبه‌ها؛ از بالا می‌تابد تا سایه‌اش کوتاه و پشت غذا بیفتد
area('top', (0, 0, 3.2), 120, 3.0)                              # نور بالا برای براقی سطح

if args.back > 0:
    area('back', (0.3, 2.4, 0.9), 260 * args.back, 1.6, (1.0, 0.93, 0.82))

world = bpy.data.worlds.new('studio')
scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes['Background']
bg.inputs['Color'].default_value = (0.9, 0.88, 0.85, 1)
bg.inputs['Strength'].default_value = 0.35
if args.hdri:
    wn = world.node_tree.nodes; wl = world.node_tree.links
    env = wn.new('ShaderNodeTexEnvironment'); env.image = bpy.data.images.load(args.hdri)
    mp = wn.new('ShaderNodeMapping'); tc = wn.new('ShaderNodeTexCoord'); mp.inputs['Rotation'].default_value[2] = math.radians(args.hdri_rot)
    wl.new(tc.outputs['Generated'], mp.inputs['Vector']); wl.new(mp.outputs[0], env.inputs['Vector']); wl.new(env.outputs['Color'], bg.inputs['Color'])
    bg.inputs['Strength'].default_value = args.hdri_strength

# ---------- دوربین ----------
cam_data = bpy.data.cameras.new('cam')
cam_data.lens = 70  # لنز تله‌ی ملایم مثل عکاسی غذا: پرسپکتیو طبیعی، بدون اغراق
cam = bpy.data.objects.new('cam', cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
target = Vector((0, 0, H * 0.45))
fov = 2 * math.atan(cam_data.sensor_width / 2 / cam_data.lens)
dim = max(W, H * 1.1)
dist = dim / 2 / math.tan(fov / 2) * args.margin
elev = args.elev
cam_data.dof.use_dof = True
cam_data.dof.focus_distance = dist
cam_data.dof.aperture_fstop = args.fstop  # عمق میدان کم و سینمایی، ولی کل غذا واضح

def place_camera(t):
    y_off = math.sin(t * 2 * math.pi + (math.pi / 2 if args.sway > 0 else 0)) * dist * 0.06
    cam.location = (0, -dist, target.z + dist * elev + y_off)
    d = target - cam.location
    cam_data.dof.focus_distance = d.length
    cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()

# ---------- رندر ----------
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = args.samples
scene.cycles.use_adaptive_sampling = True
scene.cycles.adaptive_threshold = 0.06
scene.cycles.adaptive_min_samples = 8
scene.render.use_persistent_data = True
scene.cycles.use_denoising = True
scene.cycles.max_bounces = 6
scene.render.film_transparent = True
scene.render.resolution_x = scene.render.resolution_y = args.size
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.view_settings.view_transform = args.view
try:
    scene.view_settings.look = args.look
except TypeError:
    pass
scene.view_settings.exposure = args.exposure
scene.render.threads_mode = 'AUTO'

os.makedirs(args.out, exist_ok=True)
frames = [args.only] if args.only >= 0 else range(args.frames)
if args.range and args.only < 0:
    frames = [i for part in args.range.split(',') for i in range(int(part.split('-')[0]), int(part.split('-')[1]) + 1)]
for i in frames:
    t = 0.75 + i / (2 * (args.frames - 1))
    if args.sway > 0:
        angle = args.start + math.radians(args.sway) * math.sin(t * 2 * math.pi)
    else:
        angle = args.start + t * 2 * math.pi
    spin.rotation_euler = (0, 0, angle)
    place_camera(t)
    scene.render.filepath = os.path.join(args.out, f'{i:04d}.png')
    # ادامه از جای قطع‌شده (رندرهای چندساعته ممکن است با ری‌استارت سرور قطع شوند)
    done = os.path.exists(scene.render.filepath) and os.path.getsize(scene.render.filepath) > 0
    if args.only < 0 and done:
        continue
    bpy.ops.render.render(write_still=True)
    print(f'frame {i + 1}/{args.frames}', flush=True)
