# Decisions

Notable choices and the reason for each, newest last, so the next session knows why.

## 2026-10-11: art direction, feel spec and working agreement
docs/art-direction.md, docs/feel.md and CLAUDE.md are the source of truth for art and feel
work. Features are frozen until the feel layer of existing units is done. The feel work runs
as six tickets, one vertical slice per PR, in this order: turn-to-face with accel/brake,
death animations with persistent wrecks, weapon VFX, recoil and turret lead, screen shake
and hit feedback, then the textured pipeline starting with the tank. Why: "make it modern"
gave no target to measure against; the docs are the ruler and screenshots the measurement.

## 2026-10-11: HUD redesign and onboarding parked
A HUD declutter and first-five-minutes pass (intro camera, quick battle, delayed AI offers)
were started and then stopped. Why: they are new features, and features are frozen until
the feel layer is done.
