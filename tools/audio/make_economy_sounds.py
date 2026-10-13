"""Synthesizes the feedback of building and the economy:

- construction_loop: a site being built: hammering, a ratchet, a grinder, welding crackle,
- power_hum_loop: a power station and its grid: mains hum, a transformer buzz, crackle,
- factory_loop: a factory at work: a press, a conveyor, air tools,
- build_place: a blueprint becomes a site: stakes driven in and a crate set down,
- build_refused: a muted double buzz when a building cannot go there,
- build_complete: a building finished: two ringing hammer strikes and a bright chord,
- deposit_1 .. deposit_3: goods set down at a depot: a crate thump and a small chime,
- alert_economy: a two-note alarm chime ahead of the advisor's low-oil or storage-full call.

Like the other generators in this folder, everything is built from noise and sine waves with
numpy, so the sounds are original work released under the project's license.

    python3 tools/audio/make_economy_sounds.py      # writes assets/audio/economy/*.ogg

Needs numpy and ffmpeg (with libvorbis).
"""

import os

import numpy as np

import make_war_sounds as war
from make_war_sounds import RATE, boom, filtered_noise, loop_noise, lowpass, outdoor_tail, times

rng = np.random.default_rng(97531)
war.rng = rng
war.OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "audio", "economy")


def bandpass(signal, low, high, slope=1.0):
    n = len(signal)
    freqs = np.maximum(np.fft.rfftfreq(n, 1.0 / RATE), 1.0)
    spectrum = np.fft.rfft(signal)
    spectrum *= 1.0 / (1.0 + (low / freqs) ** (2 * slope))
    spectrum *= 1.0 / (1.0 + (freqs / high) ** (2 * slope))
    return np.fft.irfft(spectrum, n)


def place(target, sound, start):
    idx = (np.arange(len(sound)) + start) % len(target)
    np.add.at(target, idx, sound)


def metal(freq, decay, length=0.5, partials=((1.0, 1.0), (2.32, 0.6), (3.9, 0.35), (5.1, 0.2))):
    t = times(length)
    return sum(w * np.sin(2 * np.pi * freq * r * t + r) for r, w in partials) * np.exp(-t * decay)


def hammer(freq=None):
    t = times(0.3)
    strike = metal(freq or rng.uniform(700, 1300), rng.uniform(18, 30), 0.3)
    knock = filtered_noise(len(t), 300, 4000) * np.exp(-t * 80)
    return strike + 0.6 * knock


def construction(seconds=6.0):
    n = int(seconds * RATE)
    out = np.zeros(n)
    for _ in range(3):  # three workers hammering at their own pace
        pace = rng.uniform(0.38, 0.6)
        start = rng.uniform(0, seconds)
        for k in range(rng.integers(4, 8)):
            place(out, hammer() * rng.uniform(0.4, 0.8), int((start + k * pace) * RATE))
    for _ in range(2):  # a ratchet
        start = int(rng.uniform(0, seconds) * RATE)
        for k in range(10):
            click = filtered_noise(int(0.012 * RATE), 2000, 7000) * 0.3
            place(out, click, start + int(k * 0.035 * RATE))
    t = times(seconds)
    grinder_on = np.clip(np.sin(2 * np.pi * 2 * t / seconds + 1.0) * 3 - 2, 0, 1)
    grinder = bandpass(loop_noise(seconds, 2500, 6000, 1.5), 2500, 6000) * grinder_on
    grinder *= 1 + 0.3 * np.sin(2 * np.pi * 180 * t)
    weld_on = np.clip(np.sin(2 * np.pi * 3 * t / seconds + 4.0) * 3 - 2, 0, 1)
    weld = filtered_noise(n, 1500, 8000) * (rng.random(n) < 0.03) * weld_on * 2
    return out + 0.15 * grinder + 0.25 * weld


def power_hum(seconds=4.0):
    t = times(seconds)
    hum = sum(np.sin(2 * np.pi * 50.0 * k * t + k) / k**1.4 for k in (1, 2, 3, 4, 5, 6, 8))
    buzz = bandpass(np.sign(np.sin(2 * np.pi * 100.0 * t)), 400, 3000) * 0.25
    swell = 0.85 + 0.15 * np.sin(2 * np.pi * 3 * t / seconds)
    n = len(t)
    crackle = filtered_noise(n, 2000, 9000) * (rng.random(n) < 0.002) * 1.5
    return (0.6 * hum / np.abs(hum).max() + buzz) * swell + 0.2 * crackle


