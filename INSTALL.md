# Installation

macOS only — this is built on Hammerspoon and Apple's Vision and Speech frameworks.

**Short version:**

```sh
git clone https://github.com/austinshin/screenreader.git
cd screenreader
./setup.sh          # builds the OCR helper, creates the venv, wires Hammerspoon
open -a Hammerspoon # then grant the permissions listed below
./start             # dashboard at http://localhost:8765
```

Then look at something and press **control + option + command + N**.

Everything below is the long version, including the parts people actually get stuck on.

---

## 1. Prerequisites

| | Required? | Install | Why |
|---|---|---|---|
| **macOS 13+** | yes | — | Vision OCR and on-device speech |
| **[Hammerspoon](https://www.hammerspoon.org/)** | yes | `brew install --cask hammerspoon` | runs the whole prototype |
| **Xcode CLI tools** | yes | `xcode-select --install` | compiles the OCR helper |
| **Python 3.9+** | yes | ships with macOS | dashboard + extraction service |
| **[`hear`](https://github.com/sveinbjornt/hear)** | no | download from releases | voice input. Without it, the hotkey still works |
| **`media-control`** | no | `brew install media-control` | knows a video is still playing in a background tab |
| **Anthropic API key** | no | — | only for the screen-inference experiment, which ships **off** |

Nothing here phones home. OCR is Apple Vision on-device, speech is Apple's on-device recognizer. The only outbound call belongs to the optional experiment.

## 2. Run setup

```sh
./setup.sh
```

It checks prerequisites, compiles `bin/cr-ocr`, creates `.venv`, and appends a loader stanza to `~/.hammerspoon/init.lua` pointing at wherever you cloned this. It's idempotent — safe to re-run, and it won't duplicate the stanza.

It touches nothing outside this folder except that one stanza.

## 3. Grant permissions — the part that actually blocks people

**System Settings → Privacy & Security → …**

| Permission | Grant to | Needed for |
|---|---|---|
| **Accessibility** | Hammerspoon | reading window titles — **required** |
| **Screen Recording** | Hammerspoon | OCR snapshots — **restart Hammerspoon after granting** |
| **Automation** | Hammerspoon → your browser | reading the active tab; prompts on first use |
| **Microphone** | `hear` | voice input |
| **Speech Recognition** | `hear` | voice input |

Three things worth knowing:

- **Screen Recording does not take effect until Hammerspoon restarts.** Granting it and carrying on is the single most common failure.
- The mic prompts are attributed to **`hear`**, not Hammerspoon. That's deliberate: a child process's permission is attributed to its responsible process, and Hammerspoon can't request speech recognition, so `hear` runs as its own launchd agent and asks for itself.
- Automation prompts appear the first time a browser is frontmost. Click OK; without it you lose per-tab binding and keep everything else.

## 4. Verify

```sh
./smoke-test.sh
```

Checks seven layers in ~20s and exits nonzero on failure. Two expected non-failures:

- OCR fails **if your screen is locked** — it can't snapshot a lock screen.
- "suggestions watcher off" is a **pass**; that experiment ships disabled.

Also useful:

```sh
python3 service/test_gate.py                # the gate's precision/recall eval
hs -c 'require("cr.test_capture").run()'    # voice capture, replaying real transcripts
```

## 5. Run it

```sh
./start            # dashboard + extraction service
./start status     # what's running
./start stop
./start restart    # after changing code
```

Hammerspoon loads on its own at login (enable **Launch at login** in its preferences).

## Using it

| | |
|---|---|
| **New reminder** | `control + option + command + N` |
| **Voice** | *"hey screenreader, remind me to reply to this once I'm done here"* |
| **See all reminders** | `command + option + shift + R` |
| **Forgot the shortcuts?** | `control + option + command + K` — or the menu-bar icon |
| **Dashboard** | http://localhost:8765 |

Shortcuts are editable in the dashboard's **Settings** tab.

**How a reminder fires.** Say it while looking at the thing it's about. It binds to that window or tab. When you leave and stay away ~30 seconds, then switch apps again, it fires. Returning to the thing resets the clock — that's deliberate, since glancing away isn't finishing.

Add a time instead (*"in 5 minutes"*, *"at 130"*, *"at 5pm august 1"*) and it fires on the clock rather than on context.

## Configuration

`hammerspoon/cr/config.lua`, read at call time — edit and reload, no restart:

```lua
pollInterval  = 5    -- seconds between context samples
trigger = {
  absentSamples = 6,   -- consecutive misses before "really gone" (~30s)
  maxReadyWait  = 90,  -- seconds to wait for a natural break before firing anyway
  snoozeMinutes = 10,
}
suggestions = { enabled = false }   -- the screen-inference experiment
```

Reload after editing:

```sh
hs -c "hs.timer.doAfter(0.1, hs.reload)"
```

## Optional: voice

Install [`hear`](https://github.com/sveinbjornt/hear), then toggle with `control + option + command + M`. Grant Microphone and Speech Recognition to **hear** when prompted.

Transcription is Apple's on-device recognizer (`hear -d`) — nothing leaves the machine, and it works offline. It's also the weakest link in accuracy: it mangles the wake word often enough that the matcher accepts a list of mishearings, and it ends utterances at pauses.

Live transcript, if something isn't being heard:

```sh
tail -f ~/Library/Logs/cr-voice/voice-transcript.log
```

## Optional: the screen-inference experiment

Off by default. It reads your screen with OCR and proposes reminders — the most interesting engineering here and the least product-ready (of the first 26 candidates I labeled, I kept one).

```lua
-- config.lua
suggestions = { enabled = true }
```

It needs an extraction backend, in preference order:

1. **Local model** — install [Ollama](https://ollama.com) and `ollama pull llama3.2:3b`. Chosen automatically; nothing leaves the machine. **Use a ~3B model**: a 9.6GB one measured 140s per call here, which can't keep up with captures arriving every 20s.
2. **Claude** — `security add-generic-password -U -s ANTHROPIC_API_KEY -a "$USER" -w 'sk-ant-…'`
3. **Neither** — falls back to regex rules, no network.

Turn on OCR capture with `control + option + command + W`, and see what it read with `control + option + command + V`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `hs` command hangs forever | Hammerspoon isn't running — `open -a Hammerspoon` |
| OCR fails in smoke test | screen is locked, or Screen Recording granted without restarting Hammerspoon |
| Reminder never fires | you keep returning to the thing — each return resets the ~30s counter. Check `logs/decisions-*.md` |
| Voice does nothing | `pgrep -x hear` — if empty, check Microphone/Speech Recognition for **hear** |
| Dashboard blank or stale | `./start restart`; check the browser console |
| Reminders don't survive restart | they persist to `data/reminders.json` — check it's writable |

**When something behaves oddly, read `logs/decisions-*.md` first.** It's plain English and says *why* each decision was made — when a reminder fired, what it heard, which reading it chose. `logs/events-*.jsonl` is the machine-readable version.

## Uninstall

```sh
./start stop
launchctl bootout gui/$(id -u)/cr.voice.hear 2>/dev/null   # voice agent
rm -f ~/Library/LaunchAgents/cr.voice.hear.plist
```

Then delete the loader stanza from `~/.hammerspoon/init.lua` and remove the folder. Revoke the permissions in System Settings if you want them gone.
