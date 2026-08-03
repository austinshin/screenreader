"""Push-to-talk capture — port of cr/dictate.lua. Hold Ctrl+Alt+D, speak,
release.

The held key answers both questions a streaming recognizer never can — where
the utterance starts and where it ends — which is why this path has no wake
word, no settle timer, no dupe guards. (The macOS wake-word path was
deliberately not ported: push-to-talk replaced it there too.)

Windows simplification worth naming: recording is in-process via sounddevice
(WASAPI) instead of a subprocess — no SIGTERM protocol, no RIFF-header race,
no per-binary mic attribution. The permission model is one OS toggle.

Optional throughout: sounddevice missing, whisper-cli missing, or the model
missing each disable voice with a one-line reason; nothing else is affected.
Transcription runs on a worker thread; results reach the app through emit(),
which the app marshals onto the tk loop.
"""

from __future__ import annotations

import shutil
import subprocess
import threading
import time
import wave

from . import config, eventlog, llm, why

state = "idle"
_frames: list[bytes] = []
_stream = None
_snap_at_press = None
_started_at = 0.0
_watchdog = None
_emit = None   # emit(kind, data) — thread-safe, wired by app.start()


def _whisper_path():
    explicit = config.DICTATE.get("whisper")
    if explicit:
        return explicit
    # Repo-local install first — the Windows twin of the macOS bin/ convention.
    # Drop a whisper.cpp release exe (and the DLLs beside it) into <repo>/bin.
    for name in ("whisper-cli.exe", "main.exe"):
        p = config.ROOT / "bin" / name
        if p.exists():
            return str(p)
    return (shutil.which("whisper-cli") or shutil.which("whisper-cli.exe")
            or shutil.which("whisper-cpp") or shutil.which("main"))


def _model_path():
    p = config.DICTATE.get("model")
    return p or (config.ROOT / "models" / "ggml-base.en.bin")


def available():
    """Reports what is missing rather than just "unavailable": each has a
    different one-line fix, and "voice doesn't work" hides which."""
    try:
        import sounddevice  # noqa: F401
    except Exception:
        return False, "voice needs sounddevice — pip install sounddevice"
    if not _whisper_path():
        return False, "whisper-cli not found — winget install whisper-cpp (or add to PATH)"
    from pathlib import Path
    if not Path(_model_path()).exists():
        return False, f"speech model missing — download ggml-base.en.bin to {_model_path()}"
    return True, None


def init(emit) -> None:
    global _emit
    _emit = emit


def start_recording(snap) -> None:
    global state, _frames, _snap_at_press, _started_at, _stream, _watchdog
    if state != "idle":
        return
    ok, reason = available()
    if not ok:
        _emit("rejected", reason)
        eventlog.append({"event": "dictate.unavailable", "reason": reason})
        return

    import sounddevice as sd

    # Bind to what you were looking at when you decided to speak, not to
    # wherever you end up when the transcript comes back.
    _snap_at_press = snap
    _started_at = time.time()
    _frames = []

    def cb(indata, frames, t, status):
        _frames.append(bytes(indata))

    try:
        _stream = sd.RawInputStream(samplerate=16000, channels=1, dtype="int16",
                                    callback=cb)
        _stream.start()
    except Exception as e:
        state = "idle"
        _emit("rejected", f"could not open the microphone: {e}")
        eventlog.append({"event": "dictate.recorder_failed", "error": str(e)[:200]})
        return
    state = "recording"
    _emit("status", "recording… release to stop")
    eventlog.append({"event": "dictate.recording",
                     "bound": (snap or {}).get("title")})

    # Watchdog for a key-up that never arrives: a dropped release must not
    # leave the mic open indefinitely.
    _watchdog = threading.Timer(config.DICTATE["max_seconds"] + 0.5,
                                lambda: stop_recording(capped=True))
    _watchdog.daemon = True
    _watchdog.start()


def stop_recording(capped: bool = False) -> None:
    global state, _stream, _watchdog
    if state != "recording":
        return
    if _watchdog:
        _watchdog.cancel()
    held = time.time() - _started_at
    try:
        _stream.stop()
        _stream.close()
    except Exception:
        pass
    _stream = None

    # A tap rather than a hold is a fumbled keystroke, not a reminder.
    if held < config.DICTATE["min_seconds"] and not capped:
        state = "idle"
        _emit("hide", None)
        eventlog.append({"event": "dictate.too_short", "held": round(held, 2)})
        return

    state = "transcribing"
    _emit("status", "transcribing…")
    data = b"".join(_frames)
    snap = _snap_at_press
    threading.Thread(target=_transcribe, args=(data, snap), daemon=True).start()


