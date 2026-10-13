# Art Direction — source of truth

## Target feel
Modern military RTS readability with weight. Reference: Company of Heroes 1
(animation weight, destruction), StarCraft II (responsiveness, control),
Tempest Rising (unit read at zoom). NOT mobile, NOT programmer-art blocky.

## Canonical asset pipeline
ONE pipeline: concept image -> image-to-3D (Tripo/Higgsfield) ->
clean_generated.py -> game. Stop hand-coding bmesh for new units.
Procedural build_*.py is legacy; only patch it, don't extend it.

## Hard constraints (every unit must pass)
- Tri budget: units 1k-6k, buildings 2k-12k. Flag anything outside.
- ONE 1024px base-color texture + ONE normal map per unit. No more
  untextured vertex-color-only models.
- Silhouette must read at 60px tall in the game camera. Test with ArtGallery.
- Texel density consistent across all units (state px/m and enforce it).
- TeamColor on top-facing surfaces only, from the shared palette.
- Units face +Y in Blender.

## Scale
Keep the existing guide in tools/blender/README.md. Do not drift.

## Review loop (required on every art task)
1. Build the model.
2. Render tools/blender/previews + ArtGallery + UnitModelCompare.
3. List the 10 biggest gaps vs the reference. Be harsh.
4. Fix the top 3.
5. Attach before/after screenshots to the PR.

## Definition of done for a unit
Model + texture + normal + [walk/idle/death/recoil animations as applicable]
+ [muzzle flash + impact VFX] + voice + correct scale + passes validator.
