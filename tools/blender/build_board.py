"""Build the 3D game board in Blender from assets/map/map_data.json.

One raised tile per territory (height by its main terrain), river channels cut
between tiles, a pale base that shows through the gaps as the faint borders,
golden continent edges, and low-poly terrain props (peaks, mesas, trees,
dunes, fields, ponds) kept inside each territory with its center left open.

Everything is exported as one FBX for Roblox Studio's 3D importer, with one
object per piece so the game can tint and select them:
  Ground_NN       territory tile (plain color, tinted by the game)
  Props_NN        that territory's props (palette texture)
  Edge_CC         continent outline (plain color, tinted by the game)
  Rivers, LandBase

Units: 1 Blender unit = 1 stud. Map pixel (x, y) -> (x - W/2, -(y - H/2)) * 0.5,
so north is +Y in Blender and -Z in Roblox.

Run with Blender:  blender --background --python tools/blender/build_board.py -- [options]
or with the bpy module:  python tools/blender/build_board.py [options]
Options: --data PATH  --out DIR  --render (also render preview PNGs)
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import sys

import bpy  # first: with the bpy module, bmesh and mathutils load through it
import bmesh  # noqa: I001
import shapely
from mathutils import Matrix
from shapely.geometry import LineString, MultiPolygon, Point, Polygon
from shapely.geometry.polygon import orient
from shapely.ops import unary_union

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))

SCALE = 0.5  # studs per map pixel, matches GameConfig.Map.StudsPerPixel
BOTTOM = -4.0  # tiles reach under the water so the coast shows as a low cliff
BASE_TOP = 1.2  # the pale floor seen in the gaps between tiles
GAP = 0.6  # each tile is pulled back this far from its border
RIVER_Z = 1.5
# Top of each tile by main terrain, matches GameConfig.Map.Elevation.
ELEVATION = {"mountain": 9, "plateau": 6.5, "forest": 3.5, "desert": 3.5, "plains": 3, "valley": 2.5, "lake": 2.2}
GROUND = {
    "mountain": "8a7d6c",
    "plateau": "c79a5e",
    "plains": "a9c464",
    "valley": "7db35a",
    "desert": "e2c483",
    "forest": "4f8a45",
    "lake": "86c7c0",
}
BASE_COLOR = "d6cfbf"
RIVER_COLOR = "3a8fd8"
GOLD = "e0ad2a"
RIVER_WIDTH = {True: 9.0, False: 5.5}  # map pixels

# Palette texture: one flat swatch per prop color, 5x5 swatches.
PALETTE = [
    "a39582",  # 0 rock light
    "7d705f",  # 1 rock mid
    "5f5446",  # 2 rock dark
    "d9b27a",  # 3 mesa light
    "b9824a",  # 4 mesa band
    "f0d9a2",  # 5 sand light
    "d4b679",  # 6 sand shade
    "3f7a3a",  # 7 leaf dark
    "5e9a45",  # 8 leaf mid
    "86b552",  # 9 leaf light
    "6b4a2e",  # 10 trunk
    "4aa3c9",  # 11 water
    "c9d36a",  # 12 field yellow-green
    "a7c85a",  # 13 field green
    "e3c86a",  # 14 field gold
    "e8e2d0",  # 15 pale stone
    "98b858",  # 16 plains patch
    "6ca44e",  # 17 valley patch
    "d4b571",  # 18 desert patch
    "b68a50",  # 19 plateau patch
    "7a6d5d",  # 20 mountain patch
    "467d3d",  # 21 forest floor
    "bcd77a",  # 22 meadow light
    "c9b58a",  # 23 dirt
    "b8ab96",  # 24 rock pale
]
SW = 5  # swatches per row
PATCH = {"plains": (16, 22), "valley": (17, 22), "desert": (18, 6), "plateau": (19, 4), "mountain": (20, 24), "forest": (21, 17), "lake": (17, 16)}


def hex_rgb(h, alpha=1.0):
    h = h.lstrip("#")
    srgb = [int(h[i : i + 2], 16) / 255 for i in (0, 2, 4)]
    lin = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb]
    return (*lin, alpha)


# ---------------------------------------------------------------- geometry


class Map:
    def __init__(self, data):
        self.w, self.h = data["image"]["width"], data["image"]["height"]
        self.data = data

    def poly(self, coords):
        return Polygon([self.pt(x, y) for x, y in coords])

    def pt(self, x, y):
        return ((x - self.w / 2) * SCALE, -(y - self.h / 2) * SCALE)

    def line(self, coords):
        return LineString([self.pt(x, y) for x, y in coords])


def parts(geom, min_area=4.0):
    if geom.is_empty:
        return []
    geoms = geom.geoms if hasattr(geom, "geoms") else [geom]
    return [orient(g, 1.0) for g in geoms if isinstance(g, Polygon) and g.area >= min_area]


class MeshBuilder:
    """Collects vertices and faces, with an optional palette swatch per face."""

    def __init__(self):
        self.verts = []
        self.faces = []
        self.swatch = []

    def add_face(self, idx, swatch=0):
        if len(set(idx)) < 3:
            return  # vertices merged into a sliver; drop it
        self.faces.append(idx)
        self.swatch.append(swatch)

    def add_verts(self, vs):
        base = len(self.verts)
        self.verts.extend(vs)
        return base

    def prism(self, poly, z_top, z_bottom, swatch=0, top_z=None):
        """Flat-topped solid over a polygon (holes allowed), with walls. No bottom."""
        tris = shapely.constrained_delaunay_triangles(poly)
        index = {}

        def vid(x, y, z):
            key = (round(x, 3), round(y, 3), round(z, 3))
            if key not in index:
                index[key] = self.add_verts([(x, y, z)])
            return index[key]

        ztop = top_z or (lambda x, y: z_top)
        for t in tris.geoms:
            (ax, ay), (bx, by), (cx, cy) = list(t.exterior.coords)[:3]
            cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
            if abs(cross) < 1e-3:
                continue
            if cross < 0:
                bx, by, cx, cy = cx, cy, bx, by
            self.add_face([vid(ax, ay, ztop(ax, ay)), vid(bx, by, ztop(bx, by)), vid(cx, cy, ztop(cx, cy))], swatch)
        if z_bottom is None:
            return
        for ring in [poly.exterior, *poly.interiors]:
            pts = list(ring.coords)[:-1]
            for i, (ax, ay) in enumerate(pts):
                bx, by = pts[(i + 1) % len(pts)]
                self.add_face(
                    [
                        vid(ax, ay, z_bottom),
                        vid(bx, by, z_bottom),
                        vid(bx, by, ztop(bx, by)),
                        vid(ax, ay, ztop(ax, ay)),
                    ],
                    swatch,
                )

    def merge_bmesh(self, bm, matrix, swatch_of):
        """Copy a bmesh in, transformed, choosing each face's swatch by its face."""
        bm.verts.index_update()
        base = self.add_verts([tuple(matrix @ v.co) for v in bm.verts])
        for f in bm.faces:
            self.add_face([base + v.index for v in f.verts], swatch_of(f, matrix))

    def to_object(self, name, material, uv=False):
        mesh = bpy.data.meshes.new(name)
        mesh.from_pydata(self.verts, [], self.faces)
        mesh.update()
        if uv:
            layer = mesh.uv_layers.new(name="UVMap")
            for poly, sw in zip(mesh.polygons, self.swatch):
                u = (sw % SW + 0.5) / SW
                v = 1 - (sw // SW + 0.5) / SW
                for li in poly.loop_indices:
                    layer.data[li].uv = (u, v)
        for p in mesh.polygons:
            p.use_smooth = False
        obj = bpy.data.objects.new(name, mesh)
        obj.data.materials.append(material)
        bpy.context.scene.collection.objects.link(obj)
        return obj


# ---------------------------------------------------------------- materials


def flat_material(name, color, roughness=0.85, metallic=0.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = hex_rgb(color)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    return mat


def palette_material(out_dir):
    size = SW * 8
    img = bpy.data.images.new("Palette", size, size)
    px = [0.0] * (size * size * 4)
    for i, h in enumerate(PALETTE):
        r, g, b = (int(h[k : k + 2], 16) / 255 for k in (0, 2, 4))
        cx, cy = (i % SW) * 8, (SW - 1 - i // SW) * 8
        for y in range(cy, cy + 8):
            for x in range(cx, cx + 8):
                o = (y * size + x) * 4
                px[o : o + 4] = [r, g, b, 1.0]
    img.pixels = px
    img.filepath_raw = os.path.join(out_dir, "palette.png")
    img.file_format = "PNG"
    img.save()
    mat = bpy.data.materials.new("Props")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = img
    tex.interpolation = "Closest"
    bsdf = nodes.get("Principled BSDF")
    bsdf.inputs["Roughness"].default_value = 0.9
    mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


# ---------------------------------------------------------------- props


def jitter(bm, rng, amount, keep_base=True):
    for v in bm.verts:
        if keep_base and v.co.z <= 1e-4:
            continue
        v.co.x += rng.uniform(-amount, amount)
        v.co.y += rng.uniform(-amount, amount)
        v.co.z += rng.uniform(-amount, amount) * 0.6


def peak(rng, height, radius):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=False, segments=rng.choice([6, 7, 8]), radius1=radius, radius2=0, depth=height)
    bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, height / 2))
    # A ring halfway up gives the slope a broken, rocky profile.
    edges = [e for e in bm.edges if abs(e.verts[0].co.z - e.verts[1].co.z) > 1e-3]
    bmesh.ops.subdivide_edges(bm, edges=edges, cuts=1)
    jitter(bm, rng, radius * 0.18)
    return bm


