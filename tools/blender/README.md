# Board in Blender

`build_board.py` builds the 3D board from `assets/map/map_data.json`: one raised
tile per territory (height by main terrain, same values as
`GameConfig.Map.Elevation`), river channels cut between tiles, a pale base that
shows through the gaps as faint borders, gold continent edges, and low-poly props
(peaks, mesas, trees, dunes, fields, ponds, rocks, ground patches) kept inside
each territory with the center left open.

```
blender --background --python tools/blender/build_board.py -- --render
# or, with the bpy module from PyPI (Python 3.13): python tools/blender/build_board.py --render
```

Writes `build/blender/board.fbx`, `board.blend`, `palette.png` and, with
`--render`, three preview PNGs. Objects in the FBX:

| Object | What it is | In the game |
| --- | --- | --- |
| `Ground_NN` | territory tile | plain color, tinted to the owner |
| `Props_NN` | that territory's props | palette texture |
| `Edge_CC` | continent outline | gold, turns to the owner's color |
| `Rivers`, `LandBase` | river water, pale floor | fixed |

1 Blender unit = 1 stud; map pixel (x, y) maps to `((x - 1536) * 0.5, -(y - 1024) * 0.5)`.
Import into Studio with the 3D Importer using studs as the unit.
