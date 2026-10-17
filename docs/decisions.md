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

## 2026-10-11: ticket 1 may change unit movement
Destin approved turn-to-face and acceleration/braking in the movement trait, which is core
simulation. Pathing, the navmesh and avoidance settings stay untouched, and
"turn_to_face": false in data/movement.json restores the old movement. Why: the instant facing
snap and constant speed were the main cause of the sliding feel, and a visual-only fix can't
remove them. Known cost: a tank ordered behind itself turns in place first and arrives about
1.3 s later (tracked turn rate 150°/s).

## 2026-10-11: onboarding cleared despite the feature freeze
Destin asked for the onboarding and first-run thread (guided first match, first-time
hints, tooltips, first-run defaults, searchable manual) explicitly, so it goes ahead while
features are otherwise frozen. It stays out of models, shaders, VFX, audio and the control
layer.

## 2026-10-11: tutorials are data, run through the play harness
The tutorial steps moved from a constant in Guide.gd to data/tutorial/*.json: standard.json
keeps the old ten steps for every Guided match, first_match.json is the guided first match
on the main menu. A step waits for one of a fixed list of conditions (Guide.CONDITIONS) and
may run play-harness orders when it starts (give, spawn, declare_war, camera), so new
tutorials need no code. The same script is played end to end by
tools/harness/scenarios/tutorial-first-match.json. Why: Destin asked for data, not
hard-coded cutscenes, and reusing the harness keeps one order format. Known gap: a save
made mid-tutorial resumes with the standard steps, because carrying the script name would
change the save format, which needs asking first.

## 2026-10-11: first-time hints are remembered in the options
A hint (HINT_*) now shows once ever, not once per match. The keys it has shown are kept
in Options (`seen_hints`, saved in options.tres), with a "Show first-time tips" switch and
a "Show all tips again" button on Options > Interface. Only a real game, one started from
source/Main.gd, writes them (FeatureFlags.remember_first_run), so tests and the play
harness never use up a player's hints. Alerts (unit cap, city full, raids) are not hints
and still repeat. Why: hints that come back every match read as nagging.

## 2026-10-11: build-menu tooltips are cards made from the building-card data
Build and production buttons open a rich hover card (RichTooltipButton + Tooltips.gd)
built from BuildingInfoText, the same source as the selection card: role, what it does,
needs, makes, health, the cost with what the player is short of, and why it is locked.
The plain tooltip_text (BuildMenu.describe) stays as the fallback. The controls thread
owns hud/ layout; this only swaps the button class and fills the tooltip. Why: one source
of truth for what a building does, and a locked or unaffordable button says why.

## 2026-10-11: first-run defaults and the intro card
On the very first launch the main menu shows a "What is Ironbound?" card (IntroCard.gd):
four lines on the game loop, then Play the tutorial or Go to the menu. Either answer sets
Options.intro_seen, so it shows once. The Play menu starts a new player on Plain & Simple
(small, open, 50x50) against an Easy AI, then remembers the last map and AI difficulty
(Options.last_map, last_ai_difficulty). Like the hints, only a real game writes these
(FeatureFlags.remember_first_run, renamed from remember_seen_hints). Why: the old default
was whichever two-player map sorted first, often a large or asymmetric one, against a
Normal AI; AoE4 and Northgard both point a new player at a guided match first.

## 2026-10-11: the manual is searchable and hints link into it
The F1 manual has a search box (Ctrl+F): it keeps the topics whose title or text holds
every word typed, title matches first, and marks the words. Each hint names its manual
topic (Guide.HINT_TOPICS) and shows a "Read more" button that opens it; alerts have none.
The "(F1: ...)" pointers in two hint texts went, the button replaces them. Known gap:
the camera polls W A S D, so typing in the search box also pans the map; the fix belongs
to the camera (control layer), passed to the controls thread.

## 2026-10-11: control and UX layer cleared despite the feature freeze
Destin asked for a second thread to bring the controls up to the StarCraft II standard
(docs/feel.md, "Control"), so it runs alongside the feel work instead of waiting for it. It
owns source/match/hud/ layout, input and camera handling; the art thread owns models,
shaders, VFX and the model fields in data/units/; the audio thread owns all sound, and the
onboarding thread owns translations, tooltips and the manual. Four PRs, one per area:
selection, orders, camera, feedback. Most of the list already existed (box select,
double-click, groups, attack-move, queued orders, rally points), so each PR only fills gaps.

## 2026-10-11: selection works like StarCraft II
A box over units and buildings takes only the units, so sweeping across the base grabs the
army; a box with only buildings still takes them. Ctrl + click selects all of a type on
screen, like a double-click. Shift + number adds to a group, and pressing a group's number
twice within 0.4 s centres the camera on it. The group bar sits top centre under the
diplomacy bar, because the bottom centre is taken by the unit card next to the minimap.

## 2026-10-11: audio and reactive soundscape cleared despite the feature freeze
Destin asked for the audio thread explicitly, so it ran alongside the feel work. It owns
data/sounds/, assets/audio/ and the playback code; Thread A owns voices.json entries for new
units. Five PRs (#57, #58, #60, #61, #64): an ambient bed, unit presence, combat density,
economy feedback, then spatialization and the mix. The full reasoning is in
docs/audio-soundscape.md ("Decisions"); the ones that shape later work:
- The ambient bed reads MusicPlayer's heat state instead of detecting threat itself, so the
  music and the world escalate together and there is one place to tune.
- Unit presence is one mixed loop per layer (engines, footsteps, rotors), not one per unit.
- Combat, economy and mix levels are data (data/sounds/*.json) keyed by unit id.
- Ducking is sidechain compressors on the buses, so the Options sliders stay in charge, and
  a crowd of sounds drops the quiet low-priority ones rather than whichever came last.
- Sounds are synthesized with numpy (tools/audio/), so they are original and regenerable.

## 2026-10-11: the tank is the first unit on the textured pipeline
The Foundry tank was remade from a GPT Image 2.5 concept through Tripo H3.1 and
tools/blender/clean_generated.py (Destin picked "modern light MBT", concept B). It keeps
one 1024 px base colour plus one normal map, team colour on upward faces only, and a
separate Turret node for TurretAim. It is decimated to 3,600 triangles, the old tank's
count, because 4,762 cost about 15% more frame time in UnitModelBench (llvmpipe) for no
visible gain at play zoom. Why: the art direction makes the tank the reference every other
unit is matched against, so it goes first. Known cost: still slower than the old
vertex-coloured tank on a software renderer (64 vs 50 ms for 30 copies); a real-GPU bench
is owed.

## 2026-10-11: rally points show where they send units
A selected factory now shows a dashed teal line from its edge to its rally point, and the
marker stays visible when the rally point follows a unit (it used to vanish). Dashed so it
does not read as an order the building carries out; teal so it is not confused with the
green move lines. Attack-move stays on F: A scrolls the camera (WASD), and controls.cfg
can rebind it for anyone who wants StarCraft II's A.

## 2026-10-11: the cursor says what a click will do
With units selected, the cursor turns into a red crosshair over an enemy they can attack and
a yellow build mark over an unfinished building a selected constructor can build; while
fight, patrol or guard waits for its click it shows that order's crosshair in the colour of
its ground line. An order nobody can carry out flashes a red "no" cursor and leaves a red
cross on the spot. The sound for it belongs to the audio thread: it can bind to
MatchSignals.units_ordered(units, "cannot"), which this layer only reacts to visually.
Cursors are tinted Kenney crosshairs (already in assets/ui), so no new art. The selection
box now reads the harness's virtual mouse too, and is green like the move lines.

## 2026-10-11: the camera follows the cursor, like StarCraft II
The mouse wheel zooms towards the cursor: the ground under it stays under it, and the zoom
glides over a fraction of a second instead of jumping a step. Edge scrolling eases in over
0.12 s and out over 0.08 s rather than starting and stopping dead. The minimap pings: a hit
on one of your units or buildings rings it red (one ping per 12 m spot every 6 s, so a fight
reads as one ping), and Alt + click marks a spot in yellow without moving the camera. A plain
click or drag on the minimap still jumps the camera. All the timings are exported on
IsometricCamera3D and constants in hud/MinimapPings.gd. Why: zoom-to-centre made you re-aim
after every wheel notch, and an attack off screen gave no sign at all. Pings have no sound
here; the audio thread can bind to MatchSignals.unit_damaged. Map keys (W, A, S, D, Q, E) are
ignored while a text field has focus, so typing into a search box no longer pans the map.

## 2026-10-13: the remade tank's cost is fine on a real GPU
The GPU bench owed by the tank remake (#56) ran on an RTX 3060 (Vulkan, Forward+, Godot
4.7.2) with UnitModelBench, 5 rounds of 300 frames. 30 copies cost 0.33 ms per frame with
the new tank against 0.31 ms with the pre-#56 tank (classic control 0.26 to 0.28 ms between
runs), so the gap is inside run-to-run noise. At 150 copies it is 0.78 against 0.60 ms, about
2.7 against 2.3 ms per frame in total, still several hundred fps. Why it matters: the 64 vs
50 ms gap on llvmpipe was texture and normal-map sampling that a software renderer
exaggerates, so the textured pipeline (one base colour plus one normal map per unit) stays
the plan for the other units and no decimation or texture cut is needed for the tank.

## 2026-10-17: supply drops give the middle of the map something to fight over
From about two minutes in, a crate parachutes down every 80 to 120 s somewhere between the
cities (at most two waiting at once), with a beacon and a yellow minimap ping. The first
ground unit to reach it takes it: goods (iron, copper, oil, timber), a repair of that
player's units around it, or experience for them when veterancy is on (goods otherwise).
Unclaimed crates vanish after 150 s. The AI sends its nearest free combat unit for a crate
within 40 m of it and keeps that unit out of its army meanwhile. Why: matches had long quiet
stretches with nothing to do outside the base; a crate is a small, visible reason to move out
and skirmish, and it rewards fast scouts. All numbers live in data/supply_drops.json; crates
are not saved (a loaded match just drops new ones), so the save format is untouched.

