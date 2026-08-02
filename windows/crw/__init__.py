# crw — Contextual Reminders, Windows port.
#
# Same product, same shapes, one process: what Hammerspoon's single-threaded
# Lua config was on macOS, a single tkinter event loop is here. The core logic
# (timeparse, condition, tier, matcher, the trigger FSM, the store) is a
# line-for-line port of hammerspoon/cr/*, including its bug fixes; only the
# platform layer (observer, hotkeys, cards) is new code.
#
# Dependency policy mirrors the service: the core runs on the standard library
# alone. Voice (sounddevice + whisper-cli) and media state (winsdk) are
# guarded optionals — missing them degrades a feature, never the process.
