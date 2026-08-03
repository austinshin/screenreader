# Installation — Windows

Windows 10/11. One Python process, standard library only — the extras are
optional and each one enables exactly one feature.

**Short version:**

```powershell
git clone https://github.com/austinshin/screenreader.git
cd screenreader
python windows\run.py
```

Then look at something and press **Ctrl+Alt+N**. That's a working install —
everything below is optional depth, plus the parts people actually get stuck on.

---

## 1. Prerequisites

| | Required? | Install | Why |
|---|---|---|---|
| **Windows 10/11** | yes | — | Win32 sensing, tray, toasts |
| **Python 3.10+** | yes | Microsoft Store or [python.org](https://python.org) — either works; both ship tkinter | runs everything |
| **git** | no | `winget install Git.Git` — or download the repo as a zip | getting the code |
| **sounddevice** | for voice | `pip install sounddevice` | microphone capture (WASAPI, in-process) |
| **whisper.cpp** | for voice | see [Voice](#4-voice-optional) below | push-to-talk transcription, on-device |
| **winsdk** | no | `pip install winsdk` | knows a video is still playing in the background |

Nothing here phones home. Speech is whisper.cpp running locally; the only
outbound calls belong to delivery channels you explicitly configure.

Unlike macOS there is **no permissions gauntlet**: window titles need no
Accessibility grant, screenshots need no Screen Recording grant, and the
microphone is one OS toggle (Settings → Privacy & security → Microphone →
*Let desktop apps access your microphone*).

## 2. Run it

```powershell
python windows\run.py
```

The startup banner lists every hotkey, whether voice is available (with the
one-line fix if it isn't), and where data and logs live. A ◉ appears in the
notification area — Windows hides new tray icons under the **^** chevron by
default; drag it onto the taskbar to pin it.

A second launch prints `crw is already running.` and exits — one instance
per machine, enforced by a mutex, so reminders can never double-fire.

## 3. Verify

```powershell
cd windows
python -m unittest discover -s tests    # 49 tests, well under a second
```

Then the ten-second live check: press **Ctrl+Alt+T** — a test card should
appear top-right. If it does, sensing, the queue, and the card renderer all
work.

## 4. Voice (optional)

**Hold `Ctrl+Alt+D`, speak, release.** Three pieces, each with a one-line
install:

1. **The capture library:**
   ```powershell
   pip install sounddevice
   ```
2. **The whisper binary.** Download `whisper-blas-bin-x64.zip` from the
   [whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases)
   (~19MB, the BLAS CPU build) and extract its contents into `bin\` at the
   repo root, so that `bin\whisper-cli.exe` exists **with the DLLs beside
   it** — the app checks `bin\` first, so PATH never needs editing. (If the
   zip extracts into a `Release\` subfolder, move the files up one level.)
3. **The model** (~148MB, one time):
   ```powershell
   curl.exe -L -o models\ggml-base.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
   ```
   Same file the macOS `setup.sh` downloads — a dual-boot clone shares it.

Restart the app; the banner flips from `voice: off (…)` to `voice: ready`.
Everything the typed path understands works spoken: *"reply to this when I'm
done here"*, *"water the plants in 5 minutes"*, *"at 130"*.

If nothing is heard: the toast tells you why ("didn't catch that" means
whisper returned a silence-hallucination and the parser rejected it), the
last failed recording is kept at `%LOCALAPPDATA%\cr-voice\last-failed.wav`,
and `grep dictate logs\events-*.jsonl` shows what whisper actually returned.

### Transcript polish (optional, needs voice)

A small local LLM can repair what speech mangled before the parsers run —
homophones ("by milk" → "buy milk") and spelled-out times ("at one thirty" →
"at 1:30", which is the difference between a reminder that fires at 1:30 and
one that silently doesn't):

```powershell
winget install Ollama.Ollama
ollama pull llama3.2:3b        # ~2GB; the 3B size matters — bigger thrashes
```

Nothing else to configure: the app probes Ollama once a minute and the
banner flips to `polish: on — llama3.2:3b repairs transcripts locally`.
Override the model or URL with `CR_LOCAL_MODEL` / `CR_OLLAMA_URL`.

The model is fenced in: it may only *repair*, never rewrite. Output that
shares too little with what was heard, or introduces words that were never
said, is logged (`llm.polish_rejected` in the event log) and discarded — and
any failure or timeout ships the raw transcript unchanged. When a polish is
accepted, `logs\decisions-*.md` records the before, the after, and which
model did it.

## 5. Delivery channels (optional)

Reminders default to the on-screen card. Per reminder they can also go to
Windows toasts, Discord, Slack, Telegram, or any webhook. Configure with
either:

```powershell
copy windows\crw\secrets_example.py windows\crw\secrets.py   # then edit it
```

or environment variables: `DISCORD_WEBHOOK_URL`, `SLACK_WEBHOOK_URL`,
`TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`. When you've been idle past
~3 minutes, delivery mirrors to the remote channels automatically — the
reminder lands where you actually are.

## 6. Start at login (optional)

A shortcut in the Startup folder, pointed at `pythonw` so no console window
appears:

```powershell
$s = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\Contextual Reminders.lnk")
$s.TargetPath = "pythonw.exe"
$s.Arguments = "windows\run.py"
$s.WorkingDirectory = "C:\path\to\screenreader"    # ← your clone
$s.Save()
```

## Using it

| | |
|---|---|
| **Speak a reminder** | **hold** `Ctrl+Alt+D`, talk, release |
| **Type a reminder** | `Ctrl+Alt+N` |
| **See all reminders** | `Ctrl+Alt+R` — or left-click the tray ◉ |
| **Test card** | `Ctrl+Alt+T` |
| **Quit** | `Ctrl+Alt+Q` — or right-click the ◉ |
| **Dashboard** | `python service\ui.py` → http://localhost:8765 (read-only on Windows) |

**How a reminder fires.** Say it while looking at the thing it's about. It
binds to that window. When you leave and stay away ~30 seconds, then switch
apps again, it fires — returning to the thing resets the clock, since
glancing away isn't finishing. Add a time instead (*"in 5 minutes"*,
*"at 130"*, *"at 5pm august 1"*) and it fires on the clock wherever you are.

## Configuration

`windows\crw\config.py` — edit, then restart the app:

```python
POLL_INTERVAL = 5     # seconds between context samples
ABSENT_SAMPLES = 6    # consecutive misses before "really gone" (~30s)
MAX_READY_WAIT = 90   # seconds to wait for a natural break before firing anyway
SNOOZE_MINUTES = 10
HOTKEYS = {...}       # every chord, one place
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| A hotkey does nothing | another app owns that chord — the startup banner marks refused ones with `!`. Edit `HOTKEYS` in config.py |
| Hold-to-talk does nothing | the banner says exactly which voice piece is missing. Also check Settings → Privacy & security → Microphone |
| Reminder never fires | you keep returning to the thing — each return resets the ~30s counter. The glance panel shows the count ("3 of 6 checks away") |
| No tray icon | it's under the **^** overflow — drag it out to pin it |
| Test hotkeys via synthesized input fail | anti-cheat software (e.g. Riot Vanguard) filters injected input at the driver level. Real key presses are unaffected |
| `crw is already running.` | it is — one instance per machine. Quit the other via `Ctrl+Alt+Q` or the tray menu |
| Cards draw over a fullscreen game | they're topmost by design — a reminder that waits for the game to end is the seam gate's job, and non-critical reminders already wait for an app switch |

**When something behaves oddly, read `logs\decisions-*.md` first.** It says
*why* in plain English — when a reminder fired, what it heard, which reading
it chose. `logs\events-*.jsonl` is the machine-readable version.

## Uninstall

Quit the app (`Ctrl+Alt+Q`), delete the Startup shortcut if you made one,
and remove the folder — data and logs live inside it, so nothing else is
left behind. `pip uninstall sounddevice winsdk` if you installed the extras.
