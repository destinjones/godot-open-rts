# AI-generated faction models

Nine faction models had no art of their own (they borrowed another unit's or building's
model). On 2026-10-06 they were generated with Higgsfield and cleaned up for the game.
Total cost: 94.5 credits (9 x 1.5 for the concept images, 9 x 9 for the 3D models).

## Pipeline

1. **Concept image:** GPT Image 2.5 (`gpt_image_2_5`), quality high, 1:1, opaque background,
   one image per model. Every prompt starts with "Single isolated 3D game asset render for a
   modern realistic real-time strategy game:", describes the object in the Grounded palette
   (weathered, dusty, muted olive for the Foundry League, rust red and sand for the Sandline
   Syndicate), paints the team-colour surfaces **flat bright cobalt blue**, and ends with
   "Three-quarter view from the front-left, camera raised about 35 degrees, the whole
   [vehicle/structure] visible and centred, plain flat light grey background, soft even
   studio light, no cast shadow, no ground, no text, no people."
2. **3D model:** Tripo H3.1 image-to-3D (`tripo_h3_1_image_to_3d`), standard quality,
   `face_limit` 8000 (10000 for the foundry and the trading post). The raw GLB is about
   4 MB with colour, ORM and normal maps.
3. **Clean-up:** `tools/blender/clean_generated.py` turns the cobalt blue faces into the
   `TeamColor` material, keeps one 1024 px base-colour JPEG, turns and scales the model and
   (gunship) adds spinning rotor blades. Result: 7.4k to 9k triangles, 0.3 to 0.6 MB.
   Since 2026-10-11 (the tank remake below) the script also keeps a 1024 px normal map, puts
   team colour on upward-facing faces only, and can cut out a separate `Turret` (see
   docs/art-direction.md). The models above were cleaned before that and have no normal map.
4. **Size in game:** `model_scale` in `data/units/<id>.json` from
   `tools/art/fit_model_scale.gd` (same length as the model it replaced, which stays as
   `classic_model` for Options > Unit models > Classic). Three were then
   set by eye: gunship 0.8, rocket technical 0.9, SAM site 0.7.

| Model | Faction | Subject (prompt core) | Clean-up flags |
| --- | --- | --- | --- |
| `units/battle_tank.glb` | Foundry | super-heavy MBT, long 140 mm gun, slat armour; turret and skirt plates blue | `--yaw 90` |
| `buildings/bunker.glb` | Foundry | round squat concrete bunker, firing slit, sandbags, olive gun cupola; cupola band blue | `--yaw 90` |
| `buildings/flak_tower.glb` | Foundry | short round concrete tower, twin flak cannons on a railed platform; gun shield blue | `--yaw 180` |
| `buildings/foundry.glb` | Foundry | steel foundry on a concrete pad, blast furnace, brick chimneys, molten metal; roof edges blue | `--yaw 180` |
| `units/rocket_technical.glb` | Syndicate | desert pickup with a 12-tube rocket pod; doors and pod sides blue | `--yaw 90` |
| `units/gunship.glb` | Syndicate | attack helicopter with stub wings and rocket pods, shown without rotor blades; wings and fin blue | `--yaw 90 --rotors` |
| `buildings/gun_nest.glb` | Syndicate | circular sandbag and scrap-steel nest, HMG behind a shield, canvas shade; shield blue | `--yaw 180` |
| `buildings/sam_site.glb` | Syndicate | turntable with four missile tubes on a sandbagged pad, radar dish; launcher sides blue | `--yaw 90` |
| `buildings/trading_post.glb` | Syndicate | adobe trade house, market stalls, crates, containers, loading crane; awnings blue | `--yaw 180` |

All were run with `--length 2`. Facing: vehicles and turret guns point along Blender +Y
(Godot -Z); buildings are turned so the side shown in the concept faces the game camera.

```sh
python3 tools/blender/clean_generated.py -- --in raw/gunship.glb \
    --out assets/models/ironbound/units/gunship.glb --yaw 90 --length 2 --rotors \
    --render /tmp/previews/gunship
```

## Player buildings

The player buildings got the same treatment on 2026-10-06 (126 credits for 12). They are in
`buildings/generated/` because their old models keep their names as `classic_model`. The
airport and the shipyard had no model of their own, so their `classic_model` is their old
geometry scene (`source/match/units/structure-geometries/*.tscn`).

