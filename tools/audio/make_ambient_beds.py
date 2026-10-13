"""Synthesizes the ambient beds: one per city tier and two threat layers.

The tier beds sit under the whole match and change as the player's city grows:
- bed_frontier: open air, crickets and the odd bird (tier 1),
- bed_industrial: far-off machinery, steam and hammering (tier 2),
- bed_electric: mains hum, a transformer buzz and traffic swells (tier 3).
The threat layers come in on top of them, following the music's calm/tension/battle state:
- bed_tension: a low rumble with far booms now and then,
- bed_battle: distant gunfire, close booms and a siren.

Everything is generated from noise and sine waves with numpy, so the sounds are original
work released under the project's license. Every loop wraps around without a click.

    python3 tools/audio/make_ambient_beds.py      # writes assets/audio/ambience/bed_*.ogg

Needs numpy and ffmpeg (with libvorbis).
"""

import numpy as np

import make_soundscape as base
from make_soundscape import RATE, band, loop_lfo, place_circular, shaped_noise, write

rng = np.random.default_rng(4321)
base.rng = rng  # shaped_noise and metal_hit draw from this too


def lowpass(signal, cutoff, slope=1.0):
    n = len(signal)
    spectrum = np.fft.rfft(signal)
    spectrum *= band(np.fft.rfftfreq(n, 1.0 / RATE), 1.0, cutoff, slope)
    return np.fft.irfft(spectrum, n)


def bandpass(signal, low, high, slope=1.0):
    n = len(signal)
    spectrum = np.fft.rfft(signal)
    spectrum *= band(np.fft.rfftfreq(n, 1.0 / RATE), low, high, slope)
    return np.fft.irfft(spectrum, n)


def chirp_train(freq, chirps, gap_s, chirp_s=0.018):
    """a cricket's call: a few short tone pulses"""
    t = np.arange(int(chirp_s * RATE)) / RATE
    pulse = np.sin(2 * np.pi * freq * t) * np.sin(np.pi * t / chirp_s) ** 2
    out = np.zeros(int((chirps * gap_s + chirp_s) * RATE) + 1)
    for k in range(chirps):
        start = int(k * gap_s * RATE)
        out[start : start + len(pulse)] += pulse
    return out


def bird_call():
    """two or three falling whistles"""
    notes = []
    for _ in range(rng.integers(2, 4)):
        length = rng.uniform(0.08, 0.18)
        t = np.arange(int(length * RATE)) / RATE
        f0 = rng.uniform(2200, 3400)
        f1 = f0 * rng.uniform(0.6, 0.85)
        freq = f0 + (f1 - f0) * t / length
        phase = 2 * np.pi * np.cumsum(freq) / RATE
        notes.append(np.sin(phase) * np.sin(np.pi * t / length) ** 1.5)
        notes.append(np.zeros(int(rng.uniform(0.05, 0.12) * RATE)))
    return np.concatenate(notes)


def frontier(seconds=24.0):
    n = int(seconds * RATE)
    air = shaped_noise(seconds, lambda f: band(f, 150, 1600, 1.0) / np.sqrt(np.maximum(f, 40)))
    air *= 0.8 + 0.2 * loop_lfo(n, seconds, [(1, 0.7), (3, 0.3)], 11)
    crickets = np.zeros(n)
    for voice in range(3):  # three crickets at different pitches and speeds
        freq = [4300, 4900, 5600][voice]
        period = rng.uniform(0.7, 1.3)
        for k in range(int(seconds / period)):
            if rng.random() < 0.25:  # pauses, so it never sounds like a metronome
                continue
            start = int((k * period + rng.uniform(0, 0.08)) * RATE)
            call = chirp_train(freq, rng.integers(3, 5), 0.045) * [0.5, 0.35, 0.25][voice]
            place_circular(crickets, call, start)
    crickets *= 0.6 + 0.4 * np.clip(loop_lfo(n, seconds, [(2, 1.0)], 12), -1, 1)
    birds = np.zeros(n)
    for _ in range(4):
        place_circular(birds, bird_call() * rng.uniform(0.3, 0.6), rng.integers(0, n))
    birds = bandpass(birds, 1500, 4500)  # far away
    return 0.9 * air + 0.22 * crickets + 0.3 * birds


def thump(length=1.2, low=40.0, high=180.0):
    """a far explosion or a heavy press: a low thud with a rumbling tail"""
    m = int(length * RATE)
    t = np.arange(m) / RATE
    body = rng.standard_normal(m) * np.exp(-t * rng.uniform(4.0, 6.0))
    body = bandpass(body, low, high, 1.5)
    sub = np.sin(2 * np.pi * rng.uniform(38, 55) * t) * np.exp(-t * 7.0)
    return body / (np.abs(body).max() + 1e-9) + 0.6 * sub


def steam_hiss(length):
    m = int(length * RATE)
    t = np.arange(m) / RATE
    hiss = bandpass(rng.standard_normal(m), 2500, 7000)
    envelope = np.clip(t / 0.06, 0, 1) * np.clip((length - t) / 0.4, 0, 1)
    return hiss / (np.abs(hiss).max() + 1e-9) * envelope


