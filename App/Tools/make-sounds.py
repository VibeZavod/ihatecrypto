#!/usr/bin/env python3
"""The notification sounds, drawn from numbers: `python3 App/Tools/make-sounds.py` writes Sources/IhatecryptoApp/Sounds/*.caf.

coin  — money arrived or a move finished: two quick metallic strikes, the second a fourth higher.
chime — something wants a look (an alert, a Confirm, a stop): two soft round notes going up.
knock — a move failed or was skipped: two low wooden knocks going down.

macOS keeps a sound it has played under its name: after changing one here, bump VERSION (and Notice.sound).
"""
import math, os, struct, subprocess, wave

RATE, VERSION = 44100, 1
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "IhatecryptoApp", "Sounds")


def strike(t, f, partials, attack=0.0015, glide=0.0):
    """One struck note: damped sines at f × ratio, each (ratio, amplitude, decay seconds); `glide` bends the pitch down."""
    if t < 0:
        return 0.0
    env = min(1.0, t / attack)
    s = 0.0
    for ratio, amp, tau in partials:
        freq = f * ratio * (1 - glide * min(1.0, t / 0.08))
        s += amp * math.exp(-t / tau) * math.sin(2 * math.pi * freq * t)
    return env * s


def render(name, notes, seconds, partials, glide=0.0):
    n = int(RATE * seconds)
    samples = [sum(strike(i / RATE - at, f, partials, glide=glide) * gain for at, f, gain in notes) for i in range(n)]
    fade = int(RATE * 0.03)
    for i in range(fade):
        samples[n - 1 - i] *= i / fade
    peak = max(abs(s) for s in samples) or 1
    wav = os.path.join(OUT, f"{name}.wav")
    with wave.open(wav, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(s / peak * 0.7 * 32767)) for s in samples))
    caf = os.path.join(OUT, f"{name}-{VERSION}.caf")
    subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16@44100", "-c", "1", wav, caf], check=True)
    os.remove(wav)
    print(caf)


os.makedirs(OUT, exist_ok=True)
# A small bar of metal: inharmonic partials (1, 2.76, 5.40) that die fast, so it rings like a coin, not a bell.
render("coin", [(0.0, 1760.0, 0.8), (0.085, 2349.3, 1.0)], 0.6, [(1.0, 1.0, 0.28), (2.76, 0.25, 0.08), (5.40, 0.06, 0.03)])
# Harmonic and slow: A5 then E6.
render("chime", [(0.0, 880.0, 0.9), (0.12, 1318.5, 1.0)], 0.8, [(1.0, 1.0, 0.35), (2.0, 0.15, 0.2), (3.0, 0.05, 0.1)])
# Low, short and bending down: E4 then B3.
render("knock", [(0.0, 329.6, 1.0), (0.13, 246.9, 0.9)], 0.55, [(1.0, 1.0, 0.12), (2.0, 0.3, 0.06), (3.9, 0.1, 0.03)], glide=0.03)
