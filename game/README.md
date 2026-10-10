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

## Controls

| On foot | In car |
|---|---|
| WASD / arrows — move (camera-relative) | W / S — throttle, brake, reverse |
| Shift — sprint, Space — jump | A / D — steer, Space — handbrake |
| Mouse — look | R — flip upright |
| E / F near the car — get in | E / F — get out (below ~20 km/h) |

Esc releases the mouse; click to recapture.

## Layout

```
project.godot, main.tscn   entry point (scene is built in code)
scripts/osm_data.gd        .osm XML parser + lat/lon -> local metres projection
scripts/map_builder.gd     roads, buildings, land use -> merged meshes + collision
scripts/main.gd            input map, sky/sun, spawn, enter/exit car, HUD
scripts/player.gd          CharacterBody3D on-foot controller
scripts/car.gd             VehicleBody3D (RWD, front steer)
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

- Flat world: no elevation. Next step is sampling an SRTM/USGS DEM and
  draping roads and building bases onto it.
- Whole map is built at load time as a few merged meshes. Fine for a few km²;
  beyond that, chunk by tile and stream.
- Primitive visuals. Swap in CC0 models (Quaternius, KayKit, Kenney) for the
  player and car by replacing the mesh code in `player.gd` / `car.gd`;
  for buildings, assign a textured material in `map_builder.gd::_attach`.
- No traffic or pedestrians yet. Drivable road centrelines are already
  identified in `map_builder.gd` (`DRIVABLE_TYPES`) — that's the graph to
  build lane-following AI on.
