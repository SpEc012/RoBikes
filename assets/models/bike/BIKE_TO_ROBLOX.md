# Bike mesh → Roblox

**Use `bike_450_parts.fbx`.** It is the generated 450 (`../bike_450.glb`) cut into the parts that move, scaled and placed
on RoBikes' own geometry (`RobikesConfig.GEOM` + the 450 tyres):

| Part | What's in it | How it moves in game |
|---|---|---|
| `Frame` | frame, engine, exhaust, tank, shrouds, seat, side panels, rear fender | with the bike body |
| `Steer` | fork tubes, clamps, bars, number plate, front fender | turns about the fork axis |
| `ForkLower` | fork lower legs and front brake | turns with the bars and slides up and down the fork with the suspension |
| `FrontWheel` | front tyre and rim | turns with the bars, rides on the fork, spins |
| `RearWheel` | rear tyre, rim, sprocket | follows the physics rear axle, spins |
| `Swingarm` | swingarm and chain | swings about the pivot to follow the rear axle |

Also in the file: three 1 cm cubes, `Origin`, `MarkFwd` and `MarkUp`. They are 1 m apart in the bike's design frame, so the
game can recover position, direction and import scale whatever the importer does. Don't delete them; the game removes
them at runtime.

- Wheelbase 1.47 m, wheels at the physics tyre radii (front 0.335 m, rear 0.325 m), bike sits on the ground at static
  sag. Uniform scale ×2.18 from the generated mesh; the wheels were shrunk about 6 % about their axles to the tyre
  radii.
- The mesh's own fork angle (22.3°) is used as the steering axis, so the wheel never leaves the fork. All hardpoints
  live in `my-version/src/ReplicatedStorage/Robikes/BikeModelData.luau`.
- Textures are embedded as PNG (Studio's importer rejects the WebP the generator produced).
- 11,626 triangles in total; the largest part (Frame) is 5,678.
- `bike_450_parts_side.png` / `bike_450_parts_3q.png` show the split (grey frame, blue steering, cyan fork lowers, red
  front wheel, yellow rear wheel, green swingarm).

## Import steps

1. Studio → **Avatar** tab (or **Home**) → **Import 3D** → pick `bike_450_parts.fbx`.
2. In the importer: **Rig Type = None**, **Scale Unit = Meter**, keep **Import as one model** on, leave **Anchored** on.
   Click **Import**.
3. Rename the model to **`Bike450`** and drag it into **ReplicatedStorage** (directly in it, not inside the `Robikes`
   folder).
4. Sync the code and press **Play**.

What the code does: `BikeRenderer` sees `Bike450`, hides the block bike and moves the six parts every frame through
`BikeModel`. The physics is untouched. If `Bike450` is missing, or its markers are, the block bike is used.
The rider (`RiderR15`, see `../rigged/RIG_TO_ROBLOX.md`) sits on this mesh's seat and holds its bars when both are
imported.

Rebuild after changing the mesh (`pip install bpy` first):
`python3 tools/split_bike.py assets/models/bike_450.glb out preview`, then copy `out/bike_450_parts.json` values into
`BikeModelData.luau`.

**Not yet tested inside Studio.** The split and pivots were checked in Blender renders, and the code compiles with the
Luau compiler.

## Colours

`colours/` has the bike's colour map in seven colours: orange (original), red, blue, green, yellow, purple and black.
`tools/recolour_bike.py` makes them by moving the orange plastics and rims to another hue; white, black and metal parts
stay as they are. `colours/preview_all_colours.png` shows all seven.

Each bike gets its own colour by default: 250X yellow, 250XF blue, 350XF green, 450XF red, 450SM purple
(`MESH_COLOUR` in `BikeRenderer.luau`). To use a colour in game:

1. In Studio, upload `colours/bike_450_colour_<name>.png` as an image (Asset Manager › Bulk Import, or any
   Decal/Texture field), copy its `rbxassetid://…` id.
2. Paste it into `colourMaps.<name>` in `BikeModelData.luau` and sync. A colour left as `""` keeps the imported texture.

A menu picker can pass any `colourMaps` key as the fourth argument: `BikeRenderer.new(spec, parent, name, "blue")`, or
call `renderer.mesh:setColour("blue")` on a live bike.