def by_height(top, light, mid, dark):
    def pick(face, matrix):
        z = face.calc_center_median().z
        lit = face.normal.z > 0.55
        if z > top * 0.62:
            return light if lit else mid
        return mid if lit else dark

    return pick


def mesa(rng, height, radius):
    bm = bmesh.new()
    n = rng.randint(7, 10)
    pts = []
    for i in range(n):
        a = i / n * math.tau
        r = radius * rng.uniform(0.75, 1.1)
        pts.append(bm.verts.new((math.cos(a) * r, math.sin(a) * r, 0)))
    face = bm.faces.new(pts)
    # Two tiers: a wide lower step and the flat top.
    for frac, shrink in ((0.45, 0.88), (1.0, 0.8)):
        ext = bmesh.ops.extrude_face_region(bm, geom=[face])
        new = [g for g in ext["geom"] if isinstance(g, bmesh.types.BMVert)]
        z = height * frac
        for v in new:
            v.co.z = z
        face = [g for g in ext["geom"] if isinstance(g, bmesh.types.BMFace)][0]
        c = face.calc_center_median()
        for v in face.verts:
            v.co.x = c.x + (v.co.x - c.x) * shrink
            v.co.y = c.y + (v.co.y - c.y) * shrink
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def mesa_colors(height):
    def pick(face, matrix):
        if face.normal.z > 0.6:
            return 3
        z = face.calc_center_median().z
        return 4 if (z / height) % 0.5 < 0.25 else 3

    return pick