def _transcribe(data: bytes, snap) -> None:
    global state
    wav_path = config.audio_dir() / f"ptt-{int(time.time())}.wav"
    try:
        with wave.open(str(wav_path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(data)
        proc = subprocess.run(
            [_whisper_path(), "-m", str(_model_path()), "-f", str(wav_path),
             "-l", config.DICTATE["language"],
             "-nt",   # no timestamps: stdout becomes the bare transcript
             "-np",   # no prints: no load banner
             "-sns",  # suppress non-speech tokens
             "-mc", "0"],
            capture_output=True, text=True,
            timeout=config.DICTATE["transcribe_timeout"],
            creationflags=0x08000000)
        state = "idle"
        if proc.returncode != 0:
            _emit("rejected", f"whisper failed ({proc.returncode})")
            eventlog.append({"event": "dictate.transcribe_failed",
                             "stderr": (proc.stderr or "")[:200]})
            return
        eventlog.append({"event": "dictate.transcribed",
                         "raw": (proc.stdout or "")[:300]})
        text, reason = clean(proc.stdout)
        if not text:
            _emit("rejected", reason)
            # Keep the audio when the parse failed: the bug class that most
            # needs evidence is the one that leaves none.
            if config.DICTATE["keep_failed_audio"]:
                try:
                    wav_path.replace(config.audio_dir() / "last-failed.wav")
                except OSError:
                    pass
            eventlog.append({"event": "dictate.rejected",
                             "raw": (proc.stdout or "")[:200], "reason": reason})
            return
        wav_path.unlink(missing_ok=True)
        # Optional local-LLM repair pass, still on this worker thread. When
        # it changes anything, the decision log gets the before and after —
        # a tool that rewords what you said must show its work.
        text, meta = llm.polish(text)
        if meta:
            why.note("transcript polished", text, [
                ("heard", f'"{meta["raw"]}"'),
                ("read as", f'"{text}"'),
                ("by", f'{meta["model"]} on this machine, {meta["ms"]}ms'),
                ("kept because", "it repaired wording without adding anything new"),
            ])
        _emit("transcript", (text, snap))
    except subprocess.TimeoutExpired:
        state = "idle"
        _emit("rejected", "transcription timed out")
    except Exception as e:
        state = "idle"
        _emit("rejected", f"voice error: {e}")
        eventlog.append({"event": "dictate.error", "error": str(e)[:200]})


# parse ----------------------------------------------------------------------
# Whisper emits a leading space, sentence capitalization, and a trailing
# period. On silence it does not return nothing; it hallucinates captions
# ("Thank you.", "you"). Those are rejected as WHOLE strings only: as
# substrings, "thank you" would eat "thank Ruth for the coffee".

NOISE = {
    "[blank_audio]", "(silence)", "[silence]", "[music]", "(upbeat music)",
    "you", "thank you", "thanks for watching", "thank you for watching",
    "bye", "so", ".", "", "oh", "hmm",
}

# With push-to-talk the whole utterance is the command; the preamble is
# politeness, not syntax. "Water the plants" is a complete instruction.
PREAMBLE = [
    "remind me that ", "remind me to ", "remind me ",
    "reminder to ", "reminder ", "remember to ", "remember ",
    "note to self, ", "note to self ", "make a note to ", "make a note ",
]


def clean(raw):
    """raw whisper stdout → (text, None) or (None, reason)."""
    import re
    t = re.sub(r"\s+", " ", raw or "").strip()
    if not t:
        return None, "didn't catch that"
    lowered = re.sub(r"[.!]+$", "", t.lower())
    if lowered in NOISE or len(lowered) < 3:
        return None, "didn't catch that"
    t = re.sub(r"[.!]+$", "", t)
    low = t.lower()
    for p in PREAMBLE:
        if low.startswith(p):
            t = t[len(p):]
            break
    t = t.strip()
    if len(t) < 3:
        return None, "didn't catch that"
    return t, None