def factory(seconds=4.0):
    n = int(seconds * RATE)
    out = np.zeros(n)
    for k in range(4):  # a press stamping once a second
        t = times(0.6)
        stamp = boom(t, 120, 50, 12.0) + 0.5 * metal(rng.uniform(300, 420), 14, 0.6)
        stamp += 0.4 * filtered_noise(len(t), 200, 3000) * np.exp(-t * 30)
        place(out, stamp * 0.7, int(k * seconds / 4 * RATE))
    t = times(seconds)
    rollers = 8.0  # a conveyor: whole cycles per loop
    conveyor = bandpass(loop_noise(seconds, 150, 1500, 1.0), 150, 1500)
    conveyor *= 0.6 + 0.4 * (np.sin(2 * np.pi * rollers * t) > 0.6)
    for _ in range(3):  # air tools
        start = int(rng.uniform(0, seconds) * RATE)
        burst = filtered_noise(int(0.4 * RATE), 1500, 6000) * (
            1 + np.sin(2 * np.pi * 40 * times(0.4))
        ) * 0.2
        place(out, burst, start)
    return out + 0.25 * conveyor


def build_place():
    out = np.zeros(int(0.9 * RATE))
    for k, freq in enumerate([520, 610]):  # two stakes driven in
        place(out, metal(freq, 22, 0.4) * 0.6 + 0.4 * boom(times(0.4), 180, 70, 25), int(k * 0.11 * RATE))
    t = times(0.5)
    crate = boom(t, 140, 60, 20.0) + 0.5 * lowpass(filtered_noise(len(t), 100, 2000), 1500) * np.exp(-t * 30)
    place(out, crate * 0.7, int(0.3 * RATE))
    return outdoor_tail(out, 0.5, 8.0, 0.15)


def build_refused():
    t = times(0.36)
    tone = np.sign(np.sin(2 * np.pi * 150 * t)) * 0.5 + np.sin(2 * np.pi * 150 * t)
    tone = lowpass(tone, 1200)
    gate = ((t < 0.13) | ((t > 0.19) & (t < 0.32))).astype(float)
    return tone * gate * np.exp(-t * 2)


def chord(freqs, length, decay):
    t = times(length)
    out = sum(np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t) for f in freqs)
    return out * np.exp(-t * decay) * np.clip(t / 0.005, 0, 1)


def build_complete():
    out = np.zeros(int(1.8 * RATE))
    place(out, hammer(880) * 0.8, 0)
    place(out, hammer(1175) * 0.8, int(0.18 * RATE))
    place(out, chord([523.3, 659.3, 784.0], 1.4, 3.0) * 0.3, int(0.36 * RATE))  # C major
    return outdoor_tail(out, 0.8, 5.0, 0.2)


def deposit():
    t = times(0.5)
    thump = boom(t, 160, 70, 22.0) + 0.6 * lowpass(filtered_noise(len(t), 100, 3000), 2000) * np.exp(-t * 35)
    out = np.zeros(int(0.6 * RATE))
    place(out, thump * 0.8, 0)
    chime = chord([rng.choice([1046.5, 1174.7, 1318.5])], 0.4, 9.0) * 0.18
    place(out, chime, int(0.04 * RATE))
    return out


def alert_economy():
    out = np.zeros(int(0.9 * RATE))
    place(out, chord([880.0, 1108.7], 0.45, 6.0), 0)  # A, C# down to
    place(out, chord([659.3, 830.6], 0.6, 5.0), int(0.22 * RATE))  # E, G#
    return out


if __name__ == "__main__":
    war.write("construction_loop", construction(), 0.8)
    war.write("power_hum_loop", power_hum(), 0.4)
    war.write("factory_loop", factory(), 0.8)
    war.write("build_place", build_place(), 0.8)
    war.write("build_refused", build_refused(), 0.6)
    war.write("build_complete", build_complete(), 0.8)
    for i in range(1, 4):
        war.write(f"deposit_{i}", deposit(), 0.7)
    war.write("alert_economy", alert_economy(), 0.6)