def trunk(height, scale):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=False, segments=5, radius1=0.35 * scale, radius2=0.3 * scale, depth=height * scale)
    bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, height * scale / 2))
    return bm


def conifer(rng, scale):
    """Trunk and crown as separate meshes, so each gets its own color."""
    crown = bmesh.new()
    for r, z, d in ((1.6, 1.0, 2.4), (1.25, 2.4, 2.1), (0.9, 3.6, 1.8)):
        tier = bmesh.new()
        bmesh.ops.create_cone(tier, cap_ends=True, segments=7, radius1=r * scale, radius2=0, depth=d * scale)
        bmesh.ops.translate(tier, verts=tier.verts, vec=(0, 0, (z + d / 2) * scale))
        merge_into(crown, tier)
    return trunk(1.2, scale), crown


def broadleaf(rng, scale):
    crown = bmesh.new()
    bmesh.ops.create_icosphere(crown, subdivisions=1, radius=1.7 * scale)
    bmesh.ops.scale(crown, vec=(1, 1, 0.85), verts=crown.verts)
    jitter(crown, rng, 0.25 * scale, keep_base=False)
    bmesh.ops.translate(crown, verts=crown.verts, vec=(0, 0, 3.0 * scale))
    return trunk(1.8, scale), crown


def dune(rng, length):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=10, v_segments=5, radius=1.0)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < -1e-4], context="VERTS")
    bmesh.ops.scale(bm, vec=(length, length * 0.45, length * 0.22), verts=bm.verts)
    return bm


