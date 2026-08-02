#!/usr/bin/env bash
# smoke-test.sh — verify every layer end to end, without waiting on wall-clock.
# Run from the repo root:  ./smoke-test.sh
set -uo pipefail
cd "$(dirname "$0")"
pass=0 fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

section "1. Hammerspoon + module loaded"
if ! pgrep -q -f "Hammerspoon.app"; then
  bad "Hammerspoon not running — run: open -a Hammerspoon"
  echo; echo "aborting: nothing else can be checked"; exit 1
fi
ok "Hammerspoon running"
hs -c "return CR and 'y' or 'n'" 2>/dev/null | grep -q y \
  && ok "cr module loaded (CR global present)" \
  || bad "cr module NOT loaded — check Hammerspoon console for '[cr] failed to load'"

section "2. Observer (screen context sensing)"
ctx=$(hs -c "local c=CR.observer.current; return c and (c.app or '?') or 'nil'" 2>/dev/null | tail -1)
[ -n "$ctx" ] && [ "$ctx" != "nil" ] \
  && ok "observer has context: $ctx" \
  || bad "observer has no context (is it paused?)"
hs -c "return tostring(CR.observer.running)" 2>/dev/null | grep -q true \
  && ok "observer running" || bad "observer paused"

section "3. OCR (on-device Vision)"
[ -x bin/cr-ocr ] && ok "bin/cr-ocr built" \
  || bad "bin/cr-ocr missing — run: swiftc -O ocr/cr-ocr.swift -o bin/cr-ocr"
hs -c "return tostring(hs.screenRecordingState and hs.screenRecordingState())" 2>/dev/null | grep -q true \
  && ok "Screen Recording permission granted" \
  || bad "Screen Recording permission missing (System Settings → Privacy → Screen Recording)"
rm -f tmp/smoke-ocr.txt
hs -c "hs.timer.doAfter(0.2, function()
  CR.screenText.capture(function(t, e)
    local f = io.open(CR.config.projectDir .. '/tmp/smoke-ocr.txt', 'w')
    if f then f:write(t or ('ERR: ' .. tostring(e))); f:close() end
  end, { mode = 'manual', reason = 'smoke-test' })
end)" >/dev/null 2>&1
for _ in $(seq 1 60); do [ -s tmp/smoke-ocr.txt ] && break; sleep 0.4; done
if [ -s tmp/smoke-ocr.txt ] && ! grep -q '^ERR:' tmp/smoke-ocr.txt; then
  ok "captured $(wc -c < tmp/smoke-ocr.txt | tr -d ' ') chars from the focused window"
else
  bad "OCR capture failed: $(head -c 120 tmp/smoke-ocr.txt 2>/dev/null || echo 'no output')"
fi

section "4. Trigger state machine (synthetic, no waiting)"
fsm=$(hs -c "
local video = { app='Chrome', bundle='com.google.Chrome', tab='X - YouTube', url='https://www.youtube.com/watch?v=smoke', reason='timer' }
local other = { app='Slack', bundle='com.tinyspeck.slackmacgap', title='#general', reason='timer' }
local r = CR.reminders.add('smoke test reminder', video)
if not r then return 'FAIL: could not create' end
local trace = r.state
CR.trigger.tick(other); trace = trace .. '>' .. r.state
CR.trigger.tick(video); trace = trace .. '>' .. r.state
for i=1,6 do CR.trigger.tick(other) end; trace = trace .. '>' .. r.state
CR.trigger.tick({ app='Slack', bundle='x', reason='app-switch' }); trace = trace .. '>' .. r.state
CR.reminders.setState(r, 'done', 'smoke-test')
return trace
" 2>/dev/null | tail -1)
[ "$fsm" = "armed>cooldown>armed>ready>fired" ] \
  && ok "FSM: $fsm" \
  || bad "FSM unexpected: $fsm (wanted armed>cooldown>armed>ready>fired)"

section "5. Notification delivery"
hs -c "CR.notifier.test(); return 'sent'" >/dev/null 2>&1 \
  && ok "test card dispatched (look at your top-right)" \
  || bad "notifier.test() failed"

section "6. Extraction service"
if [ -x .venv/bin/python ]; then
  ok "venv present"
  out=$(.venv/bin/python service/extract.py --once 2>&1)
  summary=$(printf '%s\n' "$out" | grep -a 'captures' | head -1 | tr -d '\r')
  [ -n "$summary" ] \
    && ok "pipeline ran: $summary" \
    || bad "pipeline output unexpected: $(printf '%s' "$out" | head -2)"
  .venv/bin/python -c "import anthropic" 2>/dev/null \
    && ok "anthropic SDK importable" || bad "anthropic SDK missing"
  [ -n "${ANTHROPIC_API_KEY:-}" ] \
    && ok "ANTHROPIC_API_KEY set → claude backend" \
    || printf '  \033[33m•\033[0m ANTHROPIC_API_KEY unset → rules backend (deterministic)\n'
else
  bad "no venv — run: python3 -m venv .venv && .venv/bin/pip install anthropic"
fi
# Capture is load-bearing: if getting a reminder in is flaky you never form
# the habit, and the hypothesis this prototype exists to test never gets
# exercised. Replays recorded transcripts, including the live-demo sequence
# that once produced two reminders from one sentence.
cap="$(hs -c 'return require("cr.test_capture").run()' 2>/dev/null | tail -1)"
case "$cap" in
  *"0 failed") ok "voice capture — $cap" ;;
  "")          bad "voice capture tests did not run (Hammerspoon unreachable?)" ;;
  *)           bad "voice capture — $cap" ;;
