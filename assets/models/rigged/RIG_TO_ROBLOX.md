# Rigged rider → playable / animated Roblox character

Files (this folder): `rider_rigged.fbx` (+ `.glb`), `anim_walking.fbx`, `anim_running.fbx`, `anim_36.fbx`, `anim_92.fbx`.
The rig is a generic humanoid skeleton (Meshy), not Roblox R15. Pick the route for what you need.

## Route A — true R15 playable character (recommended for a walking Humanoid)
The Meshy skeleton won't drive a Roblox `Humanoid` directly. Use Roblox's native setup:
1. Studio → **Avatar** tab → **Avatar Setup / Auto-Setup**.
2. Feed it the rider mesh (import `rider_rigged.fbx` first, or the un-rigged `rider_fullkit.glb`→FBX).
3. Auto-Setup fits an **R15** cage + skeleton, so it works with `Humanoid`, the default `Animate` script and any Roblox animation. Now it's a drop-in player character or NPC.

## Route B — use the Meshy rig + its clips directly (AnimationController)
1. Studio → **3D Importer** → import `rider_rigged.fbx`. It comes in as a Model: a skinned MeshPart + bones + an `AnimationController`/`Animator`.
2. Import `anim_walking.fbx` / `anim_running.fbx` / `anim_36.fbx` / `anim_92.fbx`; in the importer enable **Animations** → each becomes a `KeyframeSequence` you can **Save to Roblox** as an Animation asset (note its assetId).
3. At runtime: `Animator:LoadAnimation(anim)` then `:Play()`.

## For Robikes specifically (the rider sits on the bike)
A motocross rider doesn't walk — it's posed on the bike and leans. Best use:
- Pose `rider_rigged` in a **riding crouch** (rotate the arm/spine bones toward the bars), parent it to the bike chassis, and drive **lean** by rotating the spine/arms with `controls.lean` and `steer` from `BikePhysics`.
- **Ragdoll on crash:** on `phys.crashed`, swap the rig to loose joints / physics so it tumbles off (mirrors the game's `detach_blend`).
- Keep `walking/running` for a paddock or menu scene.

## Notes
- **FBX imports directly** into Studio (no conversion). The `.glb` versions still need FBX/OBJ.
- **Scale:** rigged at 1.8 m → ~6.3 studs tall; resize to match the bike.
- **⚠ Logo:** the rider texture still carries the stray Fox-style logo — re-skin after cleaning before shipping.