def rock(rng, size):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=1, radius=size)
    bmesh.ops.scale(bm, vec=(1, rng.uniform(0.7, 1), rng.uniform(0.5, 0.8)), verts=bm.verts)
    jitter(bm, rng, size * 0.2, keep_base=False)
    return bm


def pond(rng, radius):
    bm = bmesh.new()
    bmesh.ops.create_circle(bm, cap_ends=True, segments=12, radius=radius)
    for v in bm.verts:
        s = rng.uniform(0.85, 1.1)
        v.co.x *= s
        v.co.y *= s * 0.8
    bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, 0.3))
    rim = bmesh.new()
    bmesh.ops.create_circle(rim, cap_ends=True, segments=12, radius=radius * 1.22)
    for v in rim.verts:
        v.co.y *= 0.82
    bmesh.ops.translate(rim, verts=rim.verts, vec=(0, 0, 0.24))
    merge_into(bm, rim)
    return bm


def pond_colors(face, matrix):
    return 11 if face.calc_center_median().z > 0.27 else 5


def field(rng, w, d):
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=0.5)
    bmesh.ops.scale(bm, vec=(w, d, 1), verts=bm.verts)
    bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, 0.2))
    return bm


def merge_into(bm, other):
    other.verts.index_update()
    mapping = [bm.verts.new(v.co) for v in other.verts]
    for f in other.faces:
        try:
            bm.faces.new([mapping[v.index] for v in f.verts])
        except ValueError:
            pass
    other.free()


class Scatter:
    """Places prop footprints inside a territory: inside the border, away from
    rivers, clear of the center, and not on top of each other."""

    def __init__(self, area, center, clear, blocked):
        self.area = area
        self.center = center
        self.clear = clear
        self.blocked = blocked
        self.taken = []
        minx, miny, maxx, maxy = area.bounds
        self.box = (minx, miny, maxx, maxy)

    def spot(self, rng, radius, near=None, spread=None, tries=60):
        minx, miny, maxx, maxy = self.box
        for _ in range(tries):
            if near is not None:
                a = rng.uniform(0, math.tau)
                d = rng.uniform(0, spread)
                x, y = near[0] + math.cos(a) * d, near[1] + math.sin(a) * d
            else:
                x, y = rng.uniform(minx, maxx), rng.uniform(miny, maxy)
            p = Point(x, y)
            if math.hypot(x - self.center[0], y - self.center[1]) < self.clear + radius:
                continue
            if not self.area.contains(p.buffer(radius * 0.9, quad_segs=3)):
                continue
            if self.blocked is not None and self.blocked.distance(p) < radius + 1.0:
                continue
            if any(math.hypot(x - tx, y - ty) < (radius + tr) * 0.85 for tx, ty, tr in self.taken):
                continue
            self.taken.append((x, y, radius))
            return x, y
        return None


def place(builder, bm, x, y, z, rot, swatch_of, scale=1.0):
    m = Matrix.Translation((x, y, z)) @ Matrix.Rotation(rot, 4, "Z") @ Matrix.Scale(scale, 4)
    builder.merge_bmesh(bm, m, swatch_of)
    bm.free()


