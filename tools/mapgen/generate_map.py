"""Generate the Risk-style strategy map structure.

Outputs (in --out, default assets/map/v2):
  map_structure.svg / .png            flat terrain colours + small terrain symbols
  map_structure_numbered.svg / .png   same, with each territory's id at its center
  map_data.json                       territories, continents, rivers, sea routes

The map is built in steps:
  1. Coastline: hand-placed control points (shape inspired by Warring States
     China: Liaodong + Bohai gulf in the north-east, Shandong peninsula on the
     east coast, ragged south coast), roughened with midpoint displacement.
  2. Fine cells: a dense random Voronoi diagram clipped to the land.
  3. Rivers: shortest paths along fine-cell edges through waypoints, so every
     river runs on cell edges and therefore on territory borders.
  4. Territories: 136 mainland territories grown from evenly spaced seeds
     over the fine cells, plus two islands of two territories each. Growth
     is weighted by terrain (mountains small, plains large).
  5. Terrain, resources, continents and names. Mountain territories are
     spread so every part of the map has some within reach, each holds only
     1-3 small peaks, and each has a quarry or a mine. Then validation: any
     failed check discards the attempt and retries with the next seed.

The coastline, islands and islets always come from LAND_SEED, so every map
shares one landmass and only the territories change between seeds.

Usage: python generate_map.py [--seed N] [--out DIR]
"""

from __future__ import annotations

import argparse
import heapq
import json
import math
import os
from dataclasses import dataclass, field

import cairosvg
import numpy as np
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra
from scipy.spatial import Voronoi
from shapely.geometry import LineString, MultiPolygon, Point, Polygon
from shapely.ops import linemerge, nearest_points, polygonize, polylabel, split, unary_union
from shapely.strtree import STRtree

W, H = 3072, 2048
MAINLAND_TERRITORIES = 136
ISLAND_TERRITORIES = 4  # two islands, split in two
TOTAL_TERRITORIES = MAINLAND_TERRITORIES + ISLAND_TERRITORIES
CELL_SPACING = 17
# The landmass of the first 70-territory board; the Blender board uses it too.
LAND_SEED = 67

CONTINENT_COUNT = (18, 22)
NEUTRAL_COUNT = (50, 62)
CONTINENT_SIZES = [2, 3, 3, 4, 4, 4, 5, 5, 5]
# A mountain continent bigger than this would read as one mountain range.
MAX_MOUNTAIN_CONTINENT = 3
# Every territory is at most this many steps from a mountain territory.
MOUNTAIN_REACH = 2
LAKES = 3

TERRAINS = ["mountain", "plateau", "plains", "valley", "desert", "forest", "lake"]
CONTINENT_THEMES = ["mountain", "plateau", "plains", "valley", "desert", "forest"]
HARD_THEMES = {"mountain", "plateau"}

# Relative target area per dominant terrain: mountains/plateaus small,
# plains/deserts/valleys large.
TERRAIN_WEIGHT = {
    "mountain": 0.8,
    "plateau": 0.85,
    "forest": 1.0,
    "lake": 1.0,
    "valley": 1.2,
    "plains": 1.3,
    "desert": 1.32,
}

# Secondary terrain that may appear inside a territory, per dominant terrain.
SECONDARY = {
    "mountain": ["plateau", "valley"],
    "plateau": ["mountain", "desert", "valley"],
    "plains": ["mountain", "valley", "plateau"],
    "valley": ["mountain", "plains"],
    "desert": ["mountain", "plateau"],
    "forest": ["mountain", "valley", "plains"],
    "lake": ["plains", "valley"],
}

COLORS = {
    "mountain": "#ab9d8a",
    "plateau": "#d8b98a",
    "plains": "#c6dd92",
    "valley": "#a2d08a",
    "desert": "#eedca2",
    "forest": "#80b472",
    "lake": "#b4dccf",
}

# Coastline control points, normalised (x, y) with y measured north->south
# before the vertical squeeze in to_px(). Clockwise from the north-west.
COAST = [
    (0.07, 0.24), (0.11, 0.16), (0.18, 0.15), (0.22, 0.10), (0.30, 0.12), (0.37, 0.07),
    (0.44, 0.11), (0.50, 0.09), (0.57, 0.05), (0.63, 0.10), (0.69, 0.07), (0.75, 0.09),
    # Liaodong: lobe to the north-east, peninsula tip pointing south-west
    (0.82, 0.04), (0.90, 0.07), (0.94, 0.14), (0.90, 0.17), (0.86, 0.22), (0.84, 0.25),
    # Bohai gulf, opening wide to the east between Liaodong and Shandong
    (0.81, 0.21), (0.78, 0.17), (0.74, 0.18), (0.71, 0.23), (0.72, 0.29),
    # Shandong peninsula jutting east
    (0.78, 0.33), (0.85, 0.33), (0.93, 0.36), (0.92, 0.41), (0.86, 0.42), (0.81, 0.44),
    (0.78, 0.47),
    # East coast down to the Yangtze mouth and the south-east
    (0.80, 0.52), (0.84, 0.57), (0.81, 0.62), (0.82, 0.68), (0.78, 0.72), (0.76, 0.78),
    (0.71, 0.80),
    # Ragged south coast with a peninsula and a few bays
    (0.67, 0.86), (0.63, 0.84), (0.60, 0.88), (0.56, 0.95), (0.53, 0.88), (0.48, 0.86),
    (0.44, 0.90), (0.39, 0.84), (0.34, 0.86), (0.30, 0.92), (0.26, 0.86), (0.21, 0.87),
    (0.16, 0.82), (0.12, 0.84),
    # West coast
    (0.08, 0.76), (0.10, 0.70), (0.05, 0.64), (0.07, 0.56), (0.11, 0.51), (0.06, 0.46),
    (0.04, 0.38), (0.08, 0.31),
]

# Waypoints are in the same normalised space as COAST.
YELLOW_RIVER = [(0.13, 0.36), (0.26, 0.33), (0.32, 0.17), (0.45, 0.15), (0.50, 0.33), (0.62, 0.38), (0.73, 0.31)]
YANGTZE = [(0.11, 0.62), (0.26, 0.64), (0.40, 0.58), (0.53, 0.65), (0.67, 0.59), (0.83, 0.57)]

# Playable islands (final pixel-space fractions) and decorative islets.
ISLANDS = [(0.93, 0.60, 118), (0.44, 0.905, 112)]
ISLETS = [(0.965, 0.29, 22), (0.56, 0.935, 16), (0.04, 0.86, 20), (0.025, 0.47, 14), (0.62, 0.035, 15), (0.30, 0.94, 12)]

TERRITORY_NAMES = [
    "شيانيانغ", "يونغ", "هاندان", "داليانغ", "لينزي", "ينغ", "جيتشنغ", "شينتشنغ", "لويي", "آنيي",
    "جينيانغ", "داي", "يانمن", "يونتشونغ", "شانغدانغ", "هيدونغ", "هانتشونغ", "تشنغدو", "با", "نانيانغ",
    "تشانغشا", "كوايجي", "وو", "يويه", "شويتشون", "تشن", "تساي", "سونغ", "لو", "جيمو",
    "لانغيا", "جيانغلينغ", "ييلينغ", "شانغيونغ", "تشانغبينغ", "غوانتشونغ", "هانغو", "ووغوان", "لانتيان", "بيدي",
    "لونغشي", "شانغجون", "جيوجيانغ", "يوجانغ", "دونغهاي", "سيشوي", "بنغتشنغ", "شيويه", "تينغ", "جو",
    "لياودونغ", "لياوشي", "يويانغ", "يوبيبينغ", "شانغغو", "تشونغشان", "جولو", "دونغجون", "ينغتشوان", "سانتشوان",
    "هينيي", "تاييوان", "بوهاي", "تشينغخه", "دونغتينغ", "تسانغوو", "غويلين", "نانهاي",
    "شو", "خهجيان", "نانجون", "تشيانجونغ", "جيبي", "دانغجون", "جيويوان", "خنغشان", "مينجونغ", "شيانغ",
    "شينجنغ", "يانغجاي", "بينغيانغ", "بويانغ", "دينغتاو", "تشوفو", "وانتشنغ", "شانغتشيو", "شينغيانغ", "آوتسانغ",
    "تشانغيي", "بينغين", "فانيانغ", "غوسو", "مولينغ", "غوانغلينغ", "شيابي", "هوايين", "دانيانغ", "يوهانغ",
    "لينهواي", "خهفي", "لوجيانغ", "شونيانغ", "إيتشنغ", "شياكو", "شيانغيانغ", "ييانغ", "وولينغ", "لينغلينغ",
    "غويانغ", "خنغيانغ", "يهلانغ", "ديان", "تسانغكه", "بادونغ", "فولينغ", "لانغجونغ", "تيانشوي", "ديداو",
    "آندينغ", "شيخه", "جانغيه", "يولين", "شوفانغ", "وويوان", "بينغتشنغ", "جينان", "لونغمن", "تونغغوان",
    "وينان", "لينتونغ", "تشنتسانغ", "جيتينغ", "تشيشان", "فنيانغ", "بينغياو", "ليشي", "هوكو", "تشاوغه",
    "مويه", "هولاو", "غاومي", "ييدو",
]
ISLAND_NAMES = ["بنغلاي", "ينغتشو", "فانغجانغ", "دايو"]

