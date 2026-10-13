# The soundscape

How Ironbound's world sounds, layer by layer, and why. The music, voices and war sounds
predate this page; it covers the reactive layers added on top of them. Tunables live in
`data/sounds/`, the files in `assets/audio/`, the generators in `tools/audio/`.

## Buses

Everything plays on one of the buses in `default_bus_layout.tres`, and each bus has its
Options slider: Music, Effects (weapons, explosions, one-shots), Voices (unit replies,
advisor, radio chatter) and Ambience (loops: wind, rain, engines, the ambient bed).
EffectsFar has no slider: it feeds Effects, so the Effects slider sets it too.

## Ambient bed (`source/match/environment/AmbientBed.gd`, `data/sounds/ambience.json`)

A bed under the whole match so the world is never silent between voice lines.

- **Tier bed**, one per city tier of the player on screen: open air, crickets and a far
  bird on the frontier; far machinery, a drop hammer and steam in the industrial tier;
  mains hum, a transformer buzz, relay clicks and traffic swells once electric. It
  crossfades over about 6 s when the city reaches a tier.
- **Threat layers**, following `MusicPlayer`'s calm/tension/battle state: tension adds a
  low rumble with far booms and the odd shot; battle adds distant gunfire, booms and a far
  siren, swelling with `MusicPlayer.intensity()`. The tier bed steps back (to 75 % under
  tension, 40 % in battle) so the threat reads.
- **Low oil** (below 8, from the industrial tier on) brings the tension layer in at a third
  of its level, without changing the music.
- Zoomed all the way out the bed is 25 % louder, as the local sounds (engines, city) fade.

Threat comes in fast (battle 1.5 s, tension 3 s) and leaves slowly (6 to 8 s), so a fight
does not cut off. Layers stop decoding when silent.

## Unit presence (`source/match/environment/Soundscape.gd`, `data/sounds/units.json`)

No unit is silent. Each unit id lists its presence layers: `tank_engine`, `truck_engine`,
`footsteps`, `rotor`, `rotor_wash`, `drone`, and `chatter`. Every layer is one loop mixed
from all units near the middle of the screen that use it, nearer ones counting more, so 40
tanks cost the same as one.

- Units on the move play the running loop (tank diesel with track clatter, wheeled engine,
  footsteps). Units at rest play an idle loop instead (a diesel ticking over, no tracks) at
  a share of the loudness; a squad standing still is quiet.
- Layers without an idle loop (rotor, drone) keep playing at rest, pitched down a little,
  and glide back up as the units move off.
- Units hidden in the fog of war make no presence sound, so they don't give themselves away.
- Now and then one of the player's units near the middle of the screen keys its radio:
  wordless chatter with squelch clicks, on the Voices bus, from where the unit stands.
  Every 9 to 18 s when calm, 5 to 10 s under tension, 3 to 6 s in battle.

## Combat (`source/match/environment/WarSounds.gd`, `data/sounds/combat.json`)

- **A report per weapon type**: rifle (militia), machine gun (raiders, buggies, gun nests,
  APCs), cannon, heavy cannon, autocannon (flak), rocket (helicopters, technicals), missile
  (anti-air), and rocket artillery salvos. A unit's report is looked up by its id.
- **Casings** ring after machine guns, autocannon and cannon now and then, only when the
  camera is close enough to hear them.
- **Impacts by surface**: rounds thud into the earth around infantry, clang and ricochet off
  armour, crunch into buildings. Cannon shells also keep their dirt-and-blast impact under
  the surface layer. Small arms are heard landing a third of the time, so a firefight is
  not wall-to-wall impacts.
- **Explosions tail off**: vehicles, heavy vehicles and buildings get a rolling echo off the
  hills half a second after the blast.
- **Deaths by size**: infantry (bodies and kit going down, no blast, no voices), light
  vehicles (a small blast), medium (a blast and a secondary), heavy (a bigger, slower double
  blast), aircraft (a falling engine whine), structures (blast, collapse, rubble).
  Each death is a list of `[delay, kind, loudness, pitch]` layers in the data.

## Building and the economy (`source/match/environment/EconomySounds.gd`, `data/sounds/economy.json`)

- **Build clangs**: laying out a site drives two stakes and sets a crate down (quieter for
  sites the helper lays out); a spot that is refused gives a muted double buzz; a finished
  building rings two hammer strikes and a bright chord.