def props_for(t, area, center, top, blocked, rng):
    """Props for one territory as a MeshBuilder (palette swatches)."""
    out = MeshBuilder()
    inradius = max(10.0, area.exterior.distance(Point(center)))
    clear = max(14.0, 0.38 * inradius)
    sc = Scatter(area, center, clear, blocked)
    size = {"small": 0.85, "medium": 1.0, "large": 1.12}.get(t["size"], 1.0)
    main = t["terrains"][0]
    room = area.area

    def peaks(count, big):
        for _ in range(count):
            r0 = rng.uniform(7, 10) * big
            spot = sc.spot(rng, r0 * 1.4)
            if not spot:
                continue
            for k in range(rng.randint(2, 4)):
                hgt = rng.uniform(14, 24) * big * (1.0 if k == 0 else rng.uniform(0.55, 0.8))
                rad = hgt * rng.uniform(0.5, 0.65)
                dx, dy = (0, 0) if k == 0 else (rng.uniform(-1, 1) * r0, rng.uniform(-1, 1) * r0)
                place(out, peak(rng, hgt, rad), spot[0] + dx, spot[1] + dy, top - 0.4, rng.uniform(0, 6.3), by_height(hgt, 0, 1, 2))

    def mesas(count, big):
        for _ in range(count):
            rad = rng.uniform(7, 11) * big
            spot = sc.spot(rng, rad * 1.1)
            if spot:
                hgt = rng.uniform(6, 10) * big
                place(out, mesa(rng, hgt, rad), spot[0], spot[1], top - 0.3, rng.uniform(0, 6.3), mesa_colors(hgt))

    tree_scale = 1.15 if main == "forest" else 1.0

    def grove(count, spread, near=None):
        hub = near or sc.spot(rng, spread * 0.6)
        if not hub:
            return
        for _ in range(count):
            s = rng.uniform(1.0, 1.6) * size * tree_scale
            spot = sc.spot(rng, 2.0 * s, near=hub, spread=spread)
            if not spot:
                continue
            if rng.random() < 0.55:
                (stem, crown), leaf = conifer(rng, s), rng.choice([7, 7, 8])
            else:
                (stem, crown), leaf = broadleaf(rng, s), rng.choice([8, 9])
            rot = rng.uniform(0, 6.3)
            place(out, stem, spot[0], spot[1], top, rot, lambda f, m: 10)
            place(out, crown, spot[0], spot[1], top, rot, lambda f, m, c=leaf: c)

    def dunes(count):
        for _ in range(count):
            ln = rng.uniform(7, 12) * size
            spot = sc.spot(rng, ln * 0.7)
            if spot:
                place(out, dune(rng, ln), spot[0], spot[1], top - 0.2, 0.5 + rng.uniform(-0.25, 0.25), lambda f, m: 5 if f.normal.y > 0 else 6)

    def rocks(count, swatch):
        for _ in range(count):
            r = rng.uniform(0.8, 1.8) * size
            spot = sc.spot(rng, r * 1.5, tries=20)
            if spot:
                place(out, rock(rng, r), spot[0], spot[1], top, rng.uniform(0, 6.3), lambda f, m: swatch if f.normal.z > 0.3 else 1)

    def patches(count, swatches):
        """Flat blobs of a darker or lighter shade so the ground isn't one flat color."""
        minx, miny, maxx, maxy = area.bounds
        for k in range(count):
            x, y = rng.uniform(minx, maxx), rng.uniform(miny, maxy)
            r = rng.uniform(7, 16) * size
            n = 12
            blob = Polygon(
                [(x + math.cos(i / n * math.tau) * r * rng.uniform(0.6, 1.15), y + math.sin(i / n * math.tau) * r * rng.uniform(0.6, 1.15)) for i in range(n)]
            ).buffer(1.5, quad_segs=2)
            blob = blob.intersection(area.buffer(-0.8))
            for piece in parts(blob, 3.0):
                # Each patch a hair higher than the last, so overlaps never z-fight.
                out.prism(piece, top + 0.03 + 0.012 * k, None, swatch=rng.choice(swatches))

    def ponds(count, big):
        for _ in range(count):
            rad = rng.uniform(5, 7) * big
            spot = sc.spot(rng, rad * 1.3)
            if spot:
                place(out, pond(rng, rad), spot[0], spot[1], top, rng.uniform(0, 6.3), pond_colors)

    def fields(count):
        hub = sc.spot(rng, 16)
        if not hub:
            return
        ang = rng.uniform(0, math.pi)
        for _ in range(count):
            w, d = rng.uniform(8, 15), rng.uniform(5, 9)
            spot = sc.spot(rng, max(w, d) * 0.55, near=hub, spread=22)
            if spot:
                place(out, field(rng, w, d), spot[0], spot[1], top, ang, lambda f, m, c=rng.choice([12, 13, 14]): c)

    per = room / 900.0  # roughly one feature per 30x30 studs
    patches(max(3, min(9, round(per * 0.9))), PATCH[main])
    if main == "mountain":
        peaks(max(3, min(8, round(per * 1.0))), 1.0 * size)
        grove(rng.randint(4, 7), 8)
        rocks(rng.randint(4, 8), 24)
    elif main == "plateau":
        mesas(max(2, min(5, round(per * 0.6))), size)
        grove(rng.randint(3, 5), 7)
        rocks(rng.randint(3, 6), 3)
    elif main == "forest":
        for _ in range(max(4, min(9, round(per * 1.0)))):
            grove(rng.randint(10, 16), 13)
    elif main == "desert":
        dunes(max(5, min(12, round(per * 1.2))))
        rocks(rng.randint(3, 6), 6)
        if rng.random() < 0.5:
            mesas(1, 0.6 * size)
    elif main == "valley":
        fields(rng.randint(6, 10))
        fields(rng.randint(4, 7))
        grove(rng.randint(5, 8), 9)
        grove(rng.randint(3, 6), 8)
    elif main == "plains":
        fields(rng.randint(5, 8))
        grove(rng.randint(4, 7), 10)
        grove(rng.randint(3, 5), 8)
        rocks(rng.randint(2, 5), 24)
    elif main == "lake":
        ponds(1, 2.2 * size)
        grove(rng.randint(4, 7), 9)

    for extra in t["terrains"][1:]:
        {
            "mountain": lambda: peaks(1, 0.8 * size),
            "plateau": lambda: mesas(1, 0.75 * size),
            "desert": lambda: dunes(2),
            "valley": lambda: fields(4),
            "plains": lambda: fields(3),
        }.get(extra, lambda: None)()
    for res in t["resources"]:
        if res == "forest" and main != "forest":
            grove(rng.randint(6, 10), 9)
        elif res == "pond" and main != "lake":
            ponds(1, size)
    return out


