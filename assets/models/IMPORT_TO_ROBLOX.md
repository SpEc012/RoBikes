# Importing the Robikes 3D models into Roblox

**Game-ready versions:** the rider is `rigged/rider_r15.fbx` (R15, logo removed, see `rigged/RIG_TO_ROBLOX.md`) and
the bike is `bike/bike_450_parts.fbx` (split into moving parts, see `bike/BIKE_TO_ROBLOX.md`). Both are FBX and import
directly. The notes below are about the raw generated `.glb` files.

Files: `bike_450.glb`, `helmet.glb`, `rider_fullkit.glb`, `boots.glb` (textured GLB from Trellis 2).

## Roblox needs FBX or OBJ, not GLB — convert first (free, ~2 min)
Roblox Studio's **Import 3D** accepts `.fbx` and `.obj`, not `.glb`. Convert each:

**Blender (recommended, keeps textures):**
1. Blender → File → Import → **glTF 2.0 (.glb)** → pick the file.
2. File → Export → **FBX (.fbx)** (Path Mode: *Copy*, and enable the little texture icon to embed textures), or **OBJ**.
3. In Studio: **Avatar/Model tab → Import 3D → 3D Importer** → select the `.fbx`. It uploads as a MeshPart with its texture/SurfaceAppearance.

**Or** use any "GLB to FBX" online converter, then Import 3D.

## Notes
- **Triangle budget:** these are ~12k verts. If the importer rejects a mesh for exceeding Roblox's per-MeshPart triangle limit, add a **Decimate** modifier in Blender and bring it under ~10k tris, then re-export.
- **Scale:** resize after import to real size. With `STUDS_PER_METRE = 3.5`: bike ≈ 7.3 studs long, rider ≈ 6 studs tall, helmet ≈ 1 stud.
- **Rider:** use `rigged/rider_r15.fbx`. Keep helmet/boots as separate accessories so colours stay swappable.
- **Logos:** the rider texture is cleaned in `rigged/rider_r15.fbx`. The separate `boots.glb` texture still carries the stray logo; it is not used by the game.

## Wiring into the starter project
The game (`my-version`) wires these in for you: import the two FBX files, name them `RiderR15` and `Bike450`, put them in ReplicatedStorage, and `BikeRenderer` uses them in place of the block bike and rider.
