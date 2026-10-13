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

## Checks and clips

- `tests/audio/AmbientBedCheck.tscn` checks the bed against MusicPlayer's state machine.
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
- **Audio work was cleared during the feature freeze.** Destin asked for the audio thread
  explicitly (2026-10-11), so it runs alongside the feel tickets.
