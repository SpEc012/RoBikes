# Importing the Robikes 3D models into Roblox

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
- **Rider is a single static mesh** (no skeleton). For a playable rider, rig it (fal `fal-ai/meshy/rigging`, or Studio's rigging tools), or use it as reference to skin an R15 character; keep helmet/boots as separate accessories so colours stay swappable.
- **⚠ Logos:** the rider and boots textures carry a stray Fox-Racing-style logo the image model added. Regenerate those two **logo-free** before shipping (quick nano-banana edit), then re-convert.

## Wiring into the starter project
In `robikes/src/client/BikeRenderer.lua`, replace the placeholder `Part`s (`Chassis`, wheels, `Rider`) with these imported **MeshPart**s (keep the same names and local offsets). The physics in `BikePhysics.lua` is independent of the visuals, so nothing else changes.