def industrial(seconds=24.0):
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    # a mill turning over: a low machine tone with a slow, whole-cycle wobble
    phase = 2 * np.pi * (31.0 * t + 0.4 * np.sin(2 * np.pi * 2 * t / seconds))
    machine = sum(np.sin(k * phase + k * 0.7) / k**1.3 for k in range(1, 8))
    machine *= 0.8 + 0.2 * np.sin(2 * np.pi * 12 * t / seconds)
    murmur = shaped_noise(seconds, lambda f: band(f, 60, 400, 1.3))
    events = np.zeros(n)
    for _ in range(int(seconds * 0.5)):  # clanks across the yards
        place_circular(events, base.metal_hit() * rng.uniform(0.2, 0.45), rng.integers(0, n))
    for _ in range(3):  # a drop hammer working
        start = rng.integers(0, n)
        for k in range(rng.integers(4, 7)):
            place_circular(events, thump(0.5, 60, 300) * 0.35, start + int(k * 0.9 * RATE))
    events = lowpass(events, 1400)
    hiss = np.zeros(n)
    for _ in range(3):
        place_circular(hiss, steam_hiss(rng.uniform(0.8, 1.6)) * 0.12, rng.integers(0, n))
    return 0.35 * machine / np.abs(machine).max() + 0.5 * murmur + 0.9 * events + hiss


def electric(seconds=24.0):
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    mains = sum(np.sin(2 * np.pi * 50.0 * k * t + k) / k**1.6 for k in (1, 2, 3, 4, 6))
    buzz = np.sign(np.sin(2 * np.pi * 100.0 * t)) * 0.15  # transformer buzz
    buzz = bandpass(buzz, 300, 2500)
    buzz *= 0.7 + 0.3 * loop_lfo(n, seconds, [(3, 1.0)], 21)
    traffic = shaped_noise(seconds, lambda f: band(f, 60, 500, 1.5))
    swells = np.clip(loop_lfo(n, seconds, [(2, 0.6), (5, 0.5), (9, 0.3)], 22), 0, None)
    traffic *= 0.35 + swells
    clicks = np.zeros(n)
    click = rng.standard_normal(int(0.008 * RATE)) * np.exp(-np.arange(int(0.008 * RATE)) / 40.0)
    for _ in range(int(seconds * 0.4)):  # relays and switchgear
        place_circular(clicks, click * rng.uniform(0.2, 0.5), rng.integers(0, n))
    clicks = bandpass(clicks, 800, 5000)
    return 0.25 * mains + 0.5 * buzz + 0.6 * traffic + 0.4 * clicks


def tension(seconds=24.0):
    n = int(seconds * RATE)
    rumble = shaped_noise(seconds, lambda f: band(f, 25, 140, 2.0))
    rumble *= 0.65 + 0.35 * loop_lfo(n, seconds, [(1, 0.6), (3, 0.4)], 31)
    booms = np.zeros(n)
    for _ in range(5):  # artillery over the horizon
        place_circular(booms, thump(2.0, 30, 140) * rng.uniform(0.4, 0.8), rng.integers(0, n))
    shots = np.zeros(n)
    for _ in range(6):  # a few far shots
        place_circular(shots, gunshot() * rng.uniform(0.15, 0.3), rng.integers(0, n))
    shots = lowpass(shots, 1200)
    return 0.8 * rumble + 0.8 * booms + 0.5 * shots


def gunshot():
    m = int(0.25 * RATE)
    t = np.arange(m) / RATE
    crack = rng.standard_normal(m) * np.exp(-t * rng.uniform(35, 60))
    return bandpass(crack, 300, 3000)


def burst(rounds, gap_s):
    out = np.zeros(int((rounds * gap_s + 0.3) * RATE))
    shot = gunshot()
    for k in range(rounds):
        start = int(k * gap_s * rng.uniform(0.9, 1.1) * RATE)
        out[start : start + len(shot)] += shot * rng.uniform(0.6, 1.0)
    return out


def siren(seconds, n):
    """a slow wailing siren far away, whole cycles per loop"""
    t = np.arange(n) / RATE
    wail = 0.5 - 0.5 * np.cos(2 * np.pi * 3 * t / seconds)
    freq = 520 + 260 * wail
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    tone = np.sin(phase) + 0.3 * np.sin(2 * phase) + 0.15 * np.sin(3 * phase)
    return tone * (0.4 + 0.6 * wail)


def battle(seconds=24.0):
    n = int(seconds * RATE)
    rumble = shaped_noise(seconds, lambda f: band(f, 25, 180, 2.0))
    rumble *= 0.75 + 0.25 * loop_lfo(n, seconds, [(2, 0.6), (5, 0.4)], 41)
    booms = np.zeros(n)
    for _ in range(12):
        place_circular(booms, thump(1.6, 35, 200) * rng.uniform(0.35, 0.9), rng.integers(0, n))
    fire = np.zeros(n)
    for _ in range(30):  # machine guns and rifles, near and far
        fire_burst = burst(rng.integers(3, 12), rng.uniform(0.07, 0.14))
        place_circular(fire, fire_burst * rng.uniform(0.2, 0.6), rng.integers(0, n))
    fire = lowpass(fire, 2200)
    wail = bandpass(siren(seconds, n), 300, 2400)
    return 0.7 * rumble + 0.9 * booms + 0.7 * fire + 0.06 * wail


if __name__ == "__main__":
    write("bed_frontier", frontier(), 0.7)
    write("bed_industrial", industrial(), 0.7)
    write("bed_electric", electric(), 0.7)
    write("bed_tension", tension(), 0.75)
    write("bed_battle", battle(), 0.8)