esac

# Screen inference is an opt-in experiment (config.suggestions.enabled).
# Off is the shipped default, so "not running" is a pass, not a failure —
# a red X for working-as-configured trains you to ignore the suite.
if hs -c "return tostring(CR.config.suggestions.enabled ~= false)" 2>/dev/null | grep -q true; then
  hs -c "return tostring(CR.suggestions.running)" 2>/dev/null | grep -q true \
    && ok "suggestions watcher running" || bad "suggestions watcher stopped"
else
  ok "suggestions watcher off (experiment disabled in config — expected)"
fi

section "7. Push-to-talk (record → Whisper)"
# Split deliberately: the parser is tested in-process where it is fast and
# deterministic, and the binaries are tested here where async and a real
# microphone are natural. Neither half proves the other works.
dic="$(hs -c 'return require("cr.test_dictate").run()' 2>/dev/null | tail -1)"
case "$dic" in
  *"0 failed") ok "dictation parser — $dic" ;;
  "")          bad "dictation tests did not run (Hammerspoon unreachable?)" ;;
  *)           bad "dictation parser — $dic" ;;
esac

[ -x bin/cr-rec ] && ok "bin/cr-rec built" \
  || bad "bin/cr-rec missing → swiftc -O audio/cr-rec.swift -o bin/cr-rec"
command -v whisper-cli >/dev/null && ok "whisper-cli installed" \
  || bad "whisper-cli missing → brew install whisper-cpp"
[ -s models/ggml-base.en.bin ] && ok "speech model present" \
  || bad "speech model missing → ./setup.sh"

# Real transcription on Homebrew's own sample: proves the flags, the model, and
# the output parsing together. Asserting on the words (not just non-empty)
# is what would catch a model file that downloaded as an HTML error page.
if command -v whisper-cli >/dev/null && [ -s models/ggml-base.en.bin ] \
   && [ -f /opt/homebrew/share/whisper-cpp/jfk.wav ]; then
  if whisper-cli -m models/ggml-base.en.bin -f /opt/homebrew/share/whisper-cpp/jfk.wav \
       -l en -nt -np 2>/dev/null | grep -qi "ask not what your country"; then
    ok "whisper transcribes the bundled sample correctly"
  else
    bad "whisper transcription wrong — is models/ggml-base.en.bin a real ggml file?"
  fi
fi

# One second of real audio proves the microphone permission end to end. Exit 77
# is specifically "denied", which needs a different fix from every other error.
if [ -x bin/cr-rec ]; then
  mkdir -p tmp
  ./bin/cr-rec tmp/smoke-mic.wav 1 >/dev/null 2>&1; rc=$?
  if [ "$rc" = "77" ]; then
    bad "microphone denied → System Settings › Privacy & Security › Microphone"
  elif afinfo tmp/smoke-mic.wav 2>/dev/null | grep -q "16000 Hz"; then
    ok "cr-rec captured 16kHz mono audio"
  else
    bad "cr-rec failed (exit $rc)"
  fi
  rm -f tmp/smoke-mic.wav
fi

mode="$(hs -c 'return CR.capture.mode()' 2>/dev/null | tail -1)"
[ -n "$mode" ] && ok "capture mode: $mode (exactly one voice path can be live)" \
  || bad "capture mode unreadable"

section "8. Logs"
for f in "logs/events-$(date +%Y-%m-%d).jsonl" "logs/ocr-$(date +%Y-%m-%d).jsonl"; do
  [ -s "$f" ] && ok "$f ($(wc -l < "$f" | tr -d ' ') lines)" || bad "$f empty/missing"
done
[ -d logs/captures ] && ok "logs/captures/ ($(ls logs/captures | wc -l | tr -d ' ') files)" \
  || bad "logs/captures/ missing"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
rm -f tmp/smoke-ocr.txt
[ "$fail" -eq 0 ] || exit 1
