# The soundscape

How Ironbound's world sounds, layer by layer, and why. The music, voices and war sounds
predate this page; it covers the reactive layers added on top of them. Tunables live in
`data/sounds/`, the files in `assets/audio/`, the generators in `tools/audio/`.

## Buses

Everything plays on one of the buses in `default_bus_layout.tres`, and each bus has its
Options slider: Music, Effects (weapons, explosions, one-shots), Voices (unit replies,
advisor) and Ambience (loops: wind, rain, engines, the ambient bed).

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

## Checks and clips

- `tests/audio/AmbientBedCheck.tscn` checks the bed against MusicPlayer's state machine.
- `tests/audio/UnitPresenceCheck.tscn` checks idle and moving units on a test map.
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
- **Audio work was cleared during the feature freeze.** Destin asked for the audio thread
  explicitly (2026-10-11), so it runs alongside the feel tickets.
