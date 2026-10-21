# Map generator

Builds the Risk-style map structure (stage 1): 70 territories, 13-15 continents,
two main rivers on territory borders, and the data file the game reads.

```
pip install -r tools/mapgen/requirements.txt
python tools/mapgen/generate_map.py --seed 67
```

Writes to `assets/map/`:

| File | What it is |
| --- | --- |
| `map_structure.png` / `.svg` | Flat terrain colours, small terrain symbols, borders, rivers, golden continent outlines. Reference for the art model. |
| `map_structure_numbered.png` / `.svg` | Same, with each territory id at its center. For review only. |
| `map_data.json` | Territories, continents, rivers and sea routes in image pixel coordinates (3072 x 2048). |
| `validation.txt` | Result of the checks run on the finished data. |
| `art_prompt.md` | Stage 2 prompt for the art model. |

Every run is checked before anything is written: exactly 70 territories, at
least 2 neighbours each, symmetric neighbour lists that match the drawn
borders, 13-15 continents of 2-5 adjacent territories sharing one terrain,
25-30 neutral territories, largest territory at most 2.5x the smallest, no
same-terrain patch bigger than 5, and rivers that never enter a territory's
interior. A seed that fails is skipped and the next one is tried.

`sea_routes` lists extra links across water: the two islands, and any
peninsula tip that would otherwise have a single neighbour. They also appear
in each territory's `neighbors`.
