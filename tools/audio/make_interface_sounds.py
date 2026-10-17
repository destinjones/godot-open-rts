"""Synthesizes the interface sounds: what the menus and the HUD sound like.

- click_1 .. click_3: a button pressed: a short, dry mechanical tick with a little body,
- hover: the pointer moving onto a button: a very soft, high tick,
- toggle_on / toggle_off: a check box or switch flipped: a two-step latch, up or down,
- back: a menu closed or cancelled: a duller, lower tick,
- cannot: an order nobody can carry out: a short, dry double knock with a buzz,
- ping_attack: one of the player's units hit somewhere: two quick urgent blips,
- ping_mark: the player marks a spot on the minimap: one soft bright blip with a tail.

Like the other generators in this folder, everything is built from noise and sine waves with
numpy, so the sounds are original work released under the project's license.

    python3 tools/audio/make_interface_sounds.py      # writes assets/audio/interface/*.ogg

Needs numpy and ffmpeg (with libvorbis).
"""

import os

import numpy as np

import make_war_sounds as war
from make_war_sounds import RATE, filtered_noise, lowpass, times

rng = np.random.default_rng(24680)
war.rng = rng
war.OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "audio", "interface")


def place(target, sound, start):
    end = min(len(target), start + len(sound))
    target[start:end] += sound[: end - start]


def attack(t, seconds=0.0015):
    return np.clip(t / seconds, 0.0, 1.0)


def tick(freq, decay, length=0.08, body=0.5):
    """a small plastic and metal tick: a damped resonance over a burst of bright noise"""
    t = times(length)
    tone = np.sin(2 * np.pi * freq * t) + 0.4 * np.sin(2 * np.pi * freq * 2.7 * t)
    noise = filtered_noise(len(t), 1500, 9000) * np.exp(-t * 400)
    thump = np.sin(2 * np.pi * 180 * t) * np.exp(-t * 90) * body
    return (tone * np.exp(-t * decay) + 0.6 * noise + thump) * attack(t)


def click():
    out = np.zeros(int(0.12 * RATE))
    place(out, tick(rng.uniform(1900, 2300), rng.uniform(70, 90)), 0)
    place(out, tick(rng.uniform(1200, 1400), 120, body=0.2) * 0.35, int(0.018 * RATE))
    return out


def hover():
    t = times(0.05)
    tone = np.sin(2 * np.pi * 3200 * t) * np.exp(-t * 140)
    return (tone + 0.3 * filtered_noise(len(t), 4000, 10000) * np.exp(-t * 600)) * attack(t)


def toggle(up=True):
    out = np.zeros(int(0.16 * RATE))
    first, second = (1400, 2100) if up else (2100, 1400)
    place(out, tick(first, 90) * 0.7, 0)
    place(out, tick(second, 90), int(0.045 * RATE))
    return out


def back():
    out = np.zeros(int(0.14 * RATE))
    place(out, lowpass(tick(900, 60, 0.12, body=0.8), 3000), 0)
    return out


def cannot():
    t = times(0.26)
    # 220 Hz with its overtones up to 2.5 kHz, so it cuts through engines and a battle bed
    buzz = np.sign(np.sin(2 * np.pi * 220 * t)) * 0.5 + np.sin(2 * np.pi * 220 * t)
    buzz = lowpass(buzz, 2500) * np.exp(-t * 9)
    gate = ((t < 0.08) | ((t > 0.11) & (t < 0.2))).astype(float)
    out = buzz * gate * 0.6
    place(out, lowpass(tick(1100, 50, 0.1, body=0.6), 4000) * 0.8, 0)
    place(out, lowpass(tick(950, 50, 0.1, body=0.6), 4000) * 0.7, int(0.11 * RATE))
    return out


def blip(freq, length, decay):
    t = times(length)
    tone = np.sin(2 * np.pi * freq * t) + 0.25 * np.sin(2 * np.pi * freq * 2 * t)
    return tone * np.exp(-t * decay) * np.clip(t / 0.004, 0, 1)


def ping_attack():
    out = np.zeros(int(0.45 * RATE))
    for k, freq in enumerate((1320.0, 1320.0)):  # two quick urgent blips, E6
        place(out, blip(freq, 0.12, 22) + 0.5 * blip(freq * 1.5, 0.12, 30), int(k * 0.13 * RATE))
    return out


def ping_mark():
    out = np.zeros(int(0.7 * RATE))
    place(out, blip(1760.0, 0.6, 8) + 0.3 * blip(2637.0, 0.6, 12), 0)  # A6 with a fifth
    return out


if __name__ == "__main__":
    for i in range(1, 4):
        war.write(f"click_{i}", click(), 0.7)
    war.write("hover", hover(), 0.35)
    war.write("toggle_on", toggle(True), 0.7)
    war.write("toggle_off", toggle(False), 0.7)
    war.write("back", back(), 0.65)
    war.write("cannot", cannot(), 0.7)
    war.write("ping_attack", ping_attack(), 0.6)
    war.write("ping_mark", ping_mark(), 0.5)