CONTINENT_NAMES = {
    "mountain": ["قمم تاي شان", "جبال هوا شان", "مرتفعات تايهانغ", "جبال تشينلينغ", "سلسلة يانشان", "جبال داباشان"],
    "plateau": ["هضبة اللوس", "نجد أوردوس", "هضبة لونغيو", "هضبة شانغلو", "نجد هيشي", "هضبة يونقوي"],
    "plains": ["السهول الوسطى", "سهول هوايبي", "سهول تشي", "سهول هيبي", "سهول جيانغهان", "سهول هواي"],
    "valley": ["وادي وي", "وادي فن", "وادي هان", "وادي لوه", "وادي جينغ", "وادي يي"],
    "desert": ["صحراء مو أوس", "كثبان هيتاو", "رمال يونتشونغ", "قفار جيوتشيوان", "رمال تنغر", "قفار جويان"],
    "forest": ["غابات تشو", "غابات با شو", "أحراش وو يويه", "غابات يونمنغ", "أحراش يوان", "غابات مينيويه"],
}


def to_px(p):
    """Normalised coast space -> pixels. Squeezes y so the south has room for an island."""
    x, y = p
    return (x * W, (0.035 + 0.84 * y) * H)


def roughen(points, rng, depth, rough):
    """Midpoint displacement on a closed polyline."""
    pts = list(points)
    for level in range(depth):
        out = []
        amp = rough * (0.62**level)
        for i in range(len(pts)):
            a = np.array(pts[i])
            b = np.array(pts[(i + 1) % len(pts)])
            d = b - a
            n = np.array([-d[1], d[0]])
            mid = (a + b) / 2 + n * rng.uniform(-amp, amp)
            out += [tuple(a), tuple(mid)]
        pts = out
    return pts


def clean_polygon(poly):
    poly = poly.buffer(0)
    if isinstance(poly, MultiPolygon):
        poly = max(poly.geoms, key=lambda g: g.area)
    return Polygon(poly.exterior)


def make_island(cx, cy, r, rng, depth=4):
    k = 12
    pts = []
    for i in range(k):
        a = 2 * math.pi * i / k
        rr = r * rng.uniform(0.75, 1.2)
        pts.append((cx + rr * math.cos(a), cy + rr * 0.85 * math.sin(a)))
    return clean_polygon(Polygon(roughen(pts, rng, depth, 0.18)))


def smooth_noise(rng):
    """A smooth scalar field in roughly [-1, 1] built from a few sine waves."""
    waves = []
    for _ in range(5):
        ang = rng.uniform(0, 2 * math.pi)
        wl = rng.uniform(260, 700)
        waves.append((math.cos(ang) * 2 * math.pi / wl, math.sin(ang) * 2 * math.pi / wl, rng.uniform(0, 2 * math.pi)))

    def f(x, y):
        return sum(math.sin(kx * x + ky * y + ph) for kx, ky, ph in waves) / len(waves) * 1.8

    return f


class Failed(Exception):
    pass


@dataclass
class Territory:
    id: int = 0
    cells: list = field(default_factory=list)
    polygon: Polygon | None = None
    terrains: list = field(default_factory=list)
    resources: list = field(default_factory=list)
    continent: int | None = None
    neighbors: set = field(default_factory=set)
    center: tuple = (0.0, 0.0)
    coastal: bool = False
    island: bool = False
    name: str = ""
    size: str = ""
    symbols: list = field(default_factory=list)


# --------------------------------------------------------------------------
# Geometry
# --------------------------------------------------------------------------


def build_land():
    rng = np.random.default_rng(LAND_SEED)
    mainland = clean_polygon(Polygon(roughen([to_px(p) for p in COAST], rng, 6, 0.3)))
    islands = [make_island(x * W, y * H, r, rng) for x, y, r in ISLANDS]
    islets = [make_island(x * W, y * H, r, rng, depth=3) for x, y, r in ISLETS]
    for shape in islands + islets:
        if shape.distance(mainland) < 60:
            raise Failed("island too close to mainland")
    return mainland, islands, islets


def split_island(isl, rng):
    """Cut an island across its long axis with a slightly wavy line."""
    rect = list(isl.minimum_rotated_rectangle.exterior.coords)[:4]
    e0 = np.subtract(rect[1], rect[0])
    e1 = np.subtract(rect[2], rect[1])
    axis = e0 if np.hypot(*e0) >= np.hypot(*e1) else e1
    axis = axis / np.hypot(*axis)
    across = np.array([-axis[1], axis[0]])
    c = np.array(isl.centroid.coords[0])
    for _ in range(40):
        mid = c + axis * rng.uniform(-8, 8)
        pts = [mid + across * t + axis * rng.uniform(-9, 9) for t in np.linspace(-1, 1, 7) * 400]
        halves = sorted(split(isl, LineString(pts)).geoms, key=lambda g: -g.area)
        if len(halves) == 2 and halves[1].area / halves[0].area > 0.82:
            return [Polygon(h.exterior) for h in halves]
    raise Failed("could not split island")


def build_cells(mainland, rng):
    minx, miny, maxx, maxy = mainland.bounds
    xs = np.arange(minx - 60, maxx + 60, CELL_SPACING)
    ys = np.arange(miny - 60, maxy + 60, CELL_SPACING)
    gx, gy = np.meshgrid(xs, ys)
    pts = np.stack([gx.ravel(), gy.ravel()], axis=1)
    pts += rng.uniform(-0.45, 0.45, pts.shape) * CELL_SPACING
    frame = [(-W, -H), (2 * W, -H), (-W, 2 * H), (2 * W, 2 * H), (W / 2, -H), (W / 2, 2 * H), (-W, H / 2), (2 * W, H / 2)]
    pts = np.vstack([pts, frame])
    vor = Voronoi(pts)

    reach = mainland.buffer(CELL_SPACING * 2)
    cell_of_point = {}
    polys = []
    for i in range(len(pts) - len(frame)):
        if not reach.contains(Point(pts[i])):
            continue
        region = vor.regions[vor.point_region[i]]
        if -1 in region or not region:
            continue
        poly = Polygon(vor.vertices[region])
        if not poly.intersects(mainland):
            continue
        clipped = poly.intersection(mainland)
        if isinstance(clipped, MultiPolygon):
            clipped = max(clipped.geoms, key=lambda g: g.area)
        if not isinstance(clipped, Polygon) or clipped.area < 4:
            continue
        cell_of_point[i] = len(polys)
        polys.append(clipped)

    n = len(polys)
    adj = [set() for _ in range(n)]
    ridge_cells = {}
    for (a, b), rv in zip(vor.ridge_points, vor.ridge_vertices):
        if a in cell_of_point and b in cell_of_point:
            ca, cb = cell_of_point[a], cell_of_point[b]
            if polys[ca].intersection(polys[cb]).length > 0.5:
                adj[ca].add(cb)
                adj[cb].add(ca)
                if -1 not in rv:
                    ridge_cells[frozenset(rv)] = (ca, cb)
    centroids = np.array([[p.centroid.x, p.centroid.y] for p in polys])
    areas = np.array([p.area for p in polys])
    return vor, polys, adj, ridge_cells, centroids, areas, cell_of_point


# --------------------------------------------------------------------------
# Territories
# --------------------------------------------------------------------------


def kmeans_seeds(centroids, areas, k, rng):
    idx = rng.choice(len(centroids), k, replace=False)
    c = centroids[idx].copy()
    for _ in range(40):
        d = ((centroids[:, None, :] - c[None, :, :]) ** 2).sum(-1)
        lab = d.argmin(1)
        for j in range(k):
            m = lab == j
            if m.any():
                c[j] = (centroids[m] * areas[m, None]).sum(0) / areas[m].sum()
    return c


