"""Synthesizes the combat layer on top of make_war_sounds.py: a report per weapon type,
shell casings, impacts by what was hit, explosion tails and deaths by size.

- mg_1..3: machine-gun bursts (raiders, buggies, gun nests, APCs),
- autocannon_1..2: a flak gun's quick heavy thumps,
- artillery_1..2: a rocket-artillery salvo: launch thumps and a long roar,
- missile_1..2: an anti-air missile: ignition crack and a rising scream,
- casing_1..3: spent casings and shells ringing on the ground or the hull,
- impact_armor_1..3: a round on armour: a clang and a ricochet,
- impact_building_1..2: a round into concrete and brick: a crunch and falling chips,
- impact_soft_1..2: a round into sandbags and earth near infantry: a dull thud and dust,
- explosion_tail_1..2: the rolling echo that follows a big explosion off the hills,
- death_infantry_1..3: a squad hit: bodies and gear going down (no voices),
- death_aircraft_1..2: an aircraft going down: a falling engine whine.

Like make_war_sounds.py, everything is built from noise and sine waves with numpy, so the
sounds are original work released under the project's license.

    python3 tools/audio/make_combat_sounds.py      # writes assets/audio/war/*.ogg

Needs numpy and ffmpeg (with libvorbis).
"""

import numpy as np

import make_war_sounds as war
from make_war_sounds import RATE, boom, crack, debris, filtered_noise, lowpass, outdoor_tail, times

rng = np.random.default_rng(1357)
war.rng = rng  # filtered_noise, debris and outdoor_tail draw from this too


def bandpass(signal, low, high, slope=1.0):
    n = len(signal)
    freqs = np.maximum(np.fft.rfftfreq(n, 1.0 / RATE), 1.0)
    spectrum = np.fft.rfft(signal)
    spectrum *= 1.0 / (1.0 + (low / freqs) ** (2 * slope))
    spectrum *= 1.0 / (1.0 + (freqs / high) ** (2 * slope))
    return np.fft.irfft(spectrum, n)


def add(out, sound, start):
    end = min(start + len(sound), len(out))
    if start < end:
        out[start:end] += sound[: end - start]


def mg_burst(rounds):
    gap = rng.uniform(0.07, 0.085)  # about 13 rounds a second
    out = np.zeros(int((gap * rounds + 0.5) * RATE))
    for k in range(rounds):
        t = times(0.18)
        shot = 0.9 * crack(t, 90.0) + 0.6 * boom(t, 420, 120, 40.0)
        shot += 0.25 * filtered_noise(len(t), 2000, 7000) * np.exp(-t * 200)  # bolt clack
        add(out, shot * rng.uniform(0.8, 1.0), int((k * gap + rng.uniform(0, 0.004)) * RATE))
    return outdoor_tail(out, 0.9, 5.0, 0.3)


def autocannon():
    rounds = rng.integers(3, 5)
    gap = rng.uniform(0.16, 0.2)
    out = np.zeros(int((gap * rounds + 0.9) * RATE))
    for k in range(rounds):
        t = times(0.5)
        shot = boom(t, 260, 70, 14.0) + 0.6 * crack(t, 50.0)
        shot += 0.5 * filtered_noise(len(t), 80, 1800) * np.exp(-t * 18)
        add(out, shot * rng.uniform(0.85, 1.0), int(k * gap * RATE))
    return outdoor_tail(out, 1.2, 3.5, 0.35)


def rocket_roar(length, rise):
    t = times(length)
    roar = filtered_noise(len(t), 150, 3500)
    sweep = np.sin(2 * np.pi * np.cumsum(200 + rise * t) / RATE)
    envelope = np.clip(t / 0.04, 0, 1) * np.exp(-t * (2.2 / length))
    return roar * envelope * (0.75 + 0.25 * sweep)


def artillery_salvo():
    rockets = rng.integers(3, 5)
    out = np.zeros(int(3.6 * RATE))
    for k in range(rockets):
        start = int((k * rng.uniform(0.22, 0.32)) * RATE)
        t = times(1.8)
        launch = 1.0 * boom(t, 160, 40, 6.0) + 0.5 * crack(t, 40.0)
        add(out, launch + 0.6 * rocket_roar(1.8, 600), start)
    return outdoor_tail(out / rockets ** 0.5, 2.0, 1.8, 0.4)


def missile():
    t = times(1.6)
    ignition = 0.8 * crack(t, 70.0) + 0.6 * boom(t, 300, 90, 20.0)
    scream = np.sin(2 * np.pi * np.cumsum(900 + 1600 * t) / RATE) * np.exp(-t * 1.6)
    scream *= np.clip(t / 0.08, 0, 1) * 0.25
    return outdoor_tail(ignition + 0.8 * rocket_roar(1.6, 1400) + scream, 1.0)


def ping(freq, decay, length=0.25):
    t = times(length)
    partials = [(1.0, 1.0), (2.76, 0.5), (5.4, 0.25)]  # a small brass tube
    return sum(w * np.sin(2 * np.pi * freq * r * t) for r, w in partials) * np.exp(-t * decay)


def casings():
    """casings falling: a few pings that bounce and settle"""
    out = np.zeros(int(0.9 * RATE))
    at = rng.uniform(0.05, 0.12)
    for k in range(rng.integers(3, 6)):
        add(out, ping(rng.uniform(2800, 4200), rng.uniform(30, 55)) * 0.8**k, int(at * RATE))
        at += rng.uniform(0.06, 0.16) * 0.8**k
    return out


