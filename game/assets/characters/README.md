# Player character

Drop a rigged, animated humanoid here as `player.glb` (or `player.gltf`) and
the game uses it instead of the built-in procedural person. Or pass one at
launch: `godot --path game -- --character=/abs/path/model.glb`.

Requirements: one skeleton, an AnimationPlayer with clips whose names contain
`idle`, `walk` and `run`/`jog`/`sprint` (`jump`/`fall` optional). Scale, feet
height and facing are worked out from the skeleton, so models in cm or m,
facing +Z or -Z, all work.

Good sources:

- **Quaternius — Universal Base Characters + Universal Animation Library**
  (quaternius.com / itch.io, CC0). Realistic proportions, one shared rig.
- **Mixamo** (mixamo.com, free Adobe account). Most realistic option: pick a
  character, download it as FBX *with skin* plus Idle / Walking / Running
  clips, combine in Blender and export glTF. Mixamo's terms let you use them
  in your game but not redistribute the raw files — keep them out of a public
  repo.
- **KayKit Character Packs** (CC0) — stylised.