Prompts use one neutral Grounded palette (weathered sand-beige concrete, dusty tan
corrugated steel, faded olive trim, rust streaks) because both factions build them, and the
same opening and closing sentences as above. Tripo `face_limit` 10000. All were cleaned with
`--yaw 180 --length 2`; `model_scale` comes from `tools/art/fit_model_scale.gd` (the pylon
set by eye to 0.7).

| Model | Subject (prompt core) | Team colour |
| --- | --- | --- |
| `command_center.glb` | two-storey sloped concrete block, control tower, radar dish, helipad roof | roof edge, tower cap |
| `vehicle_factory.glb` | corrugated assembly hall, roll-up door with ramp, gantry rail, exhaust stacks | door frame, roof ridge |
| `aircraft_factory.glb` | curved-roof hangar, control cabin, helipad with landing circle, fuel tanks | door edges, helipad circle |
| `mine.glb` | lattice headframe with winding wheel, winch house, conveyor to an ore hopper, carts | winch house roof, hopper |
| `oil_derrick.glb` | pumpjack, short drilling tower, two storage tanks, pipes | walking beam, tank bands |
| `lumber_mill.glb` | open saw shed, circular saw, log conveyor, plank stacks, log pile | roof edge, saw housing |
| `power_plant.glb` | concrete cooling tower, generator hall, two chimneys, transformers | tower rim, hall roof trim |
| `solar_plant.glb` | three rows of tilted panels, inverter hut, fence | hut roof and door |
| `pylon.glb` | lattice transmission tower, insulators, transformer box | transformer, top cross arm |
| `storage.glb` | corrugated warehouse with loading dock, containers, pallets, forklift | roll-up door, one container |
| `shipyard.glb` | concrete quay with slipway, boat hull on blocks, dock crane, workshop | crane cab, workshop roof edge |
| `airport.glb` | short runway, round-roofed hangar, control tower with radar, fuel truck | tower cab, hangar door frame |

The raw downloads and concept images are not in the repository (they are 4 MB each).

## The tank (2026-10-11)

The Foundry tank, the hero unit every other unit is matched against, was remade as a modern
light main battle tank (Leopard 1 / M60 style). 10.5 credits: 1.5 for two concept images, 9
for the 3D model. Concept B was picked.

- **Prompt core:** low, wide, angular hull with side skirts over six road wheels; a
  wedge-shaped turret clearly separate from the hull on a visible turret ring; a long gun with
  a bore evacuator and muzzle brake; commander's cupola and roof machine gun; turret stowage
  baskets. Muted olive drab with desert dust. Only the turret roof and the engine deck are
  cobalt blue.
- **Tripo:** `face_limit` 5000 (art-direction budget for units is 1k to 6k). It returned 4,762
  triangles; the clean-up decimates to 3,600, the old tank's count. In
  `tests/perf/UnitModelBench.tscn` (llvmpipe) 30 copies at 4,762 cost about 75 ms against 64 ms
  at 3,600, and the two look the same at the closest zoom.
- **Clean-up:**

```sh
python3 tools/blender/clean_generated.py -- --in raw/tank.glb \
    --out assets/models/ironbound/units/tank.glb --yaw 90 --length 1.75 --max-tris 3600 \
    --turret 0.41 --turret-front 0.14 --barrel-width 0.06 --barrel-scale 1.6 \
    --team-smooth 2 --saturation 1.35
```

`--turret 0.41` is the hull roof height in metres after scaling: every face above it, except
those in front of the turret body (`--turret-front`) and off the gun's centre line
(`--barrel-width`), goes to `Turret`, whose origin is on the turret ring. That is the node
`TurretAim.gd` traverses. `--length 1.75` (gun included) makes the hull 1.37 m long, about 10% longer
than the old tank model, so `model_scale` stays 2.575 and the unit's footprint barely changes. The last three flags came out of the review at play
zoom: the generated gun was a thin line (`--barrel-scale`), the concept's dirt left olive holes
in the team-colour panels (`--team-smooth`), and the dusty paint sank into the desert sand
(`--saturation`).

The raw Tripo download is kept outside the repository, in the project's shared files
(`game/modern/tank/tank_raw_concept_b.glb`).

