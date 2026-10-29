#!/usr/bin/env python3
"""Make replacements for the stock Half-Life sounds in sounds/, one recipe per sound.

  sound_art.py [NAME ...]            make the named sounds (all of them when none are given)
  sound_art.py --sheet OUT [NAME]    original and replacement spectrograms side by side, as a PNG

NAME is the path under sounds/ without .wav, e.g. ambience/drips. Every replacement keeps its
original's sample rate, sample width and channel count, and is scaled to the original's
loudness. A sound with a cue point is one GoldSrc loops (the port's ambient_generic restarts it
when it ends), so it is made the original's exact length, seamless end to start, and keeps the
cue point. Byte-identical copies of a stock sound that the mod shipped under its own names
(TWINS) are rewritten with the same new file. The originals are read from git, as they stood
just before this script first replaced them (STOCK).

Three kinds of recipe:
  synthesized   from noise and oscillators, here
  recorded      CC0 recordings from freesound.org, downloaded once into build/freesound/ (each
                sound page is checked for the CC0 licence first), then cut and shaped here
  spoken        Kokoro-82M (Apache-2.0) speaking phonemes written below; its model files go in
                build/kokoro/ (kokoro-v1.0.onnx and voices-v1.0.bin from the kokoro-onnx
                releases on GitHub)
sounds/CREDITS.md lists every sound this script made and where each recording came from.
Needs numpy, scipy and ffmpeg; kokoro-onnx for the spoken ones; Pillow for --sheet.
"""

import os
import re
import struct
import subprocess
import sys
import urllib.parse
import urllib.request
import zlib
from fractions import Fraction

import numpy as np
from scipy import signal

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOUNDS = os.path.join(ROOT, "sounds")
CACHE = os.path.join(ROOT, "build", "freesound")
KOKORO = os.path.join(ROOT, "build", "kokoro")
W = 44100  # recipes work at this rate; the result is resampled to the original's
TAU = 2 * np.pi

# Stock sounds the mod also shipped under its own names, byte for byte.
TWINS = {
    "ambience/biggun3": ["spells/combos/comet_hit", "spells/combos/meteor_hit", "spells/fissure_boom"],
    "ambience/burning1": ["spells/satchels/pyro_spiral"],
    "ambience/explode3": ["weapons/explode3"],
    "ambience/goal_1": ["ambience/disco"],
    "ambience/wind1": ["spells/levitate"],
    "items/gunpickup2": ["weapons/scock1", "UI/buttonrollover", "spells/satchels/life_satchel"],
    "zombie/claw_strike3": ["spells/staff_hitbod3", "monster/thornplant/thornplant_shoot"],
}


# ---- wav files ----

class Wav:
    def __init__(self, sr, bits, ch, x, cue):
        self.sr, self.bits, self.ch, self.x, self.cue = sr, bits, ch, x, cue


