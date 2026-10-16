# Rigged rider → Roblox (R15)

**Use `rider_r15.fbx`.** It is the rider rebuilt as a Roblox R15 skinned character:

- Skeleton: `Root › HumanoidRootNode › LowerTorso › UpperTorso › Head`, arms `UpperArm › LowerArm › Hand`, legs
  `UpperLeg › LowerLeg › Foot` (Left/Right), the names and hierarchy in Roblox's
  [character specification](https://create.roblox.com/docs/art/characters/specifications).
- Mesh split into the 15 body parts (`LowerTorso_Geo` … `RightFoot_Geo`), all skinned to that one skeleton, so the
  joints bend smoothly instead of separating. Max 4 bone influences per vertex, nothing weighted to `Root`.
- Facing +Z, Y up, transforms frozen, 1.8 m tall, texture embedded. 11,660 triangles total; the largest part
  (Head with helmet) is 2,075.
- `rider_r15_parts.png` shows the body-part split; `rider_r15_posed_test.png` is the mesh bent into a crouch to prove
  the skinning holds.

Other files here: `rider_r15.glb` (same rig, for viewers), `rider_r15.blend` (Blender source),
`rider_rigged.*` and `anim_*.fbx` (the original Meshy rig and clips, which are **not** R15 and won't drive this rig).
To rebuild after changing the mesh (`pip install bpy` first):
`python3 tools/rig_rider_r15.py assets/models/rigged/rider_rigged.glb out` then
`python3 tools/delogo_rider.py out/rider_r15.blend out/rider_r15_clean.blend`, and export the clean .blend to FBX.

## Put it on the bike (RoBikes)

1. Studio → **Avatar** tab → **Import 3D** → pick `rider_r15.fbx`.
2. In the importer: **Rig General › Rig Type = R15** (it should detect it), **Scale Unit = Meter**. The preview should
   show a rider about 6 studs tall. Click **Import**.
3. Rename the new model to **`RiderR15`** and drag it into **ReplicatedStorage** (directly in it, *not* inside the
   `Robikes` folder, because the dev sync rebuilds that folder).
4. Import the bike the same way (see `../bike/BIKE_TO_ROBLOX.md`) if you want the mesh bike too.
5. Pull the code in as usual (`node tools/serve_src.js my-version/src`, then
   `require(game.ServerStorage.RobikesDevSync)()`). This brings in the new `RiderRig` module and the updated
   `BikeRenderer`.
6. Press **Play**. Every bike, yours and other players', now has the rigged rider instead of the block rider.

What the code does: `BikeRenderer` clones `RiderR15`, scales it to 1.8 m (6.3 studs), anchors it and poses it every
frame. The hips sit on the seat, the body shifts with the existing rider-weight controls (arrow keys), the hands follow
the handlebars through the steering, the boots stay on the pegs, and on a crash the whole rider tumbles as before.
If `RiderR15` is missing, the old block rider is used, so nothing breaks.

If the Output shows **"RiderR15 has no joint named …"**, the importer renamed a bone. Open the model, find the bone
or part with the odd name, rename it to the R15 name the warning gives, and play again.

Pose tuning lives in `BikeRenderer.luau` (`self.rigTargets`, `rigGrips`, `rigPegs`): `hips` moves the rider
along the seat, `torsoLean` / `hipLean` set the attack position, `headUp` tilts the helmet up.

## As a walking character (paddock, menus, NPCs)

Because the rig is R15, Roblox's own animations drive it.

- **Player character:** copy the imported model, name it `StarterCharacter`, put it in `StarterPlayer`. If Play
  complains about a missing Humanoid or HumanoidRootPart, select the model and run **Avatar › Avatar Setup** on it
  once; it adds the Humanoid, the attachments and the joints.
- **NPC:** put the model in Workspace and play any R15 animation through its `Humanoid.Animator`.

## Notes

- **Logo removed:** the stray Fox-style head on both boot shins is painted out (`rider_r15_boots_nologo.png`),
  with `tools/delogo_rider.py`.
- **Not yet tested inside Studio.** The rig was checked in Blender (names, hierarchy, weights, and skin deformation
  after an FBX round-trip), and the pose code compiles with the Luau compiler, but it has not been imported into
  Studio yet.