def assign_nearest(centroids, seeds):
    d = ((centroids[:, None, :] - seeds[None, :, :]) ** 2).sum(-1)
    return d.argmin(1)


def region_graph(labels, adj, k, min_touch=1):
    """Regions that touch along at least `min_touch` fine-cell pairs."""
    touch = {}
    for a, nbrs in enumerate(adj):
        for b in nbrs:
            if labels[a] != labels[b] and labels[a] >= 0 and labels[b] >= 0:
                key = (labels[a], labels[b])
                touch[key] = touch.get(key, 0) + 1
    g = [set() for _ in range(k)]
    for (a, b), n in touch.items():
        if n >= min_touch:
            g[a].add(b)
    return g


def grow(seeds, weights, centroids, areas, adj, rng):
    """Grow territories over fine cells, keeping area roughly proportional to weight."""
    n, k = len(centroids), len(seeds)
    noise = smooth_noise(rng)
    owner = np.full(n, -1)
    area = np.zeros(k)
    members = [set() for _ in range(k)]
    heaps = [[] for _ in range(k)]

    def score(r, c):
        x, y = centroids[c]
        return math.hypot(x - seeds[r][0], y - seeds[r][1]) * (1 + 0.45 * noise(x, y))

    def claim(r, c):
        owner[c] = r
        members[r].add(c)
        area[r] += areas[c]
        for nb in adj[c]:
            if owner[nb] < 0:
                heapq.heappush(heaps[r], (score(r, nb), nb))

    start = assign_nearest(np.array(seeds), centroids)  # nearest cell per seed
    for r in range(k):
        c = int(start[r])
        if owner[c] >= 0:
            raise Failed("two seeds share a cell")
        claim(r, c)
    active = [(area[r] / weights[r], r) for r in range(k)]
    heapq.heapify(active)
    while active:
        _, r = heapq.heappop(active)
        h = heaps[r]
        while h:
            _, c = heapq.heappop(h)
            if owner[c] < 0:
                claim(r, c)
                heapq.heappush(active, (area[r] / weights[r], r))
                break
    # Cells no territory reached (rare slivers) join any neighbour.
    for _ in range(50):
        left = np.where(owner < 0)[0]
        if not len(left):
            break
        for c in left:
            for nb in adj[c]:
                if owner[nb] >= 0:
                    claim(owner[nb], c)
                    break
    if (owner < 0).any():
        raise Failed(f"unassigned cells: {int((owner < 0).sum())}")
    balance(owner, members, area, weights, adj, areas)
    return owner


def connected_without(cells, drop, adj):
    rest = cells - {drop}
    if not rest:
        return False
    start = next(iter(rest))
    seen, stack = {start}, [start]
    while stack:
        x = stack.pop()
        for nb in adj[x]:
            if nb in rest and nb not in seen:
                seen.add(nb)
                stack.append(nb)
    return len(seen) == len(rest)


def balance(owner, members, area, weights, adj, areas, rounds=8000):
    """Hand border cells from territories that are too big for their terrain
    to smaller neighbours, so sizes follow the terrain weights closely."""
    w = np.array(weights)
    for _ in range(rounds):
        norm = area / w
        mean = norm.mean()
        order = np.argsort(-norm)
        moved = False
        for r in order[:6]:
            if norm[r] < mean * 1.08:
                break
            # Border cells of r and the neighbour territory that would take them.
            options = []
            for c in members[r]:
                for s in {owner[nb] for nb in adj[c]} - {r}:
                    touch = sum(1 for nb in adj[c] if owner[nb] == s)
                    if touch >= 2 and norm[s] < norm[r] - areas[c] / w[r]:
                        options.append((-touch, norm[s], c, s))
            for _, _, c, s in sorted(options):
                if connected_without(members[r], c, adj):
                    members[r].discard(c)
                    members[s].add(c)
                    owner[c] = s
                    area[r] -= areas[c]
                    area[s] += areas[c]
                    moved = True
                    break
            if moved:
                break
        if not moved:
            # Nothing too big left to shrink; grow the smallest instead.
            r = int(np.argmin(norm))
            if norm[r] > mean * 0.9:
                return
            options = []
            for c in members[r]:
                for nb in adj[c]:
                    s = owner[nb]
                    touch = sum(1 for x in adj[nb] if owner[x] == r)
                    if s != r and touch >= 2 and norm[s] > norm[r] + areas[nb] / w[r]:
                        options.append((-touch, -norm[s], nb, s))
            for _, _, c, s in sorted(options):
                if connected_without(members[s], c, adj):
                    members[s].discard(c)
                    members[r].add(c)
                    owner[c] = r
                    area[s] -= areas[c]
                    area[r] += areas[c]
                    moved = True
                    break
            if not moved:
                return


def pick_continents(graph, k, rng):
    """Choose continents of 2-5 adjacent territories. Growth can later cut a
    member off, so aim a couple of territories above the neutral range."""
    lo, hi = CONTINENT_COUNT
    for _ in range(400):
        count = int(rng.integers(lo, hi + 1))
        sizes = [int(rng.choice(CONTINENT_SIZES)) for _ in range(count)]
        total = sum(sizes)
        if not (TOTAL_TERRITORIES - NEUTRAL_COUNT[1] + 7 <= total <= TOTAL_TERRITORIES - NEUTRAL_COUNT[0] + 7):
            continue
        cont = [-1] * k
        ok = True
        for ci, size in enumerate(sizes):
            # Seed far from existing continents so they spread over the map.
            free = [r for r in range(k) if cont[r] < 0 and all(cont[nb] < 0 for nb in graph[r])]
            free = free or [r for r in range(k) if cont[r] < 0]
            if not free:
                ok = False
                break
            r0 = int(rng.choice(free))
            group = [r0]
            cont[r0] = ci
            while len(group) < size:
                cand = {nb for g in group for nb in graph[g] if cont[nb] < 0}
                cand = [c for c in cand if all(cont[x] in (-1, ci) for x in graph[c])] or list(cand)
                if not cand:
                    break
                c = int(rng.choice(sorted(cand)))
                cont[c] = ci
                group.append(c)
            if len(group) != size:
                ok = False
                break
        if ok:
            return cont, count
    raise Failed("could not place continents")


def pick_terrains(graph, cont, n_cont, rng):
    k = len(graph)
    cont_graph = [set() for _ in range(n_cont)]
    for r in range(k):
        for nb in graph[r]:
            if cont[r] >= 0 and cont[nb] >= 0 and cont[r] != cont[nb]:
                cont_graph[cont[r]].add(cont[nb])
    themes = [None] * n_cont
    pool = []
    while len(pool) < n_cont:
        pool += list(rng.permutation(CONTINENT_THEMES))
    pool = pool[:n_cont]
    size = [sum(1 for c in cont if c == ci) for ci in range(n_cont)]
    for ci in sorted(range(n_cont), key=lambda c: -size[c]):
        options = [t for t in pool if all(themes[o] != t for o in cont_graph[ci])] or pool
        if size[ci] > MAX_MOUNTAIN_CONTINENT:
            options = [t for t in options if t != "mountain"] or [t for t in pool if t != "mountain"] or options
        t = options[int(rng.integers(len(options)))]
        themes[ci] = t
        pool.remove(t)

    primary = [None] * k
    for r in range(k):
        if cont[r] >= 0:
            primary[r] = themes[cont[r]]
    lakes_left = LAKES
    for r in rng.permutation(k):
        if primary[r] is not None:
            continue
        near = {primary[nb] for nb in graph[r] if primary[nb]}
        if lakes_left and "lake" not in near and rng.random() < 0.08:
            primary[r] = "lake"
            lakes_left -= 1
            continue
        opts = [t for t in CONTINENT_THEMES if t not in near] or CONTINENT_THEMES
        primary[r] = opts[int(rng.integers(len(opts)))]
    return primary, themes


def detail_terrain(t, in_continent, rng):
    primary = t.terrains[0]
    extra_n = int(rng.choice([0, 0, 1], p=None)) if in_continent else int(rng.choice([0, 1, 1, 2]))
    extras = list(rng.permutation(SECONDARY[primary]))[:extra_n]
    t.terrains = [primary] + extras
    res = []
    if primary == "forest" or rng.random() < (0.12 if in_continent else 0.28):
        res.append("forest")
    if primary == "lake" or rng.random() < (0.1 if in_continent else 0.22):
        res.append("pond")
    # Stone and gold come out of the hills: every mountain territory has a
    # quarry or a mine (now and then both), some plateaus a quarry.
    if primary == "mountain":
        res += [["quarry"], ["mine"], ["quarry", "mine"]][int(rng.choice(3, p=[0.42, 0.42, 0.16]))]
    elif primary == "plateau" and rng.random() < 0.3:
        res.append("quarry")
    t.resources = res



