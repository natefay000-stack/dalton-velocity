# Neighborhood — open-world sandbox from OpenStreetMap

Godot 4 project that turns an OpenStreetMap extract into a drivable, walkable
3D neighbourhood: roads, extruded buildings (with collision), parks and water,
a third-person character and a car you can get in and out of.

All code here is original and MIT-compatible. No Rockstar/GTA code, no
reverse-engineered projects, no game assets. The only external input is OSM
map data (ODbL — attribution is shown in the HUD).

## Run

1. Install [Godot 4.3+](https://godotengine.org/download) (standard build, not .NET).
2. `godot --path game` — or open `game/project.godot` in the editor and press F5.

It loads, in order: `--map=<path>` on the command line
(`godot --path game -- --map=/abs/path/area.osm`), the `map_path` export on the
`Main` node, `maps/neighborhood.osm`, then the bundled synthetic
`maps/sample.osm` (a fictional 4×4-block grid).

## Your neighbourhood

**Recommended — Overture Maps + terrain** (roads, footpaths, water and land
use from OpenStreetMap; buildings merged with Microsoft/Google footprints, so
suburbs are nearly complete; plus a 4 m elevation grid):

```bash
pip install pyarrow   # the only dependency, for reading Overture's GeoParquet
python3 game/tools/fetch_overture.py --bbox SOUTH WEST NORTH EAST -o game/maps/home.osm
# e.g. Herriman, Blackridge Reservoir area:
python3 game/tools/fetch_overture.py --bbox 40.470 -112.032 40.489 -112.006 -o game/maps/herriman.osm
```

This writes `home.osm` + `home.height`; the game picks up any `.osm` in
`maps/` and its matching `.height` automatically. Takes about a minute for a
few km². Everything is clipped to the box, and the edge of the map has
invisible walls.

**Alternative — Overpass (OSM only, flat):**

```bash
python3 game/tools/fetch_osm.py --center <lat> <lon> --radius 400
# or: --bbox SOUTH WEST NORTH EAST
```

Writes `game/maps/neighborhood.osm` (stdlib only; Overpass API; refuses areas
over 6 km² unless `--force`). You can also use **Export** on openstreetmap.org
and drop the `.osm` file into `game/maps/`.

`maps/*.osm` other than the sample is git-ignored so your home area isn't
committed by accident — remove that line from `game/.gitignore` if you want it
versioned.

## What's in the world

- **Roads** with kerbs, sidewalks (from the data), yellow centre lines on
  through roads, and driveways synthesised from each house's garage to the
  street.
- **Houses** with hipped or gabled roofs, windows on every wall, a front
  door and a garage door on the wall that faces the street.
- **Trees** in yards, parks and woods, sage scrub on the open hillside,
  street lights, and parked cars (sedans, SUVs, pickups in nine colours)
  in driveways and along kerbs. All placed on a 1 m occupancy grid so
  nothing sits on a road, in a house or in the water; all have collision.
- **Pedestrians** (40 by default, `pedestrian_count` on the Main node)
  walking the footpath network, animating within 160 m of you.
- **A visible driver** (your character) when you're in the car.

Placement is seeded from the map file name, so a given map always looks the
same.

## Player character

By default you play a procedurally built person (articulated body, clothes,
face, randomised skin/hair/outfit via `look_seed` on the Player node) with a
procedural idle / walk / jog / sprint / jump cycle with foot planting:
stance feet are locked to the ground (two-bone leg IK, heel-to-toe roll,
pelvis drops only as far as the legs need), and when you stop or turn on the
spot the feet step back under the body. For a fully realistic,
mocap-animated person, drop a rigged `.glb` into `assets/characters/player.glb`
— see [assets/characters/README.md](assets/characters/README.md). Tested with
Mixamo exports (both cm/+Z and m/−Z conventions).

## Controls

| On foot | In car |
|---|---|
| WASD / arrows — move (camera-relative) | W / S — throttle, brake, reverse |
| Shift — sprint, Ctrl — walk, Space — jump | A / D — steer, Space — handbrake |
| Mouse — look | R — flip upright |
| E / F near the car — get in | E / F — get out (below ~20 km/h) |

Esc releases the mouse; click to recapture.

## Layout

```
project.godot, main.tscn   entry point (scene is built in code)
scripts/osm_data.gd        .osm XML parser + lat/lon -> local metres projection
scripts/map_builder.gd     roads, buildings (hip roofs), land use, water -> meshes + collision
scripts/terrain.gd         .height grid -> terrain mesh, HeightMapShape3D, edge walls
tools/fetch_overture.py    Overture Maps + AWS terrain tiles -> .osm + .height
scripts/main.gd            input map, sky/sun, spawn, enter/exit car, HUD
scripts/player.gd          CharacterBody3D on-foot controller
scripts/humanoid.gd        procedural person + walk/run animation
scripts/gltf_character.gd  drop-in rigged .glb player (auto clip matching)
scripts/car.gd             VehicleBody3D (RWD, front steer), seated driver
scripts/car_mesh.gd        low-poly sedan / SUV / pickup meshes from a side profile
scripts/occupancy.gd       1 m grid of what's where (roads, houses, water, props)
scripts/props_builder.gd   trees, scrub, parked cars, street lights (MultiMesh)
scripts/pedestrians.gd     walkers on the footpath graph
scripts/camera_rig.gd      orbit camera with spring arm
tools/fetch_osm.py         Overpass downloader
tests/run_tests.gd         headless engine tests (parser, geometry, physics)
tools/test_fetch_osm.py    downloader unit tests
```

Coordinates: +X east, −Z north, origin at the centre of the map bounds.
Building height comes from `height`, else `building:levels` × 3.2 m, else a
deterministic 1–3 storeys. Road width from `width`, else `lanes` × 3.25 m,
else a per-`highway` default. Multipolygon buildings/areas use outer rings
only (courtyards are filled in).

## Tests

```bash
godot --headless --path game --script res://tests/run_tests.gd   # exits 1 on failure
cd game && python3 -m unittest discover -s tools
```

## Known limits / next steps

- Terrain comes from a ~3–10 m elevation model resampled to 4 m, so curbs,
  driveways and retaining walls aren't in it; roads are draped over it, not
  cut into it.
- Whole map is built at load time as a few merged meshes. Fine for a few km²;
  beyond that, chunk by tile and stream.
- Everything is flat-shaded low-poly, no textures. Textured walls/roads
  would be the next visual step (`map_builder.gd::_attach`).
- No moving traffic yet; parked cars only. Drivable road centrelines are
  in `MapBuilder.road_list` — that's the graph to build lane-following AI on.
- Pedestrians have no collision: you walk through them and they ignore you.