# ---------------------------------------------------------------- board


def build(data, out_dir):
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    m = Map(data)
    rng = random.Random(7)

    shapes = {t["id"]: m.poly(t["polygon"]).buffer(0) for t in data["territories"]}
    land = unary_union(list(shapes.values()))
    rivers = [(r, m.line(r["path"])) for r in data["rivers"]]
    channel = unary_union([line.buffer(RIVER_WIDTH[r["main"]] * SCALE / 2 + 0.9, quad_segs=4) for r, line in rivers])
    river_water = unary_union([line.buffer(RIVER_WIDTH[r["main"]] * SCALE / 2 + 0.6, quad_segs=4) for r, line in rivers]).intersection(land)

    palette = palette_material(out_dir)
    tops = {}
    tiles = {}
    stats = {"ground": 0, "props": 0}
    for t in data["territories"]:
        tid = t["id"]
        top = ELEVATION[t["terrains"][0]]
        tops[tid] = top
        tile = shapes[tid].buffer(-GAP, join_style="mitre").difference(channel).simplify(0.25)
        pieces = parts(tile)
        tiles[tid] = unary_union(pieces) if pieces else shapes[tid]
        ground = MeshBuilder()
        for p in pieces:
            ground.prism(p, top, BOTTOM)
        obj = ground.to_object(f"Ground_{tid:02d}", flat_material(f"Ground_{tid:02d}", GROUND[t["terrains"][0]]))
        obj["TerritoryId"] = tid
        stats["ground"] += sum(len(f) - 2 for f in ground.faces)

        area = max(pieces, key=lambda g: g.area).buffer(-1.0) if pieces else None
        if area is None or area.is_empty:
            continue
        cx, cy = m.pt(*t["center"])
        props = props_for(t, area if isinstance(area, Polygon) else max(area.geoms, key=lambda g: g.area), (cx, cy), top, channel, rng)
        if props.faces:
            pobj = props.to_object(f"Props_{tid:02d}", palette, uv=True)
            pobj["TerritoryId"] = tid
            stats["props"] += sum(len(f) - 2 for f in props.faces)

    # Pale floor under all tiles: it shows through the gaps as the borders.
    base = MeshBuilder()
    for p in parts(land.buffer(-GAP * 0.5)):
        base.prism(p.simplify(0.3), BASE_TOP, BOTTOM)
    base.to_object("LandBase", flat_material("LandBase", BASE_COLOR))

    water = MeshBuilder()
    for p in parts(river_water, 0.5):
        water.prism(p.simplify(0.2), RIVER_Z, None)
    water.to_object("Rivers", flat_material("Rivers", RIVER_COLOR, roughness=0.15))

    # Continent outline: a band just inside the continent's outer edge,
    # draped over its own tiles.
    def top_at(x, y, ids):
        p = Point(x, y)
        best, dist = BASE_TOP, 1e9
        for tid in ids:
            shape = shapes[tid]
            d = shape.distance(p)
            if d < dist:
                best, dist = tops[tid], d
            if d == 0:
                break
        return best + 0.06

    for c in data["continents"]:
        shape = unary_union([shapes[i] for i in c["territories"]])
        band = shape.buffer(-GAP - 0.2, join_style="mitre").difference(shape.buffer(-GAP - 2.6, join_style="mitre"))
        band = band.difference(channel)
        edge = MeshBuilder()
        for p in parts(shapely.segmentize(band.simplify(0.2), 2.0), 0.5):
            edge.prism(p, 0, None, top_z=lambda x, y, ids=c["territories"]: top_at(x, y, ids))
        obj = edge.to_object(f"Edge_{c['id']:02d}", flat_material(f"Edge_{c['id']:02d}", GOLD, roughness=0.4, metallic=0.3))
        obj["ContinentId"] = c["id"]

    print(f"ground triangles {stats['ground']}, prop triangles {stats['props']}")
    return land