def ricochet():
    t = times(0.45)
    freq = rng.uniform(2600, 3600) * np.exp(-t * rng.uniform(1.0, 2.0))
    whine = np.sin(2 * np.pi * np.cumsum(freq) / RATE) * np.exp(-t * 7.0)
    return whine * np.clip(t / 0.02, 0, 1)


def impact_armor():
    t = times(0.8)
    clang = sum(
        w * np.sin(2 * np.pi * f * rng.uniform(0.92, 1.08) * t)
        for f, w in [(620, 1.0), (1130, 0.7), (1890, 0.45), (2770, 0.3)]
    ) * np.exp(-t * 12.0)
    hit = 0.8 * crack(t, 90.0) + clang + 0.4 * boom(t, 200, 80, 25.0)
    if rng.random() < 0.7:
        whine = np.zeros(len(t))
        add(whine, ricochet() * 0.35, int(0.03 * RATE))
        hit += whine
    return outdoor_tail(hit, 0.7, 5.0, 0.25)


def impact_building():
    t = times(1.2)
    crunch = filtered_noise(len(t), 150, 4500) * np.exp(-t * 14.0)
    thud = boom(t, 140, 50, 14.0)
    chips = debris(t, 25, 0.04, 0.25)
    dust = filtered_noise(len(t), 800, 5000) * np.exp(-t * 4.0) * 0.12
    return outdoor_tail(0.9 * thud + 0.8 * crunch + 1.2 * chips + dust, 0.9)


def impact_soft():
    t = times(0.7)
    thud = boom(t, 110, 45, 18.0)
    earth = lowpass(filtered_noise(len(t), 80, 2500), 1800) * np.exp(-t * 16.0)
    patter = debris(t, 10, 0.06, 0.15) * 0.4
    return outdoor_tail(thud + 0.7 * earth + patter, 0.6, 5.0, 0.2)


def explosion_tail():
    """the echo rolling back off the hills a moment after a big blast"""
    length = 4.0
    t = times(length)
    rumble = filtered_noise(len(t), 25, 220, 1.5)
    rolls = np.zeros(len(t))
    for _ in range(5):  # a few reflections from different distances
        start = rng.uniform(0.05, 1.6)
        echo = boom(times(1.5), 80, 30, 2.5) * rng.uniform(0.3, 0.7)
        add(rolls, lowpass(echo, 300), int(start * RATE))
    envelope = np.clip(t / 0.25, 0, 1) * np.exp(-t * 1.1)
    return (0.7 * rumble + rolls) * envelope


def death_infantry():
    t = times(1.4)
    out = np.zeros(len(t))
    for k in range(rng.integers(2, 4)):  # bodies and kit hitting the ground
        fall = boom(times(0.3), 90, 50, 22.0) + 0.5 * lowpass(
            filtered_noise(int(0.3 * RATE), 100, 2500), 1500
        ) * np.exp(-times(0.3) * 20)
        add(out, fall * rng.uniform(0.6, 1.0), int(rng.uniform(0.05, 0.6) * RATE))
    gear = np.zeros(len(t))
    for _ in range(rng.integers(5, 9)):  # a rifle and a helmet clattering
        add(gear, ping(rng.uniform(900, 2200), rng.uniform(25, 45), 0.2) * 0.25,
            int(rng.uniform(0.1, 0.9) * RATE))
    return outdoor_tail(out + gear + debris(t, 6, 0.1, 0.2) * 0.4, 0.7, 5.0, 0.2)


def death_aircraft():
    """a falling engine: a whine dropping in pitch while the rotor or prop sputters"""
    length = 2.2
    t = times(length)
    freq = 1100 * np.exp(-t * 0.7) + 120
    whine = np.sin(2 * np.pi * np.cumsum(freq) / RATE)
    whine += 0.4 * np.sin(2 * np.pi * np.cumsum(freq * 2.01) / RATE)
    sputter = (np.sin(2 * np.pi * np.cumsum(9 + 6 * np.exp(-t)) / RATE) > 0.3).astype(float)
    air = filtered_noise(len(t), 300, 4000) * (0.4 + 0.6 * t / length)
    envelope = np.clip(t / 0.05, 0, 1) * np.clip((length - t) / 0.3, 0, 1)
    return (0.35 * whine * (0.6 + 0.4 * sputter) + 0.4 * air) * envelope


if __name__ == "__main__":
    for i in range(1, 4):
        war.write(f"mg_{i}", mg_burst(int(rng.integers(5, 9))))
        war.write(f"casing_{i}", casings(), 0.6)
        war.write(f"impact_armor_{i}", impact_armor())
        war.write(f"death_infantry_{i}", death_infantry())
    for i in range(1, 3):
        war.write(f"autocannon_{i}", autocannon(), 0.7)
        war.write(f"artillery_{i}", artillery_salvo())
        war.write(f"missile_{i}", missile())
        war.write(f"impact_building_{i}", impact_building())
        war.write(f"impact_soft_{i}", impact_soft())
        war.write(f"explosion_tail_{i}", explosion_tail(), 0.8)
        war.write(f"death_aircraft_{i}", death_aircraft(), 0.45)