def chaikin(coords, iterations=3, closed=False):
    """Corner-cutting smoothing. Open chains keep their end points fixed so
    neighbouring chains still meet exactly at junctions."""
    pts = np.asarray(coords, float)
    for _ in range(iterations):
        if closed:
            a, b = pts, np.roll(pts, -1, axis=0)
            out = np.empty((2 * len(a), 2))
            out[0::2] = 0.75 * a + 0.25 * b
            out[1::2] = 0.25 * a + 0.75 * b
            pts = out
        else:
            if len(pts) < 3:
                return pts
            a, b = pts[:-1], pts[1:]
            mid = np.empty((2 * len(a), 2))
            mid[0::2] = 0.75 * a + 0.25 * b
            mid[1::2] = 0.25 * a + 0.75 * b
            pts = np.vstack([pts[:1], mid[1:-1], pts[-1:]])
    return pts


def smooth_territories(raw):
    """Smooth every border once (shared borders stay shared) and rebuild the
    territory polygons from the smoothed border network. Returns the polygons
    and the smoothed border chains."""
    merged = linemerge(unary_union([p.exterior for p in raw]))
    chains = list(merged.geoms) if hasattr(merged, "geoms") else [merged]
    smooth = []
    for c in chains:
        coords = np.array(c.coords)
        if c.is_ring:
            sc = chaikin(coords[:-1], 3, closed=True)
            smooth.append(LineString(np.vstack([sc, sc[:1]])).simplify(0.6))
        else:
            # Douglas-Peucker keeps the end points, so junctions stay shared.
            smooth.append(LineString(chaikin(coords, 3)).simplify(0.6))
    faces = list(polygonize(unary_union(smooth)))
    tree = STRtree(raw)
    pieces = [[] for _ in raw]
    for f in faces:
        idx = list(tree.query(f))
        if not idx:
            continue
        best = max(idx, key=lambda i: raw[i].intersection(f).area)
        if raw[best].intersection(f).area > 0.3 * f.area:
            pieces[best].append(f)
    out = []
    for ps in pieces:
        if not ps:
            raise Failed("smoothing lost a territory")
        poly = unary_union(ps)
        if isinstance(poly, MultiPolygon):
            poly = max(poly.geoms, key=lambda g: g.area)
        out.append(Polygon(poly.exterior))
    return out, smooth


class ChainGraph:
    """Graph of smoothed inland borders: nodes are border junctions, edges are
    the border chains between them. Rivers walk this graph, so they always run
    exactly on territory borders."""

    def __init__(self, chains, land):
        self.coast = land.exterior
        self.key = {}
        self.pts = []
        self.edges = []  # (u, v, line)
        coast_buf = self.coast.buffer(0.8)
        for c in chains:
            if c.is_ring or c.difference(coast_buf).length < 1:
                continue  # coastline, not a border between two territories
            u, v = self._node(c.coords[0]), self._node(c.coords[-1])
            if u != v:
                self.edges.append((u, v, c))
        self.pts = np.array(self.pts)
        self.on_coast = np.array([self.coast.distance(Point(p)) < 0.8 for p in self.pts])
        self.near_coast = [c.distance(self.coast) for _, _, c in self.edges]

    def _node(self, xy):
        k = (round(xy[0], 2), round(xy[1], 2))
        if k not in self.key:
            self.key[k] = len(self.pts)
            self.pts.append(xy)
        return self.key[k]

    def _matrix(self, avoid_nodes, coast_ok):
        n = len(self.pts)
        rows, cols, w = [], [], []
        for i, (u, v, c) in enumerate(self.edges):
            cost = c.length
            if u in avoid_nodes or v in avoid_nodes:
                cost *= 400
            if self.near_coast[i] < 70 and not (u in coast_ok or v in coast_ok):
                cost *= 6
            rows += [u, v]
            cols += [v, u]
            w += [cost, cost]
        return csr_matrix((w, (rows, cols)), shape=(n, n))

    def _nearest(self, p, coast=False, among=None):
        d = np.hypot(self.pts[:, 0] - p[0], self.pts[:, 1] - p[1])
        if coast:
            d = np.where(self.on_coast, d, np.inf)
        else:
            d = np.where(self.on_coast, np.inf, d)
        if among is not None:
            mask = np.zeros(len(d), bool)
            mask[list(among)] = True
            d = np.where(mask, d, np.inf)
        return int(np.argmin(d))

    @staticmethod
    def _walk(pred, a, b):
        seg, cur = [], b
        while cur != a:
            if cur < 0:
                raise Failed("river waypoint unreachable")
            seg.append(int(cur))
            cur = pred[cur]
        return seg[::-1]

    def trace(self, waypoints, avoid):
        """Cheapest border path from the source to the mouth, where each border
        chain costs more the further it strays from the guide line."""
        guide = LineString([to_px(p) for p in waypoints])
        start = self._nearest(to_px(waypoints[0]))
        mouth = self._nearest(to_px(waypoints[-1]), coast=True)
        near_mouth = {i for i, p in enumerate(self.pts) if np.hypot(*(p - self.pts[mouth])) < 200}
        n = len(self.pts)
        rows, cols, w = [], [], []
        for i, (u, v, c) in enumerate(self.edges):
            stray = guide.distance(c.interpolate(0.5, normalized=True))
            cost = c.length * (1 + (stray / 70.0) ** 2)
            if u in avoid or v in avoid:
                cost *= 400
            if self.near_coast[i] < 70 and not (u in near_mouth or v in near_mouth):
                cost *= 6
            rows += [u, v]
            cols += [v, u]
            w += [cost, cost]
        mat = csr_matrix((w, (rows, cols)), shape=(n, n))
        _, pred = dijkstra(mat, indices=start, return_predecessors=True)
        return [start] + self._walk(pred, start, mouth)

    def tributary(self, body, taken, rng):
        inland = [i for i in range(len(self.pts)) if not self.on_coast[i]]
        bodypts = self.pts[body]
        for _ in range(100):
            v = int(rng.choice(inland))
            d = np.hypot(bodypts[:, 0] - self.pts[v][0], bodypts[:, 1] - self.pts[v][1]).min()
            far = all(np.hypot(*(self.pts[v] - self.pts[t])) > 180 for t in taken)
            if 220 < d < 420 and self.coast.distance(Point(self.pts[v])) > 160 and far:
                mat = self._matrix(taken - set(body), set())
                dist, pred = dijkstra(mat, indices=v, return_predecessors=True)
                end = body[int(np.argmin(dist[body]))]
                if not np.isfinite(dist[end]) or dist[end] > 2.0 * d:
                    continue
                path = [v] + self._walk(pred, v, end)
                if set(path[:-1]) & taken:
                    continue
                return path
        return None

    def line(self, path, to_sea):
        lookup = {}
        for u, v, c in self.edges:
            lookup[(u, v)] = list(c.coords)
            lookup[(v, u)] = list(c.coords)[::-1]
        coords = []
        for u, v in zip(path, path[1:]):
            seg = lookup[(u, v)]
            coords += seg if not coords else seg[1:]
        if to_sea:
            # Carry the river a little past the coast, continuing its last heading.
            (x0, y0), (x1, y1) = coords[-6] if len(coords) > 6 else coords[0], coords[-1]
            norm = math.hypot(x1 - x0, y1 - y0) or 1.0
            coords.append((x1 + (x1 - x0) / norm * 45, y1 + (y1 - y0) / norm * 45))
        return LineString(coords)


# --------------------------------------------------------------------------
# Build + validate
# --------------------------------------------------------------------------


def hops_from(terr, sources):
    """Steps from every territory to the nearest of `sources` (land or sea)."""
    dist = {r: 0 for r in sources}
    queue = list(sources)
    for x in queue:
        for nb in terr[x].neighbors:
            if nb not in dist:
                dist[nb] = dist[x] + 1
                queue.append(nb)
    return [dist.get(r, 99) for r in range(len(terr))]


def mountain_patch(terr, r):
    """Size of the mountain patch `r` would join if it became a mountain."""
    comp, stack = {r}, [r]
    while stack:
        x = stack.pop()
        for nb in terr[x].neighbors:
            if nb not in comp and terr[nb].terrains[0] == "mountain":
                comp.add(nb)
                stack.append(nb)
    return len(comp)


