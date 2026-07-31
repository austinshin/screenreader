#!/usr/bin/env bash
# One-shot setup for a machine that has never run this.
#
#   ./setup.sh
#
# Builds the OCR helper, creates the Python venv, and wires the Hammerspoon
# loader to wherever this folder happens to live. Everything it touches is
# either inside this folder or a single stanza appended to ~/.hammerspoon/
# init.lua — nothing else on the machine is modified.
#
# It cannot grant macOS permissions for you. Those are the last section, and
# they are the part people actually get stuck on.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

say()  { printf "\n\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }

say "1. Prerequisites"
[[ "$(uname)" == "Darwin" ]] || { bad "macOS only — this is built on Hammerspoon + Apple Vision"; exit 1; }
ok "macOS $(sw_vers -productVersion)"

if [[ -d /Applications/Hammerspoon.app ]]; then
  ok "Hammerspoon installed"
else
  bad "Hammerspoon missing → brew install --cask hammerspoon (or hammerspoon.org)"
  exit 1
fi

command -v swiftc >/dev/null && ok "swiftc (for the OCR helper)" \
  || { bad "swiftc missing → install Xcode Command Line Tools: xcode-select --install"; exit 1; }
command -v python3 >/dev/null && ok "python3 $(python3 -V | cut -d' ' -f2)" \
  || { bad "python3 missing"; exit 1; }

say "2. Build the on-device OCR helper"
mkdir -p bin
if swiftc -O ocr/cr-ocr.swift -o bin/cr-ocr 2>/dev/null; then
  ok "bin/cr-ocr built (Apple Vision — screen text never leaves this machine)"
else
  bad "swiftc failed; try: swiftc -O ocr/cr-ocr.swift -o bin/cr-ocr"
fi

say "3. Python service"
if [[ ! -d .venv ]]; then python3 -m venv .venv; fi
./.venv/bin/pip install -q --upgrade pip >/dev/null 2>&1 || true
./.venv/bin/pip install -q anthropic >/dev/null 2>&1 && ok "venv ready (anthropic installed)" \
  || warn "anthropic install failed — the extractor falls back to regex rules, everything else works"

say "4. Optional extras"
command -v hear >/dev/null && ok "hear — voice capture available" || warn \
  "hear not installed → voice input is off. Get it from github.com/sveinbjornt/hear (on-device speech)."
command -v media-control >/dev/null && ok "media-control — knows if a video is still playing" || warn \
  "media-control not installed → 'done with this video' can't tell paused from closed. brew install media-control"

say "5. Wire the Hammerspoon loader"
HS_INIT="$HOME/.hammerspoon/init.lua"
mkdir -p "$HOME/.hammerspoon"
touch "$HS_INIT"
# matches both spellings: require("cr") and pcall(require, "cr")
if grep -q 'cr' "$HS_INIT" 2>/dev/null && grep -Eq 'require.*"cr"' "$HS_INIT" 2>/dev/null; then
  ok "loader already present in ~/.hammerspoon/init.lua"
  grep -q "$HERE" "$HS_INIT" || warn "…but it points somewhere else. Update the crPath line to: $HERE/hammerspoon"
else
  cat >> "$HS_INIT" <<LUA

--------------------------------------------------------------------------------
-- Contextual Reminders (added by setup.sh)
-- pcall so a bug in the module can never break the rest of this config.
--------------------------------------------------------------------------------
require("hs.ipc")   -- enables the \`hs\` command-line tool
local crPath = "$HERE/hammerspoon"
package.path = package.path .. ";" .. crPath .. "/?.lua;" .. crPath .. "/?/init.lua"
local crOk, crErr = pcall(require, "cr")
if not crOk then print("[cr] failed to load: " .. tostring(crErr)) end
LUA
  ok "loader appended to ~/.hammerspoon/init.lua"
fi

say "6. Claude API key (optional)"
if [[ -n "${ANTHROPIC_API_KEY:-}" ]] || security find-generic-password -s ANTHROPIC_API_KEY -w >/dev/null 2>&1; then
  ok "key found — the extractor can use Claude"
else
  warn "no key. Only the (optional, off-by-default) screen-inference experiment needs one."
  warn "  security add-generic-password -U -s ANTHROPIC_API_KEY -a \"\$USER\" -w 'sk-ant-...'"
fi

say "7. Permissions you must grant by hand"
cat <<'TXT'
  System Settings → Privacy & Security → …

    Accessibility     → Hammerspoon    (read window titles — required)
    Screen Recording  → Hammerspoon    (OCR snapshots — required, then RESTART Hammerspoon)
    Automation        → Hammerspoon → your browser  (read the active tab; prompts on first use)
    Microphone        → hear           (voice input — only if you installed hear)
    Speech Recognition→ hear           (same)

  Screen Recording in particular does not take effect until Hammerspoon is restarted.
TXT

say "Next"
cat <<TXT
  1. Open (or restart) Hammerspoon.
  2. ./smoke-test.sh      verify all seven layers
  3. ./start              dashboard at http://localhost:8765
  4. Press control+option+command+K for the hotkey cheatsheet.

  Then make a reminder while looking at something:
     control+option+command+N  →  "reply to this thread when I'm done here"
TXT
