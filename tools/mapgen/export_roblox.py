"""Turn assets/map/map_data.json into src/shared/MapData.luau for the game.

Roblox has no polygon part, so each territory is pre-split into triangles
here (constrained Delaunay, so no triangle leaves the territory). Outlines
are simplified for 3D; the JSON keeps the full-detail shapes.

Also places the small terrain props (peaks, groves, ponds, dunes, mesas)
away from each territory's center, and works out each continent's outer
edge for the golden outline.

Usage: python export_roblox.py   (then run stylua on the output)
"""

from __future__ import annotations

import json
import math
import os

import numpy as np
import shapely
from shapely.geometry import LineString, Point, Polygon
from shapely.ops import linemerge, nearest_points, unary_union

HERE = os.path.dirname(__file__)
SRC = os.path.join(HERE, "..", "..", "assets", "map", "map_data.json")
OUT = os.path.join(HERE, "..", "..", "src", "shared", "MapData.luau")
SIMPLIFY = 2.0  # pixels

PROPS = {
    "mountain": ["peak", "peak", "peak"],
    "plateau": ["mesa", "mesa"],
    "plains": [],
    "valley": [],
    "desert": ["dune", "dune", "dune"],
    "forest": ["grove", "grove", "grove"],
    "lake": ["pond_big"],
}


def triangles(poly):
    tris = shapely.constrained_delaunay_triangles(poly)
    out = []
    for t in tris.geoms:
        if t.area < 0.5:
            continue
        (ax, ay), (bx, by), (cx, cy) = list(t.exterior.coords)[:3]
        out += [ax, ay, bx, by, cx, cy]
    return out


def place_props(t, poly, rivers, rng):
    cx, cy = t["center"]
    inner = poly.buffer(-16)
    if inner.is_empty:
        return []
    clear = max(46.0, 0.45 * poly.exterior.distance(Point(cx, cy)))
    wanted = list(PROPS[t["terrains"][0]])
    wanted += [{"mountain": "peak", "plateau": "mesa", "desert": "dune", "forest": "grove"}.get(x) for x in t["terrains"][1:]]
    wanted += ["grove" for r in t["resources"] if r == "forest" and t["terrains"][0] != "forest"]
    wanted += ["pond" for r in t["resources"] if r == "pond" and t["terrains"][0] != "lake"]
    minx, miny, maxx, maxy = inner.bounds
    placed = []
    for kind in [w for w in wanted if w]:
        size = 26.0 if kind == "pond_big" else 18.0
        for _ in range(300):
            x, y = rng.uniform(minx, maxx), rng.uniform(miny, maxy)
            p = Point(x, y)
            if math.hypot(x - cx, y - cy) < clear + size or not inner.contains(p):
                continue
            if poly.exterior.distance(p) < size + 8 or rivers.distance(p) < size + 8:
                continue
            if any(math.hypot(x - px, y - py) < size + 30 for px, py, _ in placed):
                continue
            placed.append((round(x, 1), round(y, 1), kind))
            break
    return placed


def lua(v, indent=0):
    pad = "\t" * indent
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(round(v, 1)) if isinstance(v, float) else str(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        if all(isinstance(x, (int, float)) for x in v):
            return "{ " + ", ".join(lua(x) for x in v) + " }"
        return "{\n" + "".join(f"{pad}\t{lua(x, indent + 1)},\n" for x in v) + pad + "}"
    if isinstance(v, dict):
        key = lambda k: k if k.isidentifier() else f'["{k}"]'
        return "{\n" + "".join(f"{pad}\t{key(k)} = {lua(x, indent + 1)},\n" for k, x in v.items()) + pad + "}"
    raise TypeError(type(v))


def main():
    data = json.load(open(SRC, encoding="utf-8"))
    rng = np.random.default_rng(11)
    rivers = unary_union([LineString(r["path"]) for r in data["rivers"]])
    polys = {t["id"]: Polygon(t["polygon"]) for t in data["territories"]}

    # Coverage simplification keeps shared borders identical on both sides,
    # so the slabs meet with no cracks.
    ids = [t["id"] for t in data["territories"]]
    simplified = dict(zip(ids, shapely.coverage_simplify([polys[i] for i in ids], SIMPLIFY)))

    territories = []
    for t in data["territories"]:
        poly = polys[t["id"]]
        simple = simplified[t["id"]]
        outline = [c for xy in list(simple.exterior.coords) for c in (round(xy[0], 1), round(xy[1], 1))]
        props = place_props(t, poly, rivers, rng)
        territories.append(
            {
                "id": t["id"],
                "name": t["name"],
                "terrains": t["terrains"],
                "resources": t["resources"],
                "size": t["size"],
                "coastal": t["coastal"],
                "continent": t["continent"],
                "neighbors": t["neighbors"],
                "center": t["center"],
                "outline": outline,
                "triangles": [round(c, 1) for c in triangles(simple)],
                "props": [{"x": x, "y": y, "kind": k} for x, y, k in props],
            }
        )

    continents = []
    for c in data["continents"]:
        shape = unary_union([simplified[i] for i in c["territories"]]).buffer(0.05).buffer(-0.05)
        shape = max(getattr(shape, "geoms", [shape]), key=lambda g: g.area)
        edge = [v for xy in shape.exterior.coords for v in (round(xy[0], 1), round(xy[1], 1))]
        continents.append({**c, "edge": edge})

    rivers_out = [
        {"name": r["name"], "main": r["main"], "path": [v for xy in LineString(r["path"]).simplify(1.0).coords for v in (round(xy[0], 1), round(xy[1], 1))]}
        for r in data["rivers"]
    ]
    # Borders between territories, each drawn once (coastlines excluded).
    land = unary_union(list(simplified.values()))
    lines = unary_union([g.exterior for g in simplified.values()]).difference(land.boundary.buffer(0.3))
    merged = linemerge(lines) if not isinstance(lines, LineString) else lines
    borders = [
        [v for xy in g.coords for v in (round(xy[0], 1), round(xy[1], 1))]
        for g in getattr(merged, "geoms", [merged])
        if g.length > 1
    ]
    coast = [
        [v for xy in g.exterior.simplify(1.0).coords for v in (round(xy[0], 1), round(xy[1], 1))]
        for g in getattr(land, "geoms", [land])
    ]
    sea_routes = []
    for a, b in data["sea_routes"]:
        p1, p2 = nearest_points(simplified[a], simplified[b])
        sea_routes.append({"from": a, "to": b, "line": [round(p1.x, 1), round(p1.y, 1), round(p2.x, 1), round(p2.y, 1)]})

    body = {
        "width": data["image"]["width"],
        "height": data["image"]["height"],
        "territories": territories,
        "continents": continents,
        "rivers": rivers_out,
        "borders": borders,
        "coast": coast,
        "seaRoutes": sea_routes,
    }
    header = (
        "--!strict\n"
        "-- GENERATED by tools/mapgen/export_roblox.py from assets/map/map_data.json. Do not edit by hand.\n"
        "-- Coordinates are image pixels (x right, y down). Flat number lists are x, y pairs;\n"
        "-- `triangles` holds three pairs per triangle.\n\n"
        "return "
    )
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(header + lua(body) + "\n")
    n_tris = sum(len(t["triangles"]) // 6 for t in territories)
    n_props = sum(len(t["props"]) for t in territories)
    print(f"wrote {OUT}: {len(territories)} territories, {n_tris} triangles, {n_props} props, {os.path.getsize(OUT) // 1024} KB")


if __name__ == "__main__":
    main()