def parse_wav(data):
    i, fmt, pcm, cue = 12, None, b"", False
    while i + 8 <= len(data):
        cid, size = data[i:i + 4], struct.unpack_from("<I", data, i + 4)[0]
        if cid == b"fmt ":
            fmt = struct.unpack_from("<HHIIHH", data, i + 8)
        elif cid == b"data":
            pcm = data[i + 8:i + 8 + size]
        elif cid == b"cue ":
            cue = True
        i += 8 + size + (size & 1)
    _, ch, sr, _, _, bits = fmt
    if bits == 8:
        x = (np.frombuffer(pcm, np.uint8).astype(np.float64) - 128) / 128
    else:
        x = np.frombuffer(pcm[:len(pcm) // 2 * 2], "<i2") / 32768.0
    x = x[:len(x) // ch * ch].reshape(-1, ch).mean(1)
    return Wav(sr, bits, ch, x, cue)


def wav_bytes(ref, x):
    dither = np.random.default_rng(0).triangular(-1, 0, 1, len(x))
    if ref.bits == 8:
        q = np.clip(np.round(x * 127 + dither) + 128, 0, 255).astype(np.uint8)
    else:
        q = np.clip(np.round(x * 32767 + dither), -32768, 32767).astype("<i2")
    if ref.ch > 1:
        q = np.repeat(q[:, None], ref.ch, 1)
    pcm = q.tobytes()
    align = ref.ch * ref.bits // 8
    body = b"fmt " + struct.pack("<IHHIIHH", 16, 1, ref.ch, ref.sr, ref.sr * align, align, ref.bits)
    body += b"data" + struct.pack("<I", len(pcm)) + pcm + b"\0" * (len(pcm) & 1)
    if ref.cue:
        # One cue point at the first sample: GoldSrc's mark for a sound that loops.
        cue = struct.pack("<III4sIII", 1, 0, 0, b"data", 0, 0, 0)
        body += b"cue " + struct.pack("<I", len(cue)) + cue
    return b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WAVE" + body


# The tree just before this script replaced the stock sounds. Not each file's first commit: a
# few (vox/doop, misc/rav1...) were re-cut since, and the live version is the one to match.
STOCK = "7892929d~1"


def original(name):
    """The stock audio this replaces."""
    data = subprocess.run(["git", "show", "%s:sounds/%s.wav" % (STOCK, name)], cwd=ROOT,
                          capture_output=True, check=True).stdout
    return parse_wav(data)


def resample(y, a, b):
    if a == b:
        return y
    f = Fraction(b, a).limit_denominator(4000)
    return signal.resample_poly(y, f.numerator, f.denominator)


# ---- what a recipe is handed ----

class Ctx:
    """dur is the original's length; a loop's recipe makes XF more, folded back over its start."""

    def __init__(self, name, ref):
        self.name, self.ref = name, ref
        self.dur = len(ref.x) / ref.sr
        self.loop = ref.cue
        self.xf = min(0.25, self.dur * 0.2) if self.loop else 0.0
        self.n = int(round((self.dur + self.xf) * W))
        self.rng = np.random.default_rng(zlib.crc32(name.encode()))


def finish(c, y):
    y = resample(np.asarray(y, np.float64), W, c.ref.sr)
    n = len(c.ref.x)
    if c.loop:
        xf = int(c.xf * c.ref.sr)
        y = np.pad(y, (0, max(0, n + xf - len(y))))
        k = np.linspace(0, 1, xf)
        out = y[:n].copy()
        out[:xf] = y[:xf] * np.sqrt(k) + y[n:n + xf] * np.sqrt(1 - k)
    else:
        out = y.copy()
        fi, fo = min(len(out), int(0.002 * c.ref.sr)), min(len(out), int(0.01 * c.ref.sr))
        out[:fi] *= np.linspace(0, 1, fi)
        out[len(out) - fo:] *= np.linspace(1, 0, fo)
    return to_level(out, loudness(c.ref.x), c.ref.sr)


def limit(x, sr, ceiling=0.98):
    """Look-ahead peak limiting: gain dips just before each over and recovers over ~50 ms."""
    from scipy.ndimage import minimum_filter1d
    need = np.minimum(1.0, ceiling / np.maximum(np.abs(x), 1e-9))
    held = minimum_filter1d(need, 2 * int(0.002 * sr) + 1)
    k = np.exp(-1.0 / (0.05 * sr))
    smooth = signal.lfilter([1 - k], [1, -k], held, zi=[held[0] * k])[0]
    return x * np.minimum(held, smooth)


def to_level(x, target, sr, most=8.0):
    """Scale x to the target loudness; past the ceiling the limiter makes up the rest, up to `most`
    times (18 dB) of squeeze, since the stock sounds were mastered hot."""
    level = loudness(x)
    if not level or not target:
        return x
    x = x * target / level
    if np.abs(x).max() <= 0.98:
        return x
    lo, hi = 1.0, most
    if loudness(limit(x * hi, sr)) < target:
        return limit(x * hi, sr)
    for _ in range(14):
        mid = (lo + hi) / 2
        if loudness(limit(x * mid, sr)) < target:
            lo = mid
        else:
            hi = mid
    return limit(x * hi, sr)


def loudness(x):
    """RMS over the parts that sound at all, so a short hit in a long file isn't diluted."""
    x = np.asarray(x)
    if not len(x) or not np.abs(x).max():
        return 0.0
    hop = 256
    frames = np.sqrt(np.array([np.mean(x[k:k + hop] ** 2) for k in range(0, len(x), hop)]))
    live = frames[frames > frames.max() * 0.03]
    return float(np.sqrt(np.mean(live ** 2)))


# ---- synthesis helpers, all at W ----

def secs(t):
    return int(round(t * W))


def times(n):
    return np.arange(n) / W


def white(c, n):
    return c.rng.standard_normal(n)


def coloured(c, n, power):
    """Noise falling off as 1/f^power: 0.5 pink, 1 brown."""
    spec = np.fft.rfft(c.rng.standard_normal(n))
    f = np.arange(len(spec), dtype=float)
    f[0] = 1
    y = np.fft.irfft(spec / f ** power, n)
    return y / (np.std(y) + 1e-12)


def butter(x, kind, f, order=4):
    return signal.sosfilt(signal.butter(order, f, kind, fs=W, output="sos"), x)


def lp(x, f, order=4):
    return butter(x, "lowpass", f, order)


def hp(x, f, order=4):
    return butter(x, "highpass", f, order)


def bp(x, lo, hi, order=2):
    return butter(x, "bandpass", [lo, hi], order)


def ring(x, f, q):
    b, a = signal.iirpeak(f, q, fs=W)
    return signal.lfilter(b, a, x)


def osc(freq, n, shape="sine", top=10000.0, phase=0.0):
    """A band-limited oscillator; freq is a number or one value per sample."""
    f = np.broadcast_to(np.asarray(freq, float), (n,))
    ph = TAU * np.cumsum(f) / W + phase
    if shape == "sine":
        return np.sin(ph)
    step = 2 if shape == "square" else 1
    harmonics = max(1, int(top / max(f.max(), 1)))
    y = np.zeros(n)
    for k in range(1, harmonics + 1, step):
        y += np.sin(k * ph) / k
    return y * (4 / np.pi if shape == "square" else 2 / np.pi)


def env(n, points):
    """Piecewise-linear envelope through (seconds, level) points."""
    t, v = zip(*points)
    return np.interp(times(n), t, v)


def decay(n, tau, start=0.0):
    t = times(n) - start
    return np.where(t >= 0, np.exp(-np.maximum(t, 0) / tau), 0.0)


def add(out, x, t, gain=1.0):
    i = secs(t)
    if i >= len(out):
        return out
    m = min(len(x), len(out) - i)
    out[i:i + m] += x[:m] * gain
    return out


def modal(n, modes, click=0.0, c=None):
    """A struck object: (Hz, decay seconds, level) per mode, plus a short noise click."""
    t = times(n)
    y = sum(a * np.sin(TAU * f * t) * np.exp(-t / tau) for f, tau, a in modes)
    if click and c is not None:
        y = y + click * hp(white(c, n), 2000) * decay(n, 0.002)
    return y


def banded(c, n, centre, width=0.5, power=0.0):
    """Noise whose band follows centre(t) Hz, width in octaves."""
    x = coloured(c, n, power) if power else white(c, n)
    f, t, z = signal.stft(x, W, nperseg=1024)
    fc = np.maximum(np.asarray(centre(t), float), 20.0)
    g = np.exp(-0.5 * (np.log2(np.maximum(f[:, None], 1.0) / fc[None, :]) / width) ** 2)
    _, y = signal.istft(z * g, W, nperseg=1024)
    y = np.pad(y, (0, max(0, n - len(y))))[:n]
    return y / (np.std(y) + 1e-12)


def sweep_lp(c, x, cutoff):
    """x through a lowpass whose cutoff follows cutoff(t) Hz."""
    f, t, z = signal.stft(x, W, nperseg=1024)
    fc = np.maximum(np.asarray(cutoff(t), float), 20.0)
    g = 1 / (1 + (f[:, None] / fc[None, :]) ** 4)
    _, y = signal.istft(z * g, W, nperseg=1024)
    return np.pad(y, (0, max(0, len(x) - len(y))))[:len(x)]


def reverb(c, x, rt60, mix, tone=6000.0):
    n = secs(rt60)
    ir = lp(white(c, n), tone) * np.exp(-6.9 * times(n) / rt60)
    wet = signal.fftconvolve(x, ir)[:len(x)]
    wet *= np.std(x) / (np.std(wet) + 1e-12)
    return x * (1 - mix) + wet * mix


def flutter(c, n, rate, depth):
    """Slow random wobble around 1: rate is how fast it wanders (Hz)."""
    w = lp(white(c, n + secs(1)), rate, 2)[secs(1):]
    return 1 + depth * w / (np.abs(w).max() + 1e-12)


def per_loop(c, k):
    """A frequency that fits k whole cycles into the loop, so it meets itself at the seam."""
    return k / c.dur


def note(f, dur, shape="sine", attack=0.01, tau=0.3, partials=((1, 1.0),)):
    n = secs(dur)
    t = times(n)
    y = sum(a * osc(f * k, n, shape) for k, a in partials)
    return y * np.minimum(t / attack, 1) * np.exp(-t / tau)


def boom(c, n, low=60.0, bright=6000.0, tail=0.35, sub=0.6):
    """An explosion: a noise burst darkening as it dies, a falling sub thump, a few crackles."""
    t = times(n)
    burst = sweep_lp(c, white(c, n), lambda s: 300 + bright * np.exp(-s / (tail * 0.6)))
    burst *= np.minimum(t / 0.003, 1) * np.exp(-t / tail)
    thump = np.sin(TAU * np.cumsum(low * 0.55 + low * 0.45 * np.exp(-t / 0.15)) / W) * np.exp(-t / 0.3)
    crack = np.zeros(n)
    for _ in range(25):
        at = c.rng.uniform(0, 0.6)
        add(crack, hp(white(c, secs(0.01)), 2500) * decay(secs(0.01), 0.002), at, c.rng.uniform(0.2, 1))
    return burst + sub * thump + 0.3 * crack


# ---- recordings ----

FREESOUND = {
    "129678": ("FreethinkerAnon", "crickets"),
    "753272": ("HECKFRICKER", "Single Cricket Chirping, Close Perspective"),
    "46938": ("galeku", "flys-I.wav"),
    "853671": ("hoshisato", "The song of an Eurasian Wren"),
    "117513": ("klangfabrik", "winter wind 01c.aiff"),
    "30444": ("moxobna", "wind2.wav"),
    "254642": ("Divinux", "wind.wav"),
    "44880": ("A.Deathy", "big_waterfall.wav"),
    "321886": ("nsmusic", "Waterfall"),
    "433589": ("jackthemurray", "Stream River Water Up Close"),
    "382322": ("sterferny", "Stream.wav"),
    "177958": ("Sclolex", "Water Dripping in Cave.wav"),
    "204348": ("Sauron974", "Crackling Fire"),
    "249418": ("midimagician", "Fire Burning Loop"),
    "40699": ("Spandau", "campfire.wav"),
    "194364": ("Dave Welsh", "Thunder Clap OWB KY 441x16.wav"),
    "398032": ("swordofkings128", "Splash"),
    "50623": ("vibe_crc", "water_splash_10shots.wav"),
}
_decoded = {}


def page_url(sid):
    return "https://freesound.org/people/%s/sounds/%s/" % (urllib.parse.quote(FREESOUND[sid][0]), sid)


def freesound(sid):
    """The recording at W, mono, from its HQ preview; fetched once, after checking it is CC0."""
    if sid in _decoded:
        return _decoded[sid]
    path = os.path.join(CACHE, sid + ".mp3")
    if not os.path.exists(path):
        req = urllib.request.Request(page_url(sid), headers={"User-Agent": "Mozilla/5.0"})
        page = urllib.request.urlopen(req, timeout=60).read().decode("utf-8", "replace")
        if "creativecommons.org/publicdomain/zero/1.0" not in page:
            raise SystemExit("freesound %s is not marked CC0" % sid)
        mp3 = re.search(r'data-mp3="([^"]+)"', page).group(1).replace("-lq.mp3", "-hq.mp3")
        os.makedirs(CACHE, exist_ok=True)
        subprocess.run(["curl", "-fsSL", "--retry", "8", "--retry-all-errors", "-o", path + ".part", mp3],
                       check=True)
        os.rename(path + ".part", path)
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-ac", "1", "-ar", str(W),
                          "-f", "f32le", "-"], capture_output=True, check=True).stdout
    _decoded[sid] = np.frombuffer(raw, np.float32).astype(np.float64)
    return _decoded[sid]


def rec(c, sid, start, n=None):
    x = freesound(sid)
    n = n or c.n
    seg = x[secs(start):secs(start) + n]
    return np.pad(seg, (0, n - len(seg)))


def busiest(x, dur, lo, hi):
    """Where the dur-long window with the most energy in lo..hi Hz starts, in seconds."""
    e = bp(x, lo, hi) ** 2
    win = secs(dur)
    s = np.concatenate([[0], np.cumsum(e)])
    k = np.argmax(s[win:] - s[:-win]) if len(x) > win else 0
    return k / W


def onsets(x, thresh=0.3, gap=0.15):
    """Start times of the hits in x."""
    e = lp(np.abs(x), 30, 2)
    e /= e.max()
    out, last = [], -1e9
    for i in np.flatnonzero((e[1:] >= thresh) & (e[:-1] < thresh)):
        if i / W - last > gap:
            out.append(i / W)
            last = i / W
    return out


# ---- speech ----

VOICE = "am_fenrir"
# The announcer's words, as Kokoro (misaki) phonemes: A eɪ, I aɪ, O oʊ, W aʊ, Y ɔɪ. Several are
# spliced into other words by the maps (red, scream, captured and day lend their first sounds to
# ww_checkmate's "res-cued king"), so each must start the way the stock word did.
VOX = {
    "all": "ˈɔl", "area": "ˈɛɹiə", "blue": "blˈu", "captured": "kˈæpʧɚd", "command": "kəmˈænd",
    "day": "dˈA", "enemy": "ˈɛnəmi", "flag": "flˈæɡ", "four": "fˈɔɹ", "good": "ɡˈʊd",
    "great": "ɡɹˈAt", "green": "ɡɹˈin", "has": "hˈæz", "have": "hˈæv", "hostile": "hˈɑstˌIl",
    "ing": "ɪŋ", "is": "ˈɪz", "job": "ʤˈɑb", "key": "kˈi", "now": "nˈW", "one": "wˈʌn",
    "point": "pˈYnt", "red": "ɹˈɛd", "reset": "ɹˌisˈɛt", "returned": "ɹᵻtˈɜɹnd", "run": "ɹˈʌn",
    "scores": "skˈɔɹz", "scream": "skɹˈim", "seconds": "sˈɛkəndz", "secure": "səkjˈʊɹ",
    "secured": "səkjˈʊɹd", "team": "tˈim", "the": "ðə", "there": "ðˈɛɹ", "three": "θɹˈi",
    "two": "tˈu", "will": "wˈɪl", "yellow": "jˈɛlO", "you": "jˈu", "your": "jˈʊɹ",
}
_kokoro = None


def speak(phonemes, voice=VOICE, speed=0.9):
    global _kokoro
    if _kokoro is None:
        from kokoro_onnx import Kokoro
        _kokoro = Kokoro(os.path.join(KOKORO, "kokoro-v1.0.onnx"), os.path.join(KOKORO, "voices-v1.0.bin"))
    audio, sr = _kokoro.create(phonemes, voice=voice, speed=speed, is_phonemes=True)
    return resample(np.asarray(audio, np.float64), sr, W)


def trim(x, floor=0.02):
    """Cut leading and trailing quiet, keeping a few ms either side."""
    e = lp(np.abs(x), 60, 2)
    live = np.flatnonzero(e > e.max() * floor)
    if not len(live):
        return x
    return x[max(0, live[0] - secs(0.005)):live[-1] + secs(0.02)]


def announcer(phonemes):
    """A word over a public-address horn: band-limited and a little driven."""
    y = trim(speak(phonemes + "."))
    y = lp(hp(y, 200), 4200)
    y /= np.abs(y).max() + 1e-12
    return np.tanh(1.8 * y) / np.tanh(1.8)


# ---- recipes ----

RECIPES = {}  # name -> (function, kind, freesound id or None)


def recipe(*names, kind="synthesized", src=None):
    def deco(fn):
        for name in names:
            RECIPES[name] = (fn, kind, src)
        return fn
    return deco


for _word, _ph in VOX.items():
    RECIPES["vox/" + _word] = ((lambda ph: lambda c: announcer(ph))(_ph), "spoken", None)


@recipe("vox/_comma")
def r_comma(c):
    return np.zeros(c.n)


# Announcer stingers.

@recipe("vox/bloop")
def r_bloop(c):
    out = np.zeros(c.n)
    for t0, f0 in ((0.01, 560), (0.29, 470)):
        n = secs(0.25)
        f = f0 * np.exp(-times(n) * 2.4)
        add(out, osc(f, n) * env(n, [(0, 0), (0.008, 1), (0.25, 0)]), t0)
    return out


@recipe("vox/buzwarn")
def r_buzwarn(c):
    # A buzzer, "bzzzt-bzt": 234 Hz led by its 2nd and 3rd harmonics, a swell then a short pulse.
    n = c.n
    t = times(n)
    ph = TAU * 234 * t
    tone = sum(a * np.sin(k * ph) for k, a in ((1, 0.5), (2, 1.0), (3, 0.6), (4, 0.35), (5, 0.25), (6, 0.15),
                                                (7, 0.1), (8, 0.06)))
    tone *= 1 + 0.15 * np.sin(TAU * 58.5 * t)  # a little rasp, not a gate
    shape = env(n, [(0, 0), (0.02, 0.6), (0.2, 1), (0.36, 1), (0.42, 0.1), (0.5, 0.1), (0.52, 0.8),
                    (0.6, 0.8), (0.64, 0.05), (c.dur, 0)])
    return lp(tone, 3000) * shape


@recipe("vox/dadeda")
def r_dadeda(c):
    out = np.zeros(c.n)
    for t0, f in ((0.0, 523.25), (0.26, 659.25), (0.52, 523.25)):
        add(out, note(f, 0.37, tau=0.18, partials=((1, 1), (2, 0.3), (3, 0.12))), t0)
    return out


@recipe("vox/deeoo")
def r_deeoo(c):
    out = np.zeros(c.n)
    add(out, note(783.99, 0.3, tau=0.25, partials=((1, 1), (2, 0.2))), 0.0)
    add(out, note(523.25, 0.38, tau=0.22, partials=((1, 1), (2, 0.2))), 0.28)
    return out


@recipe("vox/doop")
def r_doop(c):
    # A horn call: A3, then the fifth above joins it, and the chord dies away.
    out = np.zeros(c.n)
    for t0, f, level in ((0.0, 215.0, 1.0), (0.18, 322.0, 0.8)):
        n = c.n - secs(t0)
        t = times(n)
        voice = sum(osc(f * cents, n, "saw", 4000) for cents in (0.998, 1.002)) / 2
        voice = sweep_lp(c, voice, lambda s: 700 + 900 * np.exp(-s / 0.25))  # the brassy blat at the start
        shape = np.minimum(t / 0.04, 1) * env(n, [(0, 1), (0.4 - t0 / 2, 1), (c.dur - t0, 0)]) ** 1.5
        add(out, level * voice * shape * (1 + 0.004 * np.sin(TAU * 5 * t)), t0)
    return out


@recipe("misc/talk")
def r_talk(c):
    out = np.zeros(secs(0.18))
    add(out, lp(osc(1175, secs(0.06), "square", 5000), 4500), 0.0)
    add(out, lp(osc(1568, secs(0.09), "square", 5000), 4500) * decay(secs(0.09), 0.04), 0.07)
    return out


@recipe("fvox/bell")
def r_bell(c):
    # ww_shrinkspell plays a tune on this at many pitches, so it must stay a clean note at the
    # original's 602 Hz.
    n = c.n
    y = modal(n, [(602, 0.55, 1.0), (1204, 0.32, 0.4), (1662, 0.22, 0.3), (3251, 0.1, 0.12),
                  (5376, 0.06, 0.05)], click=0.2, c=c)
    return y


# Pickups.

@recipe("items/gunpickup2")
def r_gunpickup2(c):
    out = np.zeros(c.n)
    add(out, note(659.25, 1.3, attack=0.005, tau=0.45, partials=((1, 1), (2, 0.25), (3, 0.08))), 0.0)
    add(out, note(987.77, 1.2, attack=0.005, tau=0.4, partials=((1, 1), (2, 0.2))), 0.08, 0.6)
    return reverb(c, out, 0.6, 0.15)


@recipe("items/ammopickup1")
def r_ammopickup1(c):
    # Mana pickup: a pouch's contents rattling, busiest early like the stock sound's.
    out = np.zeros(c.n)
    for start, end, count, level in ((0.08, 0.32, 34, 1.0), (0.48, 0.76, 12, 0.4)):
        for at in np.sort(c.rng.uniform(start, end, count)):
            add(out, knock(c, c.rng.uniform(380, 900), level * c.rng.uniform(0.4, 1)), at)
    n = secs(0.35)
    return add(out, 0.05 * bp(white(c, n), 600, 2500) * env(n, [(0, 0), (0.08, 1), (0.35, 0)]), 0.06)


def knock(c, low, level):
    """A latch or buckle snapping shut. Noise only: any tuned mode, however damped, gives a row
    of these a pitch and they ring like a wooden bell."""
    n = secs(0.05)
    snap = bp(white(c, n), low * 1.5, low * 6) * decay(n, 0.004)
    thud = lp(white(c, n), low) * decay(n, 0.007)
    return level * (snap + 0.7 * thud)


@recipe("items/gunpickup3")
def r_gunpickup3(c):
    # Priming a satchel: a clack-clack in the stock sound's rhythm, then two faint settles.
    out = np.zeros(c.n)
    for at, low, level in ((0.0, 520, 0.6), (0.06, 610, 0.4), (0.1, 450, 1.0), (0.42, 700, 0.15), (0.8, 650, 0.12)):
        add(out, knock(c, low, level), at)
    n = secs(0.25)
    return add(out, 0.06 * bp(white(c, n), 1000, 4000) * env(n, [(0, 0), (0.05, 1), (0.25, 0)]), 0.12)


@recipe("items/itembk2")
def r_itembk2(c):
    n = c.n
    whump = lp(coloured(c, n, 1), 300) * env(n, [(0, 0), (0.12, 1), (0.25, 0.6), (c.dur, 0)])
    shimmer = bp(white(c, n), 900, 3500) * flutter(c, n, 25, 0.9) * env(n, [(0, 0), (0.1, 1), (c.dur, 0)])
    return whump + 0.8 * np.sin(TAU * 72 * times(n)) * decay(n, 0.22, 0.05) * (times(n) > 0.05) + 0.25 * shimmer


def medkit(c, beeps):
    out = np.zeros(c.n)
    for at, f in beeps:
        add(out, osc(f, secs(0.07)) * env(secs(0.07), [(0, 0), (0.005, 1), (0.06, 1), (0.07, 0)]), at)
    n = secs(0.42)
    add(out, bp(white(c, n), 2000, 7000) * env(n, [(0, 0), (0.04, 0.35), (0.42, 0)]), c.dur - 0.45)
    return out


@recipe("items/smallmedkit1")
def r_smallmedkit1(c):
    return medkit(c, ((0.0, 880), (0.12, 880)))


@recipe("items/smallmedkit2")
def r_smallmedkit2(c):
    return medkit(c, ((0.0, 988), (0.11, 1319)))


# Hits.

@recipe("zombie/claw_strike3")
def r_claw_strike3(c):
    n = c.n
    out = bp(white(c, n), 700, 2800) * env(n, [(0, 0), (0.08, 0.4), (0.1, 0)])
    hit = (bp(white(c, n), 1000, 6000) * decay(n, 0.035) + 1.2 * np.sin(TAU * 110 * times(n)) * decay(n, 0.08)
           + 0.6 * bp(white(c, n), 300, 900) * decay(n, 0.1))
    return add(out, hit, 0.1)


@recipe("weapons/xbow_hitbod1")
def r_xbow_hitbod1(c):
    n = c.n
    t = times(n)
    thump = np.sin(TAU * np.cumsum(90 + 60 * np.exp(-t / 0.03)) / W) * decay(n, 0.06)
    return lp(white(c, n), 2500) * decay(n, 0.03) + 1.3 * thump + 0.5 * bp(white(c, n), 1000, 3000) * decay(n, 0.015)


def clink(c, freqs):
    return modal(c.n, [(freqs[0], 0.05, 1), (freqs[1], 0.03, 0.6), (freqs[2], 0.02, 0.35)], click=0.4, c=c)


@recipe("debris/bone_clink1")
def r_bone_clink1(c):
    return clink(c, (820, 1910, 3080))


@recipe("debris/bone_clink2")
def r_bone_clink2(c):
    return clink(c, (950, 2240, 3610))


@recipe("debris/bone_clink3")
def r_bone_clink3(c):
    return clink(c, (760, 1730, 2890))


def flop(c, low):
    n = c.n
    t = times(n)
    thud = np.sin(TAU * np.cumsum(low * 0.7 + low * 0.3 * np.exp(-t / 0.04)) / W) * decay(n, 0.07)
    squelch = bp(white(c, n), 400, 1200) * flutter(c, n, 40, 0.8) * decay(n, 0.12)
    return thud + 0.6 * lp(white(c, n), 800) * decay(n, 0.05) + 0.5 * squelch


@recipe("debris/flesh_flop1")
def r_flesh_flop1(c):
    return flop(c, 85)


@recipe("debris/flesh_flop2")
def r_flesh_flop2(c):
    return flop(c, 70)


# Weapons and blasts.

@recipe("ambience/explode3")
def r_explode3(c):
    return boom(c, c.n, low=60, bright=7000, tail=0.32)


@recipe("ambience/biggun3")
def r_biggun3(c):
    n = c.n
    out = boom(c, n, low=45, bright=5000, tail=0.5, sub=0.9)
    out += 0.6 * lp(coloured(c, n, 1), 220) * decay(n, 0.9) * np.minimum(times(n) / 0.05, 1)
    echo = lp(out, 1500)
    return add(out, echo, 0.45, 0.35)


@recipe("x/nih_die2")
def r_nih_die2(c):
    n = c.n
    out = boom(c, n, low=40, bright=4000, tail=0.7, sub=0.9)
    out += 0.8 * lp(coloured(c, n, 1), 300) * env(n, [(0, 0), (0.1, 1), (2.0, 0.5), (c.dur, 0)])
    for _ in range(40):
        add(out, bp(white(c, secs(0.03)), 800, 4000) * decay(secs(0.03), 0.008), c.rng.uniform(0.2, 2.6),
            c.rng.uniform(0.1, 0.5))
    return reverb(c, out, 1.5, 0.25)


@recipe("x/x_shoot1")
def r_x_shoot1(c):
    n = c.n
    t = times(n)
    fc = 150 + 1400 * np.exp(-t / 0.12)
    mod = 3 * np.exp(-t / 0.2) * np.sin(TAU * np.cumsum(fc * 1.5) / W)
    zap = np.sin(TAU * np.cumsum(fc) / W + mod) * decay(n, 0.15)
    return zap + 0.4 * hp(white(c, n), 3000) * decay(n, 0.02)


def electro(c, spans):
    n = c.n
    t = times(n)
    gate = np.zeros(n)
    for a, b in spans:
        gate[secs(a):secs(b)] = 1
    gate = lp(gate, 200, 2) * np.maximum(flutter(c, n, 90, 1.0), 0)
    buzz = hp(osc(60, n, "saw", 6000), 400)
    snaps = np.zeros(n)
    for at in c.rng.uniform(0, c.dur, 60):
        add(snaps, white(c, secs(0.003)) * decay(secs(0.003), 0.0008), at, c.rng.uniform(0.5, 2))
    hiss = bp(white(c, n), 1500, 6000) * (0.6 + 0.4 * np.sin(TAU * 120 * t) ** 2)
    return (0.6 * hiss + 0.5 * buzz + bp(snaps, 800, 7000)) * gate


@recipe("weapons/electro5")
def r_electro5(c):
    return electro(c, ((0.0, 0.42), (0.47, 0.66)))


@recipe("weapons/electro6")
def r_electro6(c):
    return electro(c, ((0.0, 0.2), (0.26, 0.45), (0.5, 0.66)))


# Doors.

def grind(c, n, lo, hi, rate):
    return bp(coloured(c, n, 0.5), lo, hi) * flutter(c, n, rate, 0.9)


@recipe("doors/doormove1")
def r_doormove1(c):
    n = c.n
    y = lp(coloured(c, n, 1), 250) + grind(c, n, 300, 3000, 8) + 0.25 * lp(osc(100, n, "saw", 2000), 600)
    scrape = bp(white(c, n), 1000, 4000) * decay(n, 0.25)
    return y * env(n, [(0, 0), (0.3, 1), (c.dur - 0.6, 1), (c.dur, 0)]) + 0.8 * scrape


@recipe("doors/doormove2")
def r_doormove2(c):
    n = c.n
    out = 0.4 * bp(white(c, n), 1500, 7000) * decay(n, 0.35, 0.2) * (times(n) > 0.2)
    for at in (0.03, 0.12):
        add(out, modal(secs(0.2), [(180, 0.05, 1), (420, 0.03, 0.5)], click=0.6, c=c), at, 1.5)
    return out


@recipe("doors/doormove6")
def r_doormove6(c):
    n = c.n
    out = 0.4 * lp(coloured(c, n, 1), 300)
    for k, at in enumerate(np.arange(0.02, c.dur - 0.05, 0.06)):
        add(out, modal(secs(0.03), [(1200, 0.006, 1), (2800, 0.004, 0.5)], click=0.3, c=c), at,
            c.rng.uniform(0.5, 1))
    return out * env(n, [(0, 0), (0.02, 1), (c.dur - 0.1, 1), (c.dur, 0)])


@recipe("doors/doormove7")
def r_doormove7(c):
    n = c.n
    y = grind(c, n, 1500, 5000, 15) + 0.5 * lp(coloured(c, n, 1), 300)
    return y * env(n, [(0, 0), (0.1, 1), (c.dur - 0.25, 1), (c.dur, 0)])


@recipe("doors/doormove8")
def r_doormove8(c):
    n = c.n
    out = 0.4 * lp(coloured(c, n, 1), 300) * env(n, [(0, 0), (0.2, 1), (c.dur - 0.5, 1), (c.dur, 0)])
    out += 0.5 * lp(coloured(c, n, 0.5), 700) * decay(n, 1.0, 1.2) * (times(n) > 1.2)
    for at in (0.0, 0.45, 0.9):
        add(out, modal(secs(0.4), [(150, 0.12, 1), (390, 0.08, 0.5), (900, 0.05, 0.3)], click=0.5, c=c), at, 1.4)
    return out


@recipe("doors/doormove9")
def r_doormove9(c):
    out = np.zeros(c.n)
    for k in range(7):
        n = secs(0.05)
        f = np.linspace(1200, 3500, n)
        add(out, osc(f, n) * env(n, [(0, 0), (0.005, 1), (0.05, 0)]), 0.03 + k * 0.08, 0.8)
        add(out, hp(white(c, secs(0.01)), 2000) * decay(secs(0.01), 0.002), 0.03 + k * 0.08)
    return out


@recipe("doors/doormove10")
def r_doormove10(c):
    n = c.n
    out = 0.4 * bp(white(c, n), 1500, 6000) * env(n, [(0, 0), (0.03, 1), (0.6, 0.2), (0.62, 0)])
    return add(out, modal(secs(0.15), [(1800, 0.08, 1), (2230, 0.06, 0.6)], click=0.5, c=c), 0.6, 1.2)


def thud(c, low, tau, rattle):
    n = c.n
    y = np.sin(TAU * low * times(n)) * decay(n, tau) + 0.8 * lp(coloured(c, n, 1), 200) * decay(n, tau * 1.1)
    return y + rattle * bp(white(c, n), 300, 1500) * decay(n, tau * 1.6)


@recipe("doors/doorstop2")
def r_doorstop2(c):
    return thud(c, 45, 0.3, 0.3)


@recipe("doors/doorstop4")
def r_doorstop4(c):
    return thud(c, 60, 0.1, 0.2)


def clang(c, modes):
    """A slam: a darkening noise body with the door's metal ringing under it."""
    n = c.n
    body = sweep_lp(c, white(c, n), lambda s: 400 + 5000 * np.exp(-s / 0.2)) * decay(n, 0.3)
    return body + 0.5 * modal(n, modes, click=0.6, c=c)


@recipe("doors/doorstop6")
def r_doorstop6(c):
    return clang(c, [(98, 0.5, 1), (233, 0.4, 0.7), (510, 0.3, 0.45), (1130, 0.2, 0.25)])


@recipe("doors/doorstop7")
def r_doorstop7(c):
    return clang(c, [(134, 0.5, 1), (279, 0.4, 0.7), (620, 0.3, 0.45), (1480, 0.2, 0.25)])


@recipe("doors/doorstop8")
def r_doorstop8(c):
    return clang(c, [(240, 0.45, 1), (517, 0.35, 0.7), (1210, 0.25, 0.45), (2650, 0.15, 0.25)])


# Map ambience made here.

@recipe("ambience/alien_beacon")
def r_alien_beacon(c):
    n = c.n
    t = times(n)
    hum = sum(a * np.sin(TAU * 204 * k * t) for k, a in ((1, 1), (2, 0.5), (3, 0.15), (4, 0.25)))
    pulse = 0.55 + 0.45 * np.sin(TAU * per_loop(c, 4) * t) ** 2
    return hum * pulse + 0.15 * bp(coloured(c, n, 0.5), 300, 1500)


@recipe("ambience/alien_creeper")
def r_alien_creeper(c):
    n = c.n
    t = times(n)
    f = 650 + 100 * np.sin(TAU * per_loop(c, 1) * t)
    tone = lp(osc(f, n, "saw", 3000), 1200) * (0.7 + 0.3 * np.sin(TAU * per_loop(c, 3) * t))
    return 0.5 * tone + lp(coloured(c, n, 1), 120)


@recipe("ambience/alien_humongo")
def r_alien_humongo(c):
    n = c.n
    t = times(n)
    voice = osc(55 + 10 * np.sin(TAU * 0.3 * t), n, "saw", 4000)
    voice = ring(voice, 500, 4) + 0.6 * ring(voice, 1200, 6)
    rumble = lp(coloured(c, n, 1), 400)
    roar = banded(c, n, lambda s: 700 - 250 * s / c.dur, 1.2, 0.5) * flutter(c, n, 6, 0.5)
    return (voice + rumble + 0.8 * roar) * env(n, [(0, 0), (1.5, 1), (c.dur - 2, 0.8), (c.dur, 0)])


@recipe("ambience/alien_twow")
def r_alien_twow(c):
    n = c.n
    t = times(n)
    beat = per_loop(c, 6)
    y = lp(osc(90, n, "saw", 2000) + osc(90 + beat, n, "saw", 2000), 600)
    return y + 0.2 * lp(coloured(c, n, 1), 200)


def drip(c, f0):
    n = secs(0.12)
    f = f0 * (1 + 1.2 * times(n) / 0.12)
    return osc(f, n) * env(n, [(0, 0), (0.003, 1), (0.12, 0)]) ** 2


@recipe("ambience/aliencave1")
def r_aliencave1(c):
    n = c.n
    out = 0.6 * lp(coloured(c, n, 1), 250) + 0.08 * bp(coloured(c, n, 0.5), 800, 2000)
    for at in (0.4, 1.3, 2.2, 3.4, 4.5):
        add(out, drip(c, c.rng.uniform(1200, 2400)), at, 0.5)
    return reverb(c, out, 1.8, 0.35)


@recipe("ambience/alienfazzle1")
def r_alienfazzle1(c):
    n = c.n
    crackle = np.zeros(n)
    for at in c.rng.uniform(0, c.dur, 110):
        add(crackle, white(c, secs(0.004)) * decay(secs(0.004), 0.001), at, c.rng.uniform(0.2, 1.5))
    crackle = bp(crackle, 600, 5000)
    buzz = lp(osc(53, n, "saw", 4000), 2000) * flutter(c, n, 12, 0.8)
    return crackle / (np.abs(crackle).max() + 1e-12) + 0.35 * buzz


def tonal_wind(c, peaks):
    n = c.n
    t = times(n)
    x = coloured(c, n, 0.5)
    y = 0.1 * bp(x, 200, 1600)
    for k, (f, q) in enumerate(peaks):
        y += 1.5 * ring(x, f, q) * (0.6 + 0.4 * np.sin(TAU * per_loop(c, k + 1) * t + k))
    return lp(y, 2000)


@recipe("ambience/alienwind1")
def r_alienwind1(c):
    return tonal_wind(c, ((410, 12), (820, 18)))


@recipe("ambience/alienwind2")
def r_alienwind2(c):
    return tonal_wind(c, ((990, 15), (280, 10)))


def machine(c, f0, partials, thumps=0, ticks=0):
    n = c.n
    t = times(n)
    hum = sum(a * np.sin(TAU * f0 * k * t) for k, a in partials)
    out = hum + 0.2 * bp(coloured(c, n, 0.5), 200, 600)
    for k in range(thumps):
        add(out, np.sin(TAU * 55 * times(secs(0.2))) * decay(secs(0.2), 0.05), k * c.dur / thumps, 0.8)
    for k in range(ticks):
        add(out, modal(secs(0.06), [(1500, 0.015, 1), (3200, 0.01, 0.5)], click=0.3, c=c), k * c.dur / ticks, 0.5)
    return out


@recipe("ambience/dronemachine3")
def r_dronemachine3(c):
    return machine(c, 51, ((1, 1), (2, 0.6), (3, 0.3), (5, 0.15)), thumps=6)


@recipe("ambience/industrial1")
def r_industrial1(c):
    return machine(c, 71, ((1, 1), (2, 0.4), (3, 0.5), (7, 0.1)), ticks=8)


@recipe("ambience/labdrone2")
def r_labdrone2(c):
    return machine(c, 57, ((1, 1), (2, 0.4), (3, 0.6)))


@recipe("ambience/labmoan")
def r_labmoan(c):
    n = c.n
    t = times(n)
    centre = lambda s: 650 + 300 * np.sin(TAU * s / c.dur - np.pi / 2)
    whoosh = banded(c, n, centre, 0.4, 0.5)
    tone = np.sin(TAU * np.cumsum(690 + 15 * np.sin(TAU * 5 * t)) / W)
    return whoosh * (0.6 + 0.4 * np.sin(TAU * per_loop(c, 1) * t - np.pi / 2)) + 0.1 * tone


@recipe("ambience/loader_hydra1")
def r_loader_hydra1(c):
    n = c.n
    t = times(n)
    hiss = hp(white(c, n), 1500) * env(n, [(0, 0), (0.15, 1), (0.9, 0.9), (c.dur, 0)])
    whine = np.sin(TAU * np.cumsum(600 + 300 * t / c.dur) / W)
    return hiss + 0.2 * whine * env(n, [(0, 0), (0.2, 1), (c.dur, 0)]) + 0.3 * np.sin(TAU * 60 * t)


@recipe("ambience/loader_step1")
def r_loader_step1(c):
    n = c.n
    thud = np.sin(TAU * 55 * times(n)) * decay(n, 0.25) + 0.7 * lp(white(c, n), 300) * decay(n, 0.1)
    clank = modal(n, [(310, 0.18, 1), (770, 0.12, 0.6), (1290, 0.08, 0.4), (2400, 0.05, 0.25)], click=0.5, c=c)
    return 1.3 * thud + 0.6 * clank + 0.3 * bp(white(c, n), 2000, 5000) * decay(n, 0.3)


@recipe("ambience/port_suckin1")
def r_port_suckin1(c):
    n = c.n
    t = times(n)
    rush = banded(c, n, lambda s: 3000 * (150 / 3000) ** np.clip(s / 2.6, 0, 1), 0.6)
    rush *= env(n, [(0, 0), (2.4, 1), (2.65, 1), (2.75, 0), (c.dur, 0)])
    low = np.sin(TAU * np.cumsum(120 * (40 / 120) ** np.clip(t / 2.7, 0, 1)) / W)
    return rush + 0.5 * low * env(n, [(0, 0), (2.5, 1), (2.75, 0), (c.dur, 0)])


@recipe("ambience/squeeks2")
def r_squeeks2(c):
    n = c.n
    out = 0.03 * coloured(c, n, 0.5)
    for start in (0.4, 2.6):
        for k in range(6):
            m = secs(0.04)
            f = np.linspace(2800, 3600, m) * c.rng.uniform(0.9, 1.1)
            add(out, osc(f, m) * env(m, [(0, 0), (0.005, 1), (0.04, 0)]), start + k * 0.1 + c.rng.uniform(0, 0.03),
                c.rng.uniform(0.5, 1))
    return out


@recipe("ambience/steamjet1")
def r_steamjet1(c):
    n = c.n
    t = times(n)
    x = white(c, n)
    return (hp(x, 1800) + 0.5 * bp(x, 4000, 6000)) * (0.9 + 0.1 * np.sin(TAU * per_loop(c, 12) * t))


def choir(c, roots, vowel):
    n = c.n
    out = np.zeros(n)
    for f0 in roots:
        drift = flutter(c, n, 0.8, 0.2) * (1 + 0.015 * np.sin(TAU * c.rng.uniform(4, 6) * times(n)))
        v = osc(f0 * drift, n, "saw", 6000) * flutter(c, n, 0.3, 0.6)
        out += sum(ring(v, f, 6) * a for f, a in vowel)
    out *= env(n, [(0, 0), (1.0, 1), (c.dur - 1.5, 1), (c.dur, 0)])
    return reverb(c, out, 2.5, 0.5)


@recipe("ambience/the_horror1")
def r_the_horror1(c):
    return choir(c, (220, 262, 330, 415, 660), ((700, 1), (1100, 0.6)))


@recipe("ambience/the_horror3")
def r_the_horror3(c):
    return choir(c, (196, 233, 311, 370, 587), ((450, 1), (800, 0.5)))


@recipe("ambience/siren")
def r_siren(c):
    out = np.zeros(c.n)
    at, k = 0.3, 0
    while at < 4.6:
        f = 880 if k % 2 == 0 else 660
        m = secs(0.15)
        add(out, lp(osc(f, m, "square", 6000), 4000) * env(m, [(0, 0), (0.005, 1), (0.14, 1), (0.15, 0)]), at)
        at += 0.2
        k += 1
    return out


@recipe("ambience/goal_1")
def r_goal_1(c):
    out = np.zeros(c.n)
    brass = lambda f, d, tau: lp(osc(f, secs(d), "saw", 6000), 3000) * env(secs(d), [(0, 0), (0.02, 1), (d, 0)]) \
        * decay(secs(d), tau)
    for k, f in enumerate((523.25, 659.25, 783.99)):
        add(out, brass(f, 0.2, 0.15), k * 0.12, 0.7)
    for f in (523.25, 659.25, 783.99, 1046.5):
        add(out, brass(f, 1.35, 0.6), 0.4, 0.5)
        add(out, note(f * 2, 1.2, tau=0.4), 0.4, 0.15)
    return reverb(c, out, 0.8, 0.2)


@recipe("nihilanth/nil_thieves", kind="spoken")
def r_nil_thieves(c):
    words = speak("ɪntɹˈudɚz… jˈu ɑɹ ˈɔl ɪntɹˈudɚz.", voice="am_onyx", speed=0.7)
    y = resample(words, W, int(W * 1.35))  # played back slower, so lower
    y = np.pad(y, (secs(0.3), secs(1.5)))
    return reverb(c, lp(y, 3500), 2.5, 0.45)


@recipe("misc/rav1", kind="spoken")
def r_rav1(c):
    return trim(speak("ɡˈʊd!", voice="bm_george", speed=0.95))


@recipe("misc/rav2", kind="spoken")
def r_rav2(c):
    return trim(speak("dˈɜɹɾi pˈul, ˈOld mˈæn. ˈI lˈIk ɪt.", voice="bm_george", speed=0.95))


# Recordings.

def recorded(name, sid, start=None, band=None, shape=None):
    """A recipe cutting c.n samples of a recording from start (or its busiest stretch in band)."""
    def fn(c):
        x = freesound(sid)
        s = start if start is not None else busiest(x, c.dur + c.xf, *band)
        y = rec(c, sid, s)
        return shape(c, y) if shape else y
    RECIPES[name] = (fn, "recorded", sid)


recorded("ambience/crickets", "129678", 2.0)
recorded("ambience/cricket", "753272", band=(3000, 6000))
recorded("ambience/wren1", "853671", band=(2000, 8000))
recorded("ambience/wind1", "30444", 10.0)
recorded("ambience/wind2", "117513", 30.0)
recorded("ambience/rwind1", "254642", 2.0)
recorded("ambience/waterfall2", "321886", 5.0)
recorded("ambience/waterfall3", "44880", 2.0)
recorded("ambience/water_flowing3", "433589", 10.0)
recorded("rwater1", "382322", 5.0)
recorded("ambience/drips", "177958", 10.0)
recorded("ambience/burning1", "204348", 10.0)
recorded("ambience/burning2", "249418", 3.0)
recorded("ambience/burning3", "40699", 30.0)
recorded("ambience/fire1", "40699", 90.0)


def r_flies(c):
    # One fly at a time in the recording; three stretches of it laid together make the swarm.
    x = freesound("46938")
    span = len(x) / W - c.dur - c.xf
    return sum(rec(c, "46938", span * k / 3) for k in range(3))


RECIPES["ambience/flies"] = (r_flies, "recorded", "46938")


def r_thunder(c):
    x = freesound("194364")
    s = max(0.0, onsets(x, 0.5)[0] - 0.3)
    y = rec(c, "194364", s)
    return y * env(c.n, [(0, 1), (c.dur - 1.5, 1), (c.dur, 0)])


RECIPES["ambience/thunder"] = (r_thunder, "recorded", "194364")


def splash(sid, which):
    def fn(c):
        x = freesound(sid)
        hits = onsets(x, 0.25, 0.4)
        s = max(0.0, hits[min(which, len(hits) - 1)] - 0.01)
        return rec(c, sid, s) * env(c.n, [(0, 1), (c.dur * 0.7, 1), (c.dur, 0)])
    return fn


RECIPES["misc/splash1"] = (splash("398032", 0), "recorded", "398032")
RECIPES["misc/splash2"] = (splash("50623", 2), "recorded", "50623")


# ---- driver ----

def make(name):
    ref = original(name)
    c = Ctx(name, ref)
    out = finish(c, RECIPES[name][0](c))
    data = wav_bytes(ref, out)
    for target in [name] + TWINS.get(name, []):
        with open(os.path.join(SOUNDS, target + ".wav"), "wb") as f:
            f.write(data)
    return out


def write_credits():
    kinds = {"synthesized": [], "recorded": [], "spoken": []}
    for name in sorted(RECIPES):
        kinds[RECIPES[name][1]].append(name)
    with open(os.path.join(SOUNDS, "CREDITS.md"), "w") as f:
        f.write("# Sound sources\n\n")
        f.write("Made by tools/sound_art.py, replacing stock Half-Life sounds of the same name, sample rate\n"
                "and format. Sounds not listed here are Wizard Wars' own.\n\n")
        f.write("## Synthesized\n\nGenerated by the script.\n\n")
        for name in kinds["synthesized"]:
            f.write("- `%s.wav`%s\n" % (name, twins_note(name)))
        f.write("\n## Spoken\n\nKokoro-82M (Apache-2.0, https://huggingface.co/hexgrad/Kokoro-82M), voice "
                "`%s` unless noted.\n\n" % VOICE)
        for name in kinds["spoken"]:
            voice = {"nihilanth/nil_thieves": " (am_onyx)", "misc/rav1": " (bm_george)",
                     "misc/rav2": " (bm_george)"}.get(name, "")
            f.write("- `%s.wav`%s\n" % (name, voice))
        f.write("\n## Recorded\n\nCC0 recordings from freesound.org, cut and shaped by the script.\n\n")
        f.write("| sound | recording |\n|---|---|\n")
        for name in kinds["recorded"]:
            sid = RECIPES[name][2]
            user, title = FREESOUND[sid]
            f.write("| `%s.wav`%s | [%s](%s) by %s (CC0) |\n" % (name, twins_note(name), title, page_url(sid), user))


def twins_note(name):
    return " (also %s)" % ", ".join("`%s.wav`" % t for t in TWINS[name]) if name in TWINS else ""


def spectrogram(x, sr, height=128):
    from PIL import Image
    n, hop = 512, 128
    x = np.pad(x, (0, max(0, n - len(x))))
    frames = np.array([np.abs(np.fft.rfft(x[k:k + n] * np.hanning(n))) for k in range(0, len(x) - n + 1, hop)]).T
    db = 20 * np.log10(frames + 1e-6)
    db = np.clip((db - db.max() + 70) / 70, 0, 1)
    img = Image.fromarray((db[::-1] * 255).astype(np.uint8))
    return img.resize((max(40, int(len(x) / sr * 120)), height))


def sheet(path, names):
    from PIL import Image, ImageDraw
    rows = []
    for name in names:
        ref = original(name)
        new = parse_wav(open(os.path.join(SOUNDS, name + ".wav"), "rb").read())
        rows.append((name, spectrogram(ref.x, ref.sr), spectrogram(new.x, new.sr)))
    width = 180 + 2 * max(max(a.width, b.width) for _, a, b in rows) + 20
    out = Image.new("RGB", (width, 140 * len(rows)), (30, 30, 36))
    d = ImageDraw.Draw(out)
    col = 180 + max(a.width for _, a, _ in rows) + 20
    for k, (name, a, b) in enumerate(rows):
        d.text((4, k * 140 + 60), name, fill=(255, 255, 255))
        out.paste(a.convert("RGB"), (180, k * 140 + 6))
        out.paste(b.convert("RGB"), (col, k * 140 + 6))
    out.save(path)


def main(argv):
    if argv[1:2] == ["--sheet"]:
        sheet(argv[2], argv[3:] or sorted(RECIPES))
        return 0
    names = argv[1:] or sorted(RECIPES)
    for name in names:
        if name not in RECIPES:
            print("no recipe for %s" % name)
            return 2
    for name in names:
        make(name)
        print("made sounds/%s.wav%s" % (name, twins_note(name)))
    write_credits()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