def spread_mountains(terr, small_area, rng):
    """Turn neutral territories into mountains where the map has none nearby,
    until every territory is within MOUNTAIN_REACH steps of a mountain. New
    mountains never touch another mountain, so ranges stay small."""
    while True:
        mountains = [r for r, t in enumerate(terr) if t.terrains[0] == "mountain"]
        dist = hops_from(terr, mountains)
        if max(dist) <= MOUNTAIN_REACH:
            return
        # The territory furthest from any mountain decides where to add one:
        # any free neutral territory close enough to bring it within reach.
        far = max(range(len(terr)), key=lambda r: (dist[r], -terr[r].polygon.area))
        near_far = hops_from(terr, [far])
        cands = [r for r in range(len(terr)) if near_far[r] <= MOUNTAIN_REACH]
        cands = [r for r in cands if terr[r].continent is None and terr[r].terrains[0] not in ("lake", "mountain")]
        apart = [r for r in cands if all(terr[nb].terrains[0] != "mountain" for nb in terr[r].neighbors)]
        cands = apart or [r for r in cands if mountain_patch(terr, r) <= MAX_MOUNTAIN_CONTINENT]
        if not cands:
            raise Failed("no room for a mountain")
        # Prefer the candidate that brings the most far-away territories in reach.
        def gain(r):
            d = hops_from(terr, mountains + [r])
            return (sum(1 for a, b in zip(dist, d) if a > MOUNTAIN_REACH >= b), terr[r].polygon.area < small_area)

        r = max(cands, key=gain)
        terr[r].terrains = ["mountain"]
        detail_terrain(terr[r], False, rng)