# ---------------------------------------------------------------- export and preview


def export(out_dir):
    path = os.path.join(out_dir, "board.fbx")
    bpy.ops.export_scene.fbx(
        filepath=path,
        use_selection=False,
        object_types={"MESH"},
        apply_scale_options="FBX_SCALE_UNITS",
        axis_forward="-Z",
        axis_up="Y",
        mesh_smooth_type="FACE",
        use_triangles=True,
        path_mode="COPY",
        embed_textures=True,
    )
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out_dir, "board.blend"))
    print("wrote", path)


def preview(out_dir, land):
    scene = bpy.context.scene
    sea = bpy.data.meshes.new("PreviewSea")
    s = 1000
    sea.from_pydata([(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)], [], [(0, 1, 2, 3)])
    sea_obj = bpy.data.objects.new("PreviewSea", sea)
    sea_obj.data.materials.append(flat_material("PreviewSea", "2a6f9e", roughness=0.25))
    scene.collection.objects.link(sea_obj)
    shallow = MeshBuilder()
    for p in parts(land.buffer(14).difference(land.buffer(-1)), 1):
        shallow.prism(p.simplify(0.5), 0.05, None)
    shallow.to_object("PreviewShallows", flat_material("PreviewShallows", "56b7bf", roughness=0.25))

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 3.2
    sun.data.angle = math.radians(8)
    sun.rotation_euler = (math.radians(42), math.radians(-18), math.radians(35))
    scene.collection.objects.link(sun)
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.55, 0.65, 0.8, 1)
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.7

    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 24
    scene.cycles.use_denoising = False
    scene.render.resolution_x, scene.render.resolution_y = 1600, 1000
    scene.view_settings.view_transform = "Standard"

    cam = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
    cam.data.clip_end = 5000
    scene.collection.objects.link(cam)
    scene.camera = cam
    shots = {
        "preview_top.png": dict(ortho=True, loc=(0, 0, 600), rot=(0, 0, 0), scale=1560),
        "preview_tilt.png": dict(ortho=False, loc=(40, -1060, 900), rot=(math.radians(44), 0, 0), lens=30),
        "preview_close.png": dict(ortho=False, loc=(-260, -40, 120), rot=(math.radians(58), 0, math.radians(-20)), lens=32),
    }
    for name, s in shots.items():
        cam.data.type = "ORTHO" if s["ortho"] else "PERSP"
        if s["ortho"]:
            cam.data.ortho_scale = s["scale"]
        else:
            cam.data.lens = s["lens"]
        cam.location = s["loc"]
        cam.rotation_euler = s["rot"]
        scene.render.filepath = os.path.join(out_dir, name)
        bpy.ops.render.render(write_still=True)
        print("rendered", name)
    for name in ("PreviewSea", "PreviewShallows", "Sun", "Camera"):
        bpy.data.objects.remove(bpy.data.objects[name], do_unlink=True)


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=os.path.join(ROOT, "assets", "map", "map_data.json"))
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "blender"))
    ap.add_argument("--render", action="store_true")
    args = ap.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    data = json.load(open(args.data, encoding="utf-8"))
    land = build(data, args.out)
    if args.render:
        preview(args.out, land)
    export(args.out)


if __name__ == "__main__":
    main()
