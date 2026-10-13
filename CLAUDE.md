# How to work on Ironbound

## Read first, every session
docs/art-direction.md, docs/feel.md, and this file.

## Scope
- FEATURES ARE FROZEN until the feel layer of existing units is done.
- One concern per PR. Small. main stays releasable. Delete dead branches.
- Prefer editing data/*.json over writing new GDScript when tuning.
- Prefer deleting duplicates (pipelines, models, looks) over adding new ones.

## Proof before "done"
Every task ends with evidence, or it isn't done:
- art: before/after screenshots (ArtGallery + UnitModelCompare) + tri count + bench fps
- logic: the relevant test + validator must pass, paste the output
- never claim something works without running it

## References
- Work from a reference image, not memory. Ask me to choose when ambiguous.
- Match the hero unit (the tank) for scale, material, and silhouette quality.

## Self-critique loop (art tasks)
build -> render -> list the 10 biggest gaps vs the reference, harshly ->
fix the top 3 -> attach before/after.

## Do not touch without asking
Core simulation, pathing/navmesh, the test suite, save format, exports.

## Decision log
Append notable choices and the reason to docs/decisions.md so the next
session knows why.
