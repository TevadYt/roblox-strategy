# Map generator

Builds the Risk-style map structure (stage 1): 140 territories (136 on the
mainland, two islands of two), 18-22 continents, two main rivers on territory
borders, and the data file the game reads.

```
pip install -r tools/mapgen/requirements.txt
python tools/mapgen/generate_map.py --seed 22
```

`assets/map/` still holds the first 70-territory board, which the Blender
board and the game are built from. This layout is written to `assets/map/v2/`
until it replaces it. Both share one landmass: the coastline, islands and
islets always come from `LAND_SEED`.

Writes to `assets/map/v2/`:

| File | What it is |
| --- | --- |
| `map_structure.png` / `.svg` | Flat terrain colours, small terrain symbols, borders, rivers, golden continent outlines. Reference for the art model. |
| `map_structure_numbered.png` / `.svg` | Same, with each territory id at its center. For review only. |
| `map_data.json` | Territories, continents, rivers and sea routes in image pixel coordinates (3072 x 2048). |
| `validation.txt` | Result of the checks run on the finished data. |
| `art_prompt.md` | Stage 2 prompt for the art model. |

Every run is checked before anything is written: exactly 140 territories, at
least 2 neighbours each, symmetric neighbour lists that match the drawn
borders, 18-22 continents of 2-5 adjacent territories sharing one terrain,
50-62 neutral territories, largest territory at most 2.5x the smallest, no
same-terrain patch bigger than 5, and rivers that never enter a territory's
interior. A seed that fails is skipped and the next one is tried.

Mountains are spread over the whole map rather than bunched: no mountain patch
is bigger than 3 territories, every territory is at most 2 steps from a
mountain territory, and every part of the map (a 4 x 3 grid) has some. A
mountain territory shows only 1-3 small peaks and always holds a `quarry`
(stone) or a `mine` (gold), sometimes both; some plateaus have a quarry too.
These appear in each territory's `resources` next to `forest` and `pond`.

`sea_routes` lists extra links across water: each island half to its nearest
coast, and any peninsula tip that would otherwise have a single neighbour. They also appear
in each territory's `neighbors`.
