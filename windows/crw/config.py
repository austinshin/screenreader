"""Tunables. Everything user-adjustable lives here; modules read these at call
time, so an edit plus restart is the whole change procedure.

Paths default to the repo's shared data/ and logs/ so the existing dashboard
(service/ui.py) sees the same reminders.json and event log this port writes.
Tests repoint DATA_DIR/LOGS_DIR at a temp directory.
"""

from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent  # the repo
DATA_DIR = ROOT / "data"
LOGS_DIR = ROOT / "logs"

# observer
POLL_INTERVAL = 5        # seconds between context samples
HEARTBEAT_EVERY = 12     # log a heartbeat every N unchanged polls (~1/min)

# presence routing
IDLE_THRESHOLD = 180     # seconds without input before the user counts as "away"
REMOTE_WHEN_AWAY = True  # mirror notifications to remote channels when away
REMOTE_CHANNELS = ["discord"]

# trigger state machine
ABSENT_SAMPLES = 6       # consecutive absent samples before "really gone" (~30s)
MAX_READY_WAIT = 90      # seconds READY waits for a context switch before firing anyway
SNOOZE_MINUTES = 10

# delivery
DEFAULT_CHANNELS = ["card"]
CARD_WIDTH = 380
CARD_DURATION = 12       # seconds before a non-sticky card auto-dismisses

# push-to-talk (all optional — absent pieces disable voice, nothing else)
DICTATE = {
    "whisper": None,         # path to whisper-cli.exe; None = search PATH
    "model": None,           # None = <repo>/models/ggml-base.en.bin
    "language": "en",
    "max_seconds": 20,       # watchdog for a key-up that never arrives
    "min_seconds": 0.35,     # shorter than this is a fumbled key, not speech
    "transcribe_timeout": 12,
    "keep_failed_audio": True,
}

# Transcript polish (optional): a small local LLM repairs what speech
# mangled — homophones, spelled-out times — before the deterministic parsers
# run. Auto-detected: active only while Ollama answers at `url`. The model
# size guidance from service/extract.py applies verbatim: ~3B keeps up,
# bigger thrashes.
LLM = {
    "enabled": True,   # False turns the feature off even with Ollama running
    "url": os.environ.get("CR_OLLAMA_URL", "http://localhost:11434"),
    "model": os.environ.get("CR_LOCAL_MODEL", "llama3.2:3b"),
    "timeout": 8,      # seconds; past this the raw transcript ships as-is
}

# hotkeys: id → (modifier names, key). Ctrl+Alt on Windows plays the role
# ⌃⌥⌘ did on macOS: free real estate no app claims system-wide.
HOTKEYS = {
    "reminder": (("ctrl", "alt"), "n"),   # type a reminder
    "glance":   (("ctrl", "alt"), "r"),   # every reminder, one panel
    "dictate":  (("ctrl", "alt"), "d"),   # HOLD to speak (needs voice deps)
    "test":     (("ctrl", "alt"), "t"),   # send a test card
    "quit":     (("ctrl", "alt"), "q"),   # stop the app
}


def data_dir() -> Path:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    return DATA_DIR


def logs_dir() -> Path:
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    return LOGS_DIR


def audio_dir() -> Path:
    # not the repo: recordings are transient scratch, and the repo dirs are
    # what the dashboard reads
    d = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "cr-voice"
    d.mkdir(parents=True, exist_ok=True)
    return d
