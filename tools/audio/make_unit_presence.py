"""Synthesizes the sounds units make just by being there, so none of them is ever silent.

- tank_idle_loop: a tracked vehicle's diesel ticking over, no track clatter,
- truck_idle_loop: a wheeled vehicle's engine at idle,
- footsteps_loop: a squad walking on dirt and gravel, with gear rattling,
- rotor_wash_loop: the downwash of a helicopter: dust and air beaten at the blade rate,
- chatter_1 .. chatter_6: short bursts of garbled radio talk, with squelch clicks.

The moving engines (tank_engine_loop, engine_hum_loop, rotor_loop, drone_loop) come from
make_war_sounds.py and make_soundscape.py. Like them, everything is built from noise and sine
waves with numpy, so the sounds are original work released under the project's license.

    python3 tools/audio/make_unit_presence.py      # writes assets/audio/units/*.ogg

Needs numpy and ffmpeg (with libvorbis).
"""

import os

import numpy as np

import make_war_sounds as war
from make_war_sounds import RATE, filtered_noise, loop_noise, lowpass, times

rng = np.random.default_rng(2468)
war.rng = rng  # filtered_noise draws from this too
war.OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "audio", "units")


def place(target, sound, start):
    """adds a sound at a sample index, wrapping around the end of a loop"""
    idx = (np.arange(len(sound)) + start) % len(target)
    np.add.at(target, idx, sound)


def bandpass(signal, low, high, slope=1.0):
    n = len(signal)
    freqs = np.maximum(np.fft.rfftfreq(n, 1.0 / RATE), 1.0)
    spectrum = np.fft.rfft(signal)
    spectrum *= 1.0 / (1.0 + (low / freqs) ** (2 * slope))
    spectrum *= 1.0 / (1.0 + (freqs / high) ** (2 * slope))
    return np.fft.irfft(spectrum, n)


def diesel_idle(seconds, fundamental, harmonics, knock):
    """an engine ticking over: a low tone with firing pulses and a slight lope"""
    t = times(seconds)
    # the lope: whole cycles per loop, so it repeats cleanly
    phase = 2 * np.pi * fundamental * t + 0.25 * np.sin(2 * np.pi * 2 * t / seconds)
    tone = sum(np.sin(k * phase + k * 1.3) / k**1.2 for k in range(1, harmonics))
    pulses = np.maximum(np.sin(phase / 2.0), 0.0) ** 10
    clatter = bandpass(rng.standard_normal(len(t)), 800, 3500) * pulses
    rumble = loop_noise(seconds, 20, 160, 1.5)
    out = 0.6 * tone / np.abs(tone).max() + 0.35 * pulses + 0.35 * rumble
    return out + knock * clatter / (np.abs(clatter).max() + 1e-9)


def tank_idle(seconds=4.0):
    return diesel_idle(seconds, 22.0, 12, 0.18)  # 22 Hz: whole cycles in 4 s


def truck_idle(seconds=4.0):
    return diesel_idle(seconds, 30.0, 9, 0.1)


def footstep():
    """one boot on dirt: a soft thud and a short gravel crunch"""
    t = times(0.16)
    thud = np.sin(2 * np.pi * rng.uniform(70, 110) * t) * np.exp(-t * 45)
    crunch = filtered_noise(len(t), 1200, 6000) * np.exp(-t * rng.uniform(28, 45))
    grains = (rng.random(len(t)) < 0.01) * rng.standard_normal(len(t)) * np.exp(-t * 20)
    return 0.7 * thud + 0.35 * crunch + 0.25 * grains


def footsteps(seconds=4.0):
    n = int(seconds * RATE)
    out = np.zeros(n)
    for soldier in range(6):
        pace = seconds / rng.integers(7, 9)  # whole steps per loop, about 2 per second
        offset = rng.uniform(0, pace)
        for k in range(int(seconds / pace)):
            start = int((offset + k * pace + rng.uniform(-0.02, 0.02)) * RATE)
            place(out, footstep() * rng.uniform(0.5, 1.0), start)
    rattle = np.zeros(n)
    for _ in range(int(seconds * 5)):  # canteens, rifles, buckles
        t = times(0.04)
        clink = np.sin(2 * np.pi * rng.uniform(2500, 4200) * t) * np.exp(-t * 160)
        place(rattle, clink * rng.uniform(0.1, 0.3), rng.integers(0, n))
    return out + 0.5 * rattle


def rotor_wash(seconds=4.0):
    t = times(seconds)
    blade_rate = 17.0  # the same chop as rotor_loop
    chop = (0.5 + 0.5 * np.cos(2 * np.pi * blade_rate * t)) ** 4
    air = loop_noise(seconds, 40, 500, 1.2)
    dust = loop_noise(seconds, 1500, 7000, 1.0)
    gust = 0.75 + 0.25 * np.sin(2 * np.pi * 3 * t / seconds)
    return (0.8 * air * (0.55 + 0.45 * chop) + 0.25 * dust * (0.7 + 0.3 * chop)) * gust


def babble(seconds):
    """speech-like but wordless: voiced pulses through moving formants, in syllables"""
    t = times(seconds)
    pitch = rng.uniform(95, 140) * (1 + 0.08 * np.sin(2 * np.pi * rng.uniform(1, 3) * t))
    phase = 2 * np.pi * np.cumsum(pitch) / RATE
    glottal = sum(np.sin(k * phase) / k for k in range(1, 30))
    syllable_rate = rng.uniform(4.0, 6.0)
    syllables = np.clip(np.sin(2 * np.pi * syllable_rate * t + rng.uniform(0, 6)), 0, None) ** 0.6
    words = (np.sin(2 * np.pi * 1.3 * t + rng.uniform(0, 6)) > -0.6).astype(float)
    out = np.zeros(len(t))
    # three formants that wander from syllable to syllable
    for low, high in [(300, 800), (900, 1800), (2000, 3000)]:
        centre = rng.uniform(low, high)
        band = bandpass(glottal, centre * 0.8, centre * 1.25, 2.0)
        out += band * (0.6 + 0.4 * np.sin(2 * np.pi * syllable_rate * 0.5 * t + rng.uniform(0, 6)))
    hiss = filtered_noise(len(t), 2500, 6000) * 0.15  # consonants
    return (out / (np.abs(out).max() + 1e-9) + hiss) * syllables * words


def squelch(length=0.07):
    t = times(length)
    return filtered_noise(len(t), 1500, 5000) * np.exp(-t * 60) * 0.6


def radio(signal):
    """a field radio: narrow band, a little distortion and static under it"""
    band = bandpass(signal, 400, 2800, 2.0)
    band = np.tanh(2.5 * band / (np.abs(band).max() + 1e-9))
    static = filtered_noise(len(band), 1000, 6000) * 0.06
    return band + static


def chatter():
    talk = radio(babble(rng.uniform(0.8, 1.6)))
    gap = np.zeros(int(0.05 * RATE))
    out = np.concatenate([squelch(), gap, talk, gap, squelch(0.12)])
    fade = np.ones(len(out))
    ramp = int(0.01 * RATE)
    fade[:ramp] = np.linspace(0, 1, ramp)
    fade[-ramp:] = np.linspace(1, 0, ramp)
    return out * fade


if __name__ == "__main__":
    war.write("tank_idle_loop", tank_idle(), 0.8)
    war.write("truck_idle_loop", truck_idle(), 0.8)
    war.write("footsteps_loop", footsteps(), 0.8)
    war.write("rotor_wash_loop", rotor_wash(), 0.8)
    for i in range(1, 7):
        war.write(f"chatter_{i}", chatter(), 0.8)