def build(seed):
    rng = np.random.default_rng(seed)
    mainland, islands, islets = build_land()
    vor, polys, adj, ridge_cells, centroids, areas, cell_of_point = build_cells(mainland, rng)

    k = MAINLAND_TERRITORIES
    seeds = kmeans_seeds(centroids, areas, k, rng)
    prelim = region_graph(assign_nearest(centroids, seeds), adj, k)
    # Continents only join regions with a long shared border, so growth is
    # less likely to cut a member off later.
    cont, n_cont = pick_continents(region_graph(assign_nearest(centroids, seeds), adj, k, min_touch=8), k, rng)
    primary, themes = pick_terrains(prelim, cont, n_cont, rng)

    weights = [TERRAIN_WEIGHT[primary[r]] for r in range(k)]
    owner = grow(seeds, weights, centroids, areas, adj, rng)

    terr = [Territory() for _ in range(TOTAL_TERRITORIES)]
    for c, r in enumerate(owner):
        terr[r].cells.append(c)
    for r in range(k):
        poly = unary_union([polys[c] for c in terr[r].cells])
        if not isinstance(poly, Polygon):
            raise Failed(f"territory {r} is not one piece")
        if len(poly.interiors):
            raise Failed(f"territory {r} has a hole")
        terr[r].polygon = poly
    smoothed, chains = smooth_territories([terr[r].polygon for r in range(k)])
    for r in range(k):
        terr[r].polygon = smoothed[r]

    # Rivers walk the smoothed borders, so they can never cut a territory.
    cg = ChainGraph(chains, unary_union(smoothed))
    yellow = cg.trace(YELLOW_RIVER, avoid=set())
    yangtze = cg.trace(YANGTZE, avoid=set(yellow))
    rivers = [("النهر الأصفر", cg.line(yellow, True), True), ("نهر اليانغتسي", cg.line(yangtze, True), True)]
    taken = set(yellow) | set(yangtze)
    for main in (yellow, yangtze, yellow):
        body = main[1:-2]
        trib = cg.tributary(body, taken, rng) if len(body) > 2 else None
        if trib:
            rivers.append(("رافد", cg.line(trib, False), False))
            taken |= set(trib)
    # Neighbours come from the smoothed shapes: two territories are neighbours
    # when they share a real stretch of border, not just a corner point.
    tree = STRtree(smoothed)
    for r in range(k):
        for q in tree.query(smoothed[r].buffer(1)):
            q = int(q)
            if q != r and smoothed[r].boundary.intersection(smoothed[q].boundary).length > 6:
                terr[r].neighbors.add(q)

    # Islands: two territories each, every half linked by a sea route to the
    # nearest coastal territory (a different one for each half).
    land_union = unary_union([t.polygon for t in terr[:k]])
    for r in range(k):
        terr[r].coastal = terr[r].polygon.boundary.intersection(land_union.exterior).length > 5
    sea_routes = []
    r = k
    for isl in islands:
        halves = split_island(isl, rng)
        pair = [r, r + 1]
        used = set()
        for h, half in zip(pair, halves):
            terr[h].polygon = half
            terr[h].island = True
            terr[h].coastal = True
            terr[h].neighbors.add(pair[1] if h == pair[0] else pair[0])
            near = sorted((half.distance(terr[q].polygon), q) for q in range(k) if terr[q].coastal and q not in used)
            q = near[0][1]
            used.add(q)
            terr[h].neighbors.add(q)
            terr[q].neighbors.add(h)
            sea_routes.append((h, q))
        r += 2
    # A territory left with a single land neighbour (a peninsula tip) gets a
    # sea route to the nearest coastal territory it does not already border.
    for r in range(k):
        if len(terr[r].neighbors) < 2 and terr[r].coastal:
            cands = sorted(
                (terr[r].polygon.distance(terr[q].polygon), q)
                for q in range(k)
                if q != r and terr[q].coastal and q not in terr[r].neighbors
            )
            if cands and cands[0][0] < 420:
                q = cands[0][1]
                terr[r].neighbors.add(q)
                terr[q].neighbors.add(r)
                sea_routes.append((r, q))
    for i in range(ISLAND_TERRITORIES):
        primary.append("plains")  # re-picked with the other neutral territories
        cont.append(-1)

    for r in range(TOTAL_TERRITORIES):
        terr[r].terrains = [primary[r]]
        detail_terrain(terr[r], cont[r] >= 0, rng)
        terr[r].continent = cont[r] if cont[r] >= 0 else None

    # Continents were chosen on the preliminary graph; growth can pull a
    # member away. Keep each continent's largest connected part, and the
    # members cut off become neutral.
    for ci in range(n_cont):
        mem = [r for r in range(k) if cont[r] == ci]
        best = []
        left = set(mem)
        while left:
            start = left.pop()
            comp, stack = {start}, [start]
            while stack:
                x = stack.pop()
                for nb in terr[x].neighbors:
                    if nb in left:
                        left.discard(nb)
                        comp.add(nb)
                        stack.append(nb)
            if len(comp) > len(best):
                best = sorted(comp)
        if len(best) < 2:
            best = []
        for r in mem:
            if r not in best:
                cont[r] = -1
                terr[r].continent = None
    used = sorted({c for c in cont if c >= 0})
    remap = {c: i for i, c in enumerate(used)}
    for r in range(TOTAL_TERRITORIES):
        terr[r].continent = remap[cont[r]] if cont[r] >= 0 else None
    themes = [themes[c] for c in used]
    n_cont = len(used)
    neutral = sum(1 for t in terr if t.continent is None)
    if not (CONTINENT_COUNT[0] <= n_cont <= CONTINENT_COUNT[1]) or not (NEUTRAL_COUNT[0] <= neutral <= NEUTRAL_COUNT[1]):
        raise Failed(f"continents {n_cont}, neutral {neutral}")

    # Re-pick neutral terrain on the final map: never the same as a neighbour
    # (so nothing clumps and continents stay the densest patch of their
    # terrain), and matching the size the territory actually grew to.
    areas_all = sorted(t.polygon.area for t in terr)
    lo, hi = areas_all[len(areas_all) // 3], areas_all[2 * len(areas_all) // 3]
    by_size = {
        "small": ["mountain", "plateau", "forest"],
        "medium": ["forest", "valley", "plains", "plateau", "mountain", "desert"],
        "large": ["plains", "desert", "valley"],
    }
    for r in rng.permutation(TOTAL_TERRITORIES):
        t = terr[r]
        if t.continent is not None or t.terrains[0] == "lake":
            continue
        a = t.polygon.area
        cls = "small" if a < lo else ("large" if a >= hi else "medium")
        near = {terr[n].terrains[0] for n in t.neighbors}
        opts = [x for x in by_size[cls] if x not in near] or [x for x in CONTINENT_THEMES if x not in near] or by_size[cls]
        t.terrains = [str(opts[int(rng.integers(len(opts)))])]
        detail_terrain(t, False, rng)
    spread_mountains(terr, lo, rng)

    for _, geom, _ in rivers:
        for t in terr:
            if geom.intersection(t.polygon.buffer(-3)).length > 2:
                raise Failed("river runs through the middle of a territory")
    for t in terr:
        if len(t.neighbors) < 2:
            raise Failed("territory with fewer than 2 neighbours")
    mainland_areas = [t.polygon.area for t in terr]
    ratio = max(mainland_areas) / min(mainland_areas)
    if not (1.8 <= ratio <= 2.5):
        big = max(range(len(terr)), key=lambda i: terr[i].polygon.area)
        small = min(range(len(terr)), key=lambda i: terr[i].polygon.area)
        raise Failed(f"area ratio {ratio:.2f} (big {terr[big].terrains[0]} island={terr[big].island}, small {terr[small].terrains[0]} island={terr[small].island})")

    return dict(
        rng=rng, mainland=land_union, islands=islands, islets=islets, terr=terr, rivers=rivers,
        vor=vor, themes=themes, n_cont=n_cont, sea_routes=sea_routes, ratio=ratio,
    )



# --------------------------------------------------------------------------
# Names, ids, symbols
# --------------------------------------------------------------------------


def finish(m):
    """Assign ids, names, centers, sizes and continent records."""
    rng, terr = m["rng"], m["terr"]
    k = MAINLAND_TERRITORIES
    order = sorted(range(k), key=lambda r: (round(terr[r].polygon.centroid.y / 190), terr[r].polygon.centroid.x))
    order += list(range(k, TOTAL_TERRITORIES))
    new_id = {old: i + 1 for i, old in enumerate(order)}
    names = list(rng.permutation(TERRITORY_NAMES))
    for old in range(TOTAL_TERRITORIES):
        t = terr[old]
        t.id = new_id[old]
        t.neighbors = {new_id[n] for n in t.neighbors}
        t.name = ISLAND_NAMES[old - k] if t.island else str(names[old])
        c = polylabel(t.polygon, tolerance=1.0)
        t.center = (c.x, c.y)
    terr.sort(key=lambda t: t.id)
    m["sea_routes"] = sorted({tuple(sorted((new_id[a], new_id[b]))) for a, b in m["sea_routes"]})

    areas = sorted(t.polygon.area for t in terr)
    lo, hi = areas[len(areas) // 3], areas[2 * len(areas) // 3]
    for t in terr:
        a = t.polygon.area
        t.size = "small" if a < lo else ("large" if a >= hi else "medium")

    continents = []
    used_names = set()
    for ci, theme in enumerate(m["themes"]):
        mem = sorted(t.id for t in terr if t.continent == ci)
        pool = [n for n in CONTINENT_NAMES[theme] if n not in used_names]
        name = pool[int(rng.integers(len(pool)))]
        used_names.add(name)
        bonus = len(mem) + (1 if theme in HARD_THEMES else 0)
        continents.append({"id": ci + 1, "name": name, "theme": theme, "territories": mem, "bonus": bonus})
    for t in terr:
        if t.continent is not None:
            t.continent += 1
    m["continents"] = continents
    place_symbols(m)
    return m


def place_symbols(m):
    """Small terrain motifs around each territory's open center. A mountain
    territory gets one cluster of 1-3 small peaks, never a full range."""
    rng = m["rng"]
    river_geom = unary_union([g for _, g, _ in m["rivers"]])
    for t in m["terr"]:
        poly = t.polygon
        cx, cy = t.center
        inner = poly.buffer(-10)
        if inner.is_empty:
            continue
        clear = max(24.0, 0.38 * poly.exterior.distance(Point(cx, cy)))
        primary = t.terrains[0]
        wanted = {
            "mountain": [f"peak{int(rng.integers(1, 4))}"],
            "plateau": ["plateau"],
            "plains": ["plains", "plains"],
            "valley": ["valley"],
            "desert": ["desert", "desert"],
            "forest": ["forest", "forest"],
            "lake": ["pond_big"],
        }[primary]
        wanted += [r for r in t.resources if r in ("quarry", "mine")]
        wanted += ["peak1" if x == "mountain" else x for x in t.terrains[1:]]
        wanted += ["forest" for r in t.resources if r == "forest" and primary != "forest"]
        wanted += ["pond" for r in t.resources if r == "pond" and primary != "lake"]
        minx, miny, maxx, maxy = inner.bounds
        placed = []
        for kind in wanted:
            size = 20 if kind == "pond_big" else float(rng.uniform(12, 14.5))
            for _ in range(300):
                x, y = rng.uniform(minx, maxx), rng.uniform(miny, maxy)
                p = Point(x, y)
                if math.hypot(x - cx, y - cy) < clear + size:
                    continue
                if not inner.contains(p) or poly.exterior.distance(p) < size + 6:
                    continue
                if river_geom.distance(p) < size + 6:
                    continue
                if any(math.hypot(x - px, y - py) < 1.1 * (size + ps) + 4 for px, py, ps, _ in placed):
                    continue
                placed.append((x, y, size, kind))
                break
        t.symbols = placed


def sym_svg(x, y, s, kind, rng):
    if kind.startswith("peak"):
        peaks = {1: [(0.0, 1.1)], 2: [(-0.45, 0.85), (0.35, 1.1)], 3: [(-0.7, 0.8), (0.1, 1.15), (0.85, 0.75)]}[int(kind[4:])]
        out = ""
        for dx, h in peaks:
            px = x + dx * s
            out += f'<path d="M{px - 0.75 * s:.1f},{y + 0.5 * s:.1f} L{px:.1f},{y + 0.5 * s - 1.4 * h * s:.1f} L{px + 0.75 * s:.1f},{y + 0.5 * s:.1f} Z" fill="#8c7b66" stroke="#6b5c4a" stroke-width="1.6" stroke-linejoin="round"/>'
            out += f'<path d="M{px:.1f},{y + 0.5 * s - 1.4 * h * s:.1f} L{px + 0.32 * s:.1f},{y + 0.5 * s:.1f}" stroke="#a7977f" stroke-width="1.4"/>'
        return out
    if kind == "plateau":
        return (
            f'<path d="M{x - 1.2 * s:.1f},{y + 0.45 * s:.1f} L{x - 0.7 * s:.1f},{y - 0.45 * s:.1f} L{x + 0.7 * s:.1f},{y - 0.45 * s:.1f} '
            f'L{x + 1.2 * s:.1f},{y + 0.45 * s:.1f} Z" fill="#c09a66" stroke="#957247" stroke-width="1.6" stroke-linejoin="round"/>'
            f'<path d="M{x - 0.45 * s:.1f},{y - 0.1 * s:.1f} L{x + 0.5 * s:.1f},{y - 0.1 * s:.1f}" stroke="#957247" stroke-width="1.3"/>'
        )
    if kind == "plains":
        out = ""
        for dx in (-0.55, 0, 0.55):
            bx = x + dx * s
            out += f'<path d="M{bx - 0.25 * s:.1f},{y - 0.35 * s:.1f} Q{bx - 0.05 * s:.1f},{y:.1f} {bx:.1f},{y + 0.35 * s:.1f} Q{bx + 0.05 * s:.1f},{y:.1f} {bx + 0.25 * s:.1f},{y - 0.35 * s:.1f}" fill="none" stroke="#6f9a49" stroke-width="2" stroke-linecap="round"/>'
        return out
    if kind == "valley":
        return (
            f'<path d="M{x - 1.2 * s:.1f},{y - 0.5 * s:.1f} Q{x - 0.5 * s:.1f},{y + 0.55 * s:.1f} {x:.1f},{y + 0.45 * s:.1f} '
            f'Q{x + 0.5 * s:.1f},{y + 0.55 * s:.1f} {x + 1.2 * s:.1f},{y - 0.5 * s:.1f}" fill="none" stroke="#5a8c48" stroke-width="2.6" stroke-linecap="round"/>'
            f'<path d="M{x - 0.75 * s:.1f},{y - 0.7 * s:.1f} Q{x - 0.3 * s:.1f},{y + 0.1 * s:.1f} {x:.1f},{y + 0.05 * s:.1f}" fill="none" stroke="#5a8c48" stroke-width="1.6" stroke-linecap="round"/>'
        )
    if kind == "desert":
        return (
            f'<path d="M{x - 1.1 * s:.1f},{y + 0.1 * s:.1f} Q{x - 0.45 * s:.1f},{y - 0.6 * s:.1f} {x + 0.2 * s:.1f},{y + 0.1 * s:.1f}" fill="none" stroke="#c39a4f" stroke-width="2.4" stroke-linecap="round"/>'
            f'<path d="M{x - 0.2 * s:.1f},{y + 0.55 * s:.1f} Q{x + 0.45 * s:.1f},{y - 0.15 * s:.1f} {x + 1.1 * s:.1f},{y + 0.55 * s:.1f}" fill="none" stroke="#c39a4f" stroke-width="2.4" stroke-linecap="round"/>'
        )
    if kind == "forest":
        out = ""
        for dx, dy in ((-0.55, 0.15), (0.0, -0.3), (0.55, 0.2), (0.05, 0.45))[: int(rng.integers(3, 5))]:
            tx, ty = x + dx * s, y + dy * s
            out += f'<path d="M{tx:.1f},{ty + 0.2 * s:.1f} L{tx:.1f},{ty + 0.55 * s:.1f}" stroke="#5b4630" stroke-width="2"/>'
            out += f'<circle cx="{tx:.1f}" cy="{ty:.1f}" r="{0.38 * s:.1f}" fill="#4e8c46" stroke="#386b33" stroke-width="1.4"/>'
        return out
    if kind == "quarry":
        # Terraced stone pit with two cut blocks beside it.
        out = ""
        for rx, ry, fill in ((1.1, 0.72, "#c4bdb0"), (0.72, 0.45, "#aaa193"), (0.36, 0.22, "#8f8578")):
            out += f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="{rx * s:.1f}" ry="{ry * s:.1f}" fill="{fill}" stroke="#7d7466" stroke-width="1.3"/>'
        for bx, by in ((1.25, 0.55), (1.65, 0.2)):
            out += f'<rect x="{x + (bx - 0.22) * s:.1f}" y="{y + (by - 0.16) * s:.1f}" width="{0.44 * s:.1f}" height="{0.32 * s:.1f}" fill="#e2dccf" stroke="#7d7466" stroke-width="1.2"/>'
        return out
    if kind == "mine":
        # Rocky mound with a dark, timber-framed entrance.
        return (
            f'<path d="M{x - 1.2 * s:.1f},{y + 0.6 * s:.1f} Q{x - 0.7 * s:.1f},{y - 0.95 * s:.1f} {x:.1f},{y - 0.85 * s:.1f} '
            f'Q{x + 0.75 * s:.1f},{y - 0.95 * s:.1f} {x + 1.2 * s:.1f},{y + 0.6 * s:.1f} Z" fill="#9a8b77" stroke="#6b5c4a" stroke-width="1.5" stroke-linejoin="round"/>'
            f'<path d="M{x - 0.38 * s:.1f},{y + 0.6 * s:.1f} L{x - 0.38 * s:.1f},{y + 0.02 * s:.1f} Q{x:.1f},{y - 0.42 * s:.1f} {x + 0.38 * s:.1f},{y + 0.02 * s:.1f} '
            f'L{x + 0.38 * s:.1f},{y + 0.6 * s:.1f} Z" fill="#2b2420"/>'
            f'<path d="M{x - 0.46 * s:.1f},{y + 0.6 * s:.1f} L{x - 0.46 * s:.1f},{y - 0.12 * s:.1f} L{x + 0.46 * s:.1f},{y - 0.12 * s:.1f} L{x + 0.46 * s:.1f},{y + 0.6 * s:.1f}" '
            'fill="none" stroke="#7a5530" stroke-width="2" stroke-linejoin="round"/>'
        )
    if kind in ("pond", "pond_big"):
        return f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="{1.15 * s:.1f}" ry="{0.7 * s:.1f}" fill="#6db7d4" stroke="#4a92b0" stroke-width="1.6"/>'
    return ""


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------


def path_d(geom):
    coords = list(geom.coords)
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in coords)


def poly_d(poly):
    return path_d(poly.exterior) + " Z"


OCEAN_STOPS = [(0, "#88d7c9"), (45, "#5cc0bf"), (115, "#3595ae"), (210, "#24719b"), (330, "#1b5582"), (480, "#153c66")]


def hex_rgb(h):
    return [int(h[i : i + 2], 16) for i in (1, 3, 5)]


def ocean_png(m):
    """Smooth sea colours by distance from land: shallow turquoise at the
    coast, deep blue towards the edges of the image."""
    from PIL import Image, ImageDraw
    from scipy.ndimage import distance_transform_edt

    f = 4
    mask = Image.new("L", (W // f, H // f), 0)
    d = ImageDraw.Draw(mask)
    for p in [t.polygon for t in m["terr"]] + m["islets"]:
        d.polygon([(x / f, y / f) for x, y in p.exterior.coords], fill=255)
    dist = distance_transform_edt(np.array(mask) == 0) * f
    xs = [s for s, _ in OCEAN_STOPS]
    rgb = np.stack([np.interp(dist, xs, [hex_rgb(c)[i] for _, c in OCEAN_STOPS]) for i in range(3)], axis=-1)
    img = Image.fromarray(rgb.astype(np.uint8), "RGB").resize((W, H), Image.BICUBIC)
    return img.convert("RGBA")


def render_svg(m, numbered, ocean=True):
    rng = np.random.default_rng(7)
    terr = m["terr"]
    land_all = unary_union([t.polygon for t in terr] + m["islets"])
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">']
    if ocean:
        parts += [
            '<defs><filter id="soft" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="30"/></filter></defs>',
            f'<rect width="{W}" height="{H}" fill="{OCEAN_STOPS[-1][1]}"/>',
            '<g filter="url(#soft)">',
        ]
        for dist, color in reversed(OCEAN_STOPS[1:-1]):
            shape = land_all.buffer(dist, join_style=1)
            for g in getattr(shape, "geoms", [shape]):
                parts.append(f'<path d="{poly_d(g)}" fill="{color}"/>')
        parts.append("</g>")

    # Land
    for isl in m["islets"]:
        parts.append(f'<path d="{poly_d(isl)}" fill="{COLORS["plains"]}" stroke="#5f7a62" stroke-width="2" stroke-opacity="0.6"/>')
    for t in terr:
        parts.append(f'<path d="{poly_d(t.polygon)}" fill="{COLORS[t.terrains[0]]}"/>')
    for t in terr:
        for x, y, s, kind in t.symbols:
            parts.append(sym_svg(x, y, s, kind, rng))

    # Borders: thin, light, semi-transparent grey. Coastline slightly darker.
    land = unary_union([t.polygon for t in terr])
    borders = unary_union([t.polygon.exterior for t in terr]).difference(land.boundary.buffer(0.8))
    for g in getattr(borders, "geoms", [borders]):
        if g.length > 0:
            parts.append(f'<path d="{path_d(g)}" fill="none" stroke="#5c5c5c" stroke-opacity="0.4" stroke-width="2" stroke-linejoin="round"/>')
    for g in getattr(land, "geoms", [land]):
        parts.append(f'<path d="{poly_d(g)}" fill="none" stroke="#56705a" stroke-opacity="0.65" stroke-width="2.2"/>')

    # Sea routes: dashed lines across the water between linked territories.
    by_id = {t.id: t for t in terr}
    for a, b in m["sea_routes"]:
        pa, pb = by_id[a].polygon, by_id[b].polygon
        p1, p2 = nearest_points(pa, pb)
        parts.append(
            f'<path d="M{p1.x:.1f},{p1.y:.1f} L{p2.x:.1f},{p2.y:.1f}" stroke="#ffffff" stroke-opacity="0.75" '
            'stroke-width="3" stroke-dasharray="14 10" fill="none"/>'
        )

    # Continents: thin golden line around each continent's outer edge only.
    for c in m["continents"]:
        shape = unary_union([by_id[i].polygon for i in c["territories"]]).buffer(0.3).buffer(-0.3)
        for g in getattr(shape, "geoms", [shape]):
            parts.append(f'<path d="{poly_d(g)}" fill="none" stroke="#d9a521" stroke-width="4" stroke-linejoin="round"/>')

    # Rivers
    for _, geom, main in m["rivers"]:
        parts.append(
            f'<path d="{path_d(geom)}" fill="none" stroke="#3a7fc8" stroke-width="{8 if main else 5}" '
            'stroke-linecap="round" stroke-linejoin="round"/>'
        )

    if numbered:
        for t in terr:
            x, y = t.center
            parts.append(
                f'<text x="{x:.1f}" y="{y + 9:.1f}" font-family="DejaVu Sans, Arial, sans-serif" font-size="26" font-weight="bold" '
                f'text-anchor="middle" fill="#ffffff" stroke="#ffffff" stroke-width="6" stroke-linejoin="round">{t.id}</text>'
            )
            parts.append(
                f'<text x="{x:.1f}" y="{y + 9:.1f}" font-family="DejaVu Sans, Arial, sans-serif" font-size="26" font-weight="bold" '
                f'text-anchor="middle" fill="#202020">{t.id}</text>'
            )
    parts.append("</svg>")
    return "\n".join(parts)


# --------------------------------------------------------------------------
# Data + validation
# --------------------------------------------------------------------------


def to_data(m):
    def pts(geom_coords):
        return [[round(x, 1), round(y, 1)] for x, y in geom_coords]

    territories = []
    for t in m["terr"]:
        territories.append(
            {
                "id": t.id,
                "name": t.name,
                "terrains": t.terrains,
                "resources": t.resources,
                "size": t.size,
                "coastal": bool(t.coastal),
                "continent": t.continent,
                "neighbors": sorted(t.neighbors),
                "center": [round(t.center[0]), round(t.center[1])],
                "polygon": pts(list(t.polygon.exterior.coords)[:-1]),
            }
        )
    rivers = [{"name": n, "main": main, "path": pts(g.coords)} for n, g, main in m["rivers"]]
    return {
        "image": {"width": W, "height": H},
        "territories": territories,
        "continents": m["continents"],
        "rivers": rivers,
        "sea_routes": [list(p) for p in m["sea_routes"]],
    }


def validate(data):
    """Independent checks on the finished data. Returns a list of lines; raises on failure."""
    terr = {t["id"]: t for t in data["territories"]}
    report = []

    def check(ok, msg):
        report.append(("OK   " if ok else "FAIL ") + msg)
        if not ok:
            raise Failed(msg)

    check(len(terr) == TOTAL_TERRITORIES and sorted(terr) == list(range(1, TOTAL_TERRITORIES + 1)), f"exactly {TOTAL_TERRITORIES} territories with ids 1..{TOTAL_TERRITORIES}")
    check(all(len(t["neighbors"]) >= 2 for t in terr.values()), "every territory has at least 2 neighbours")
    check(all(i in terr[n]["neighbors"] for i, t in terr.items() for n in t["neighbors"]), "neighbour lists are symmetric")
    polys = {i: Polygon(t["polygon"]) for i, t in terr.items()}
    check(all(p.is_valid for p in polys.values()), "every polygon is valid")
    check(all(polys[i].contains(Point(t["center"])) for i, t in terr.items()), "every center lies inside its territory")
    sea = {tuple(sorted(p)) for p in data["sea_routes"]}
    shared = {}
    ids = sorted(polys)
    for i in ids:
        for j in ids:
            if i < j and polys[i].distance(polys[j]) < 0.5:
                shared[(i, j)] = polys[i].boundary.intersection(polys[j].boundary).length
    land_pairs = {p for p, length in shared.items() if length > 6}
    listed = {tuple(sorted((i, n))) for i, t in terr.items() for n in t["neighbors"]}
    check(listed - sea == land_pairs, f"neighbour lists match the drawn borders ({len(land_pairs)} land borders, {len(sea)} sea routes)")
    areas = [p.area for p in polys.values()]
    ratio = max(areas) / min(areas)
    check(1.8 <= ratio <= 2.5, f"largest/smallest area ratio {ratio:.2f} (target 2-2.5)")
    conts = data["continents"]
    lo, hi = CONTINENT_COUNT
    check(lo <= len(conts) <= hi, f"{len(conts)} continents ({lo}-{hi})")
    neutral = sum(1 for t in terr.values() if t["continent"] is None)
    lo, hi = NEUTRAL_COUNT
    check(lo <= neutral <= hi, f"{neutral} neutral territories ({lo}-{hi})")
    for c in conts:
        mem = c["territories"]
        check(2 <= len(mem) <= 5, f"continent {c['id']} has {len(mem)} territories (2-5)")
        check(all(terr[i]["continent"] == c["id"] for i in mem), f"continent {c['id']} membership matches territories")
        land_nb = {i: {n for n in terr[i]["neighbors"] if polys[i].distance(polys[n]) < 1} for i in mem}
        seen, stack = {mem[0]}, [mem[0]]
        while stack:
            x = stack.pop()
            for n in land_nb[x]:
                if n in mem and n not in seen:
                    seen.add(n)
                    stack.append(n)
        check(len(seen) == len(mem), f"continent {c['id']} territories are adjacent by land")
        themed = sum(1 for i in mem if terr[i]["terrains"][0] == c["theme"])
        check(themed == len(mem), f"continent {c['id']} ({c['theme']}) territories share its terrain")
    # No big blobs of one terrain: a connected patch of territories with the
    # same main terrain may be at most as big as the largest continent (5),
    # and a mountain patch at most MAX_MOUNTAIN_CONTINENT.
    prim = {i: t["terrains"][0] for i, t in terr.items()}
    seen_all, worst = set(), {}
    for i in terr:
        if i in seen_all:
            continue
        comp, stack = {i}, [i]
        while stack:
            x = stack.pop()
            for n in terr[x]["neighbors"]:
                if n not in comp and prim[n] == prim[i] and polys[x].distance(polys[n]) < 1:
                    comp.add(n)
                    stack.append(n)
        seen_all |= comp
        worst[prim[i]] = max(worst.get(prim[i], 0), len(comp))
    check(max(worst.values()) <= 5, f"largest same-terrain patch is {max(worst.values())} territories (max 5)")
    check(worst.get("mountain", 0) <= MAX_MOUNTAIN_CONTINENT, f"largest mountain patch is {worst.get('mountain', 0)} territories (max {MAX_MOUNTAIN_CONTINENT})")
    # Mountains spread over the whole map: every territory is close to one,
    # and every part of the map (a 4 x 3 grid over the land) has some.
    mountains = [i for i in terr if prim[i] == "mountain"]
    dist = {i: 0 for i in mountains}
    queue = list(mountains)
    for x in queue:
        for n in terr[x]["neighbors"]:
            if n not in dist:
                dist[n] = dist[x] + 1
                queue.append(n)
    far = max(dist.get(i, 99) for i in terr)
    check(far <= MOUNTAIN_REACH, f"{len(mountains)} mountain territories; every territory is at most {far} steps from one (max {MOUNTAIN_REACH})")
    xs = [t["center"][0] for t in terr.values()]
    ys = [t["center"][1] for t in terr.values()]
    zones = {}
    for i, t in terr.items():
        zx = min(3, int(4 * (t["center"][0] - min(xs)) / (max(xs) - min(xs) + 1)))
        zy = min(2, int(3 * (t["center"][1] - min(ys)) / (max(ys) - min(ys) + 1)))
        zones.setdefault((zx, zy), []).append(i)
    bare = [z for z, mem in zones.items() if len(mem) >= 4 and not any(prim[i] == "mountain" for i in mem)]
    check(not bare, f"every part of the map has mountains (zones without: {len(bare)})")
    check(
        all({"quarry", "mine"} & set(terr[i]["resources"]) for i in mountains),
        "every mountain territory has a quarry or a mine",
    )
    for r in data["rivers"]:
        line = LineString(r["path"])
        worst = max(line.intersection(p.buffer(-3)).length for p in polys.values())
        check(worst < 2, f"river '{r['name']}' stays on borders (max {worst:.1f}px inside a territory)")
    check(sum(1 for r in data["rivers"] if r["main"]) == 2, "two main rivers")
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--tries", type=int, default=60)
    # assets/map holds the 70-territory board the game is built from; this
    # layout goes to assets/map/v2 until it replaces it.
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "..", "assets", "map", "v2"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    for seed in range(args.seed, args.seed + args.tries):
        try:
            m = finish(build(seed))
            data = to_data(m)
            report = validate(data)
            break
        except Failed as e:
            print(f"seed {seed}: {e}")
    else:
        raise SystemExit("no valid map found")

    print(f"seed {seed}: valid")
    with open(os.path.join(args.out, "map_data.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    ocean = ocean_png(m)
    for numbered, name in ((False, "map_structure"), (True, "map_structure_numbered")):
        svg = render_svg(m, numbered)
        with open(os.path.join(args.out, name + ".svg"), "w", encoding="utf-8") as f:
            f.write(svg)
        # cairosvg ignores blur filters, so the PNG gets a raster sea underneath.
        import io

        from PIL import Image

        land = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=render_svg(m, numbered, ocean=False).encode(), output_width=W, output_height=H)))
        Image.alpha_composite(ocean, land.convert("RGBA")).convert("RGB").save(os.path.join(args.out, name + ".png"))
    neutral = sum(1 for t in data["territories"] if t["continent"] is None)
    summary = [f"seed: {seed}", f"continents: {len(data['continents'])}", f"neutral territories: {neutral}", ""] + report
    with open(os.path.join(args.out, "validation.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(summary) + "\n")
    print("\n".join(summary))


if __name__ == "__main__":
    main()