- **Working buildings** are loops mixed from what is near the middle of the screen, like
  unit presence: sites hammer, grind and weld while someone is building them (and fall
  quiet when nobody is), factories with a queue stamp and rattle, and power stations and
  pylons on a live grid hum. In a brownout the hum sags in pitch.
- **Deposits**: goods reaching one of the player's depots near the camera are set down with
  a crate thump and a small chime (not every delivery, and at most every half second).
- **Callouts**: the advisor already says "low oil" and "storage full"; those calls now ring a
  two-note alarm chime first, so they stand out from routine news.

## Spatialization and the mix (`default_bus_layout.tres`, `data/sounds/mix.json`)

- **Panning.** Sounds are heard through a listener hovering over the middle of the screen,
  facing the way the camera does, so a shot on the left is heard on the left. The presence
  loops (engines, footsteps, rotors) are panned to the centre of the units making them, and
  the city loop to the nearest depot.
- **Falloff.** Loudness falls with the square of the distance from the middle of the
  screen, the hearing range grows as the camera zooms out, and everything is quieter
  zoomed out. Sounds past 45 % of the hearing range, and fights in the fog of war, play
  through the EffectsFar bus, which low-passes them at 1.6 kHz like air over distance.
- **Priority.** Every combat kind has a priority (0 casings, 1 small arms and impacts, 2
  cannon, rockets and small explosions, 3 big explosions, artillery and aircraft going
  down). Once six sounds have played within 0.15 s, a new one quieter than half the loudest
  of them is dropped unless it is priority 3. When all 24 voices are busy, the lowest
  priority, quietest voice is cut for a more important sound.
- **Ducking.** Compressors sidechained in the bus layout: the music and the ambience duck
  under the Effects bus, so a big battle pushes them down and a lone shot barely does; the
  effects duck a little under Voices, so the advisor and unit replies stay clear.
- **Limiter.** A hard limiter on Master (ceiling -0.5 dB) catches what still piles up.

## Checks and clips

- `tests/audio/AmbientBedCheck.tscn` checks the bed against MusicPlayer's state machine.
- `tests/audio/UnitPresenceCheck.tscn` checks idle and moving units on a test map.
- `tests/audio/CombatSoundsCheck.tscn` checks every unit's report, death and surface.
- `tests/audio/WarSoundsCheck.tscn` stages a battle and checks it is heard.
- `tests/audio/EconomySoundsCheck.tscn` builds a power plant and checks each feedback.
- `tests/audio/MixCheck.tscn` checks the bus effects, the far bus and masking in a crowd.
- `tests/audio/SoundClip.tscn -- --clip=<name>` records a clip of a scripted timeline with
  Godot's movie maker, for pull requests (see its header).

## Decisions

- **The bed follows MusicPlayer, it does not run its own threat detection.** One heat
  model for music and ambience keeps them in step and leaves one place to tune. MusicPlayer
  only gained `intensity()` and `state_name()`.
- **Synthesized, not sampled.** Like the rest of the game's audio, the beds are generated
  with numpy so they are original work under the project's license and can be regenerated.
- **Low oil changes the ambience, not the music.** Economy stress is real but not a
  fight; switching to the tension track for it would make the music lie about combat.
- **Presence is one loop per layer, not one per unit.** Forty units each running a 3D loop
  would be mush and cost forty decoders; a mixed loop per layer stays clear and cheap. The
  per-unit detail lives in the one-shots (weapons, chatter).
- **Chatter is wordless.** The voice sets only have reply lines (select, move, attack);
  playing those unprompted would sound like orders nobody gave.
- **Combat sounds are keyed by unit id in data**, replacing the scene-name lists in
  WarSounds. Units built on another unit (scout buggy, gun nest) get their own report
  instead of their base unit's.
- **Infantry deaths have no screams.** Bodies and gear going down read clearly at RTS
  distance, and keep the game's tone.
- **Callouts stay spoken.** Low oil and storage full already had advisor lines; adding a
  second, non-verbal callout would double them, so they gained a chime instead.
- **Ducking is done by sidechain compressors, not by code.** They follow what is actually
  loud, cost nothing in scripts, and leave the Options sliders (bus volumes) untouched.
- **Masking over a hard cap.** Dropping quiet low-priority sounds in a crowd keeps the
  close, important ones readable, which a plain voice cap does not: it would cut whichever
  came last.
- **Audio work was cleared during the feature freeze.** Destin asked for the audio thread
  explicitly (2026-10-11), so it runs alongside the feel tickets.
