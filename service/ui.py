#!/usr/bin/env python3
"""
ui.py — local web dashboard for Contextual Reminders.

The menu bar is fine for glancing; it is bad for reviewing. This serves a
single-page dashboard at http://localhost:8765 showing what the system sees,
what it is watching, what it is suggesting, and how it is learning — with the
accept/dismiss actions the learning layer needs.

Runs on the Python standard library only (no Flask, no build step) so the demo
has one dependency: python3. It reads the same JSONL/JSON files the Lua side
writes and writes feedback back into the same feedback.jsonl, so both UIs stay
in sync without any IPC.

    python3 service/ui.py            # then open http://localhost:8765
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs"
DATA = ROOT / "data"
PORT = int(os.environ.get("CR_UI_PORT", "8765"))


# ----------------------------------------------------------------- data ------


def _tail_jsonl(path: Path, n: int) -> list[dict]:
    if not path.exists():
        return []
    rows = []
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return rows[-n:]


def today(prefix: str) -> Path:
    return LOGS / f"{prefix}-{datetime.now():%Y-%m-%d}.jsonl"


def hs(lua: str, timeout: float = 4) -> str:
    """Ask the running Hammerspoon instance for live state.

    `timeout` is a parameter because reads and writes have very different
    budgets. A status read should give up fast so the page stays responsive;
    a write that rebinds every hotkey takes longer, and timing it out reports
    a failure for work that actually succeeded — the worst kind of wrong.
    """
    try:
        out = subprocess.run(
            ["hs", "-c", lua], capture_output=True, text=True, timeout=timeout
        )
        return out.stdout.strip().splitlines()[-1] if out.stdout.strip() else ""
    except Exception:
        return ""


def snapshot() -> dict:
    ocr = _tail_jsonl(today("ocr"), 40)
    # deep tail: heartbeat events vastly outnumber the notify.dispatch rows the
    # Delivered list is built from — a shallow tail loses the day's deliveries
    events = _tail_jsonl(today("events"), 8000)
    cands = _tail_jsonl(DATA / "candidates.jsonl", 200)
    feedback = _tail_jsonl(DATA / "feedback.jsonl", 500)

    reminders = []
    rpath = DATA / "reminders.json"
    if rpath.exists():
        try:
            reminders = json.loads(rpath.read_text()).get("items", [])
        except Exception:
            pass

    weights = {}
    wpath = DATA / "weights.json"
    if wpath.exists():
        try:
            weights = json.loads(wpath.read_text())
        except Exception:
            pass

    judged = [f for f in feedback if f.get("value") in ("accept", "dismiss", "not_mine")]
    accepted = sum(1 for f in judged if f["value"] == "accept")
    # weights only start meaning anything once each feature has a few
    # observations; PRIOR=3 smoothing means ~20 labels before it moves much
    TRAIN_TARGET = 20
    trained_at = 0
    wpath_ = DATA / "weights.json"
    if wpath_.exists():
        try:
            ws = json.loads(wpath_.read_text())
            trained_at = sum(w.get("accept", 0) + w.get("dismiss", 0)
                             for w in ws.values()) and len(ws)
        except json.JSONDecodeError:
            pass

    ctx = hs("local c=CR.observer.current; return c and ((c.app or '?')..' — '..(c.tab or c.title or '')) or 'no context'")
    watching = hs("return tostring(CR.screenText.watching)") == "true"
    voice = hs("return tostring(CR.voice and CR.voice.running)") == "true"

    # the inference experiment is opt-in; when it's off its UI shouldn't be
    # there at all — a tab for a disabled feature is just a dead end
    suggestions_on = hs("return tostring(CR.config.suggestions.enabled ~= false)") == "true"

    # keybindings come from the Lua registry, never a copy kept here
    try:
        hotkeys = json.loads(hs("return hs.json.encode(CR.hotkeys.list())") or "[]")
    except json.JSONDecodeError:
        hotkeys = []

    # delivery channels + configuration state, straight from the Lua registry
    try:
        channels_available = json.loads(
            hs("return hs.json.encode(CR.notifier.available())") or "[]"
        )
    except json.JSONDecodeError:
        channels_available = []
    if not channels_available:  # Hammerspoon unreachable — show the default
        channels_available = [{"name": "card", "configured": True,
                               "desc": "on-screen card on this Mac (default)"}]

    # everything that was actually delivered (any channel), newest last
    dismissed = load_dismissed()
    all_delivered = [e for e in events if e.get("event") == "notify.dispatch"]
    notifications = [e for e in all_delivered if delivered_key(e) not in dismissed]

    # candidates not yet judged
    judged_ids = {f.get("id") for f in feedback}
    open_cands = [c for c in cands if c.get("id") not in judged_ids]

    caps_dir = LOGS / "captures"
    return {
        "context": ctx or "Hammerspoon not reachable",
        "watching": watching,
        "voice": voice,
        "counts": {
            "captures_today": len(ocr),
            "capture_files": len(list(caps_dir.glob("*.md"))) if caps_dir.exists() else 0,
            "candidates": len(cands),
            "open": len(open_cands),
            "reminders_active": sum(
                1 for r in reminders if r.get("state") not in ("done", "cancelled")
            ),
            "labels": len(judged),
            "precision": round(100 * accepted / len(judged)) if judged else None,
            "notified_today": len(notifications),
            "notified_total": len(all_delivered),
        },
        "channels_available": channels_available,
        "hotkeys": hotkeys,
        "suggestions_on": suggestions_on,
        "notifications": [dict(e, _key=delivered_key(e)) for e in notifications[-25:]],
        "delivered_hidden": len(all_delivered) - len(notifications),
        "training": {
            "labels": len(judged),
            "accepts": accepted,
            "dismisses": len(judged) - accepted,
            "target": TRAIN_TARGET,
            "features_learned": trained_at,
            "can_undo": bool(feedback),
        },
        "suggestions": list(reversed(open_cands))[:40],
        "reminders": [
            r for r in reminders if r.get("state") not in ("done", "cancelled")
        ][-20:],
        "captures": [
            {
                "iso": c.get("iso"),
                "source": c.get("source", "")[:90],
                "chars": len(c.get("text", "")),
                "ms": c.get("ms"),
                "mode": c.get("mode"),
                "text": c.get("text", "")[:1500],
            }
            for c in reversed(ocr[-15:])
        ],
        "weights": sorted(
            (
                {"feature": k, **v}
                for k, v in weights.items()
            ),
            key=lambda w: -w["multiplier"],
        )[:14],
    }


def write_feedback(cand: dict, value: str) -> None:
    DATA.mkdir(exist_ok=True)
    row = {
        "ts": int(datetime.now().timestamp()),
        "iso": datetime.now().isoformat(timespec="seconds"),
        "id": cand.get("id"),
        "value": value,
        "action": cand.get("action"),
        "kind": cand.get("kind"),
        "app": cand.get("app"),
        "score": cand.get("score"),
        "backend": cand.get("backend"),
        "features": cand.get("features", []),
        "via": "web",
    }
    with open(DATA / "feedback.jsonl", "a") as f:
        f.write(json.dumps(row) + "\n")


def find_candidate(cid: str) -> dict | None:
    for c in _tail_jsonl(DATA / "candidates.jsonl", 500):
        if c.get("id") == cid:
            return c
    return None


# The event log is the record of what actually happened; clearing a row from
# the Delivered list is a display preference, not a correction of history. So
# dismissals live in their own file and are applied as a filter — the audit
# trail stays intact and "clear" can never destroy evidence of a delivery.
DISMISSED = DATA / "delivered_dismissed.json"


def delivered_key(e: dict) -> str:
    """Stable id for one delivery. The event's `id` is the *reminder* id, which
    repeats when a reminder fires twice, so the timestamp is part of the key."""
    return f"{e.get('iso', '')}|{e.get('id') or e.get('title', '')}"


def load_dismissed() -> set[str]:
    if not DISMISSED.exists():
        return set()
    try:
        return set(json.loads(DISMISSED.read_text()))
    except (json.JSONDecodeError, TypeError):
        return set()


def save_dismissed(keys: set[str]) -> None:
    DATA.mkdir(exist_ok=True)
    # bounded: this is a hide-list, not a second copy of the log
    DISMISSED.write_text(json.dumps(sorted(keys)[-2000:]))


def undo_last_feedback() -> dict | None:
    """Drop the most recent label. Mislabeling is the one thing that quietly
    poisons a learning loop, so the fix has to be as cheap as the mistake."""
    path = DATA / "feedback.jsonl"
    if not path.exists():
        return None
    lines = [l for l in path.read_text().splitlines() if l.strip()]
    if not lines:
        return None
    last = lines.pop()
    path.write_text("\n".join(lines) + ("\n" if lines else ""))
    try:
        return json.loads(last)
    except json.JSONDecodeError:
        return {}


def run_learn() -> dict:
    """Recompute weights from the labels collected so far.

    Shells out to extract.py rather than importing it: the same command the
    user would run by hand, so the UI can't drift from the CLI.
    """
    before = {}
    wpath = DATA / "weights.json"
    if wpath.exists():
        try:
            before = json.loads(wpath.read_text())
        except json.JSONDecodeError:
            pass
    proc = subprocess.run(
        [sys.executable, str(ROOT / "service" / "extract.py"), "--learn"],
        capture_output=True, text=True, timeout=30,
    )
    after = {}
    if wpath.exists():
        try:
            after = json.loads(wpath.read_text())
        except json.JSONDecodeError:
            pass
    rows = []
    for feat, w in sorted(after.items(), key=lambda kv: -kv[1]["multiplier"]):
        prev = before.get(feat, {}).get("multiplier")
        rows.append({
            "feature": feat,
            "multiplier": w["multiplier"],
            "accept": w["accept"],
            "dismiss": w["dismiss"],
            "delta": None if prev is None else round(w["multiplier"] - prev, 3),
            "is_new": prev is None,
        })
    return {"ok": proc.returncode == 0, "message": proc.stdout.strip().splitlines()[-1]
            if proc.stdout.strip() else proc.stderr.strip()[:200], "weights": rows}


# ------------------------------------------------------------------ page -----

PAGE = r"""<!doctype html>
<meta charset="utf-8"><title>Contextual Reminders</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{
  --bg:#0d0e14; --panel:#151721; --line:#242736; --txt:#e7e9f0; --dim:#8b91a6;
  --accent:#7aa2f7; --good:#9ece6a; --warn:#e0af68; --bad:#f7768e;
}
@media (prefers-color-scheme:light){:root{
  --bg:#f6f7fa; --panel:#fff; --line:#e3e6ee; --txt:#161821; --dim:#6b7280;
  --accent:#3b6fe0; --good:#4e8c2f; --warn:#c77d1a; --bad:#d64560;}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--txt);
  font:14.5px/1.6 ui-sans-serif,-apple-system,"SF Pro Text",system-ui,sans-serif}
header{padding:22px 24px 14px;border-bottom:1px solid var(--line);
  display:flex;align-items:baseline;gap:12px;flex-wrap:wrap}
h1{font-size:17px;margin:0;font-weight:650;letter-spacing:-.01em}
.ctx{color:var(--dim);font-size:12px;overflow:hidden;text-overflow:ellipsis;
  white-space:nowrap;max-width:44vw;margin-left:auto}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:5px}
.on{background:var(--good)}.off{background:var(--dim)}
main{padding:22px 24px 70px;max-width:760px;margin:0 auto}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(118px,1fr));gap:10px;margin-bottom:8px}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.stat b{display:block;font-size:22px;font-weight:640;letter-spacing:-.02em}
.stat span{color:var(--dim);font-size:11.5px;text-transform:uppercase;letter-spacing:.05em}
h2{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--dim);
  margin:30px 0 10px;font-weight:600}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;
  padding:14px 16px;margin-bottom:10px}
.row{display:flex;gap:12px;align-items:flex-start}
.grow{flex:1;min-width:0}
.act{font-weight:560;font-size:15px}
.when{color:var(--accent);font-size:13px;white-space:nowrap}
button{font:inherit;font-size:12.5px;padding:5px 11px;border-radius:7px;cursor:pointer;
  border:1px solid var(--line);background:transparent;color:var(--txt);transition:.12s}
button:hover{border-color:var(--accent)}
button.y{border-color:rgba(158,206,106,.4);color:var(--good)}
button.y:hover{background:rgba(158,206,106,.12)}
button.n:hover{background:rgba(247,118,142,.12);border-color:rgba(247,118,142,.4)}
.pill{font-size:11px;padding:1.5px 7px;border-radius:20px;border:1px solid var(--line);
  color:var(--dim);white-space:nowrap}
.chips{margin-top:7px;display:flex;gap:6px;flex-wrap:wrap}
.chip{font-size:11px;padding:2px 9px;border-radius:20px;border:1px solid var(--line);
  color:var(--dim);cursor:pointer;user-select:none;transition:.12s}
.chip:hover{border-color:var(--accent)}
.chipOn{border-color:rgba(122,162,247,.55);color:var(--accent);background:rgba(122,162,247,.10)}
.chipNA{opacity:.45;font-style:italic}
.empty{color:var(--dim);padding:16px;text-align:center;font-size:13px}
pre{white-space:pre-wrap;word-break:break-word;font-size:11.5px;color:var(--dim);
  max-height:150px;overflow:auto;margin:8px 0 0;font-family:ui-monospace,Menlo,monospace}
details summary{cursor:pointer;color:var(--dim);font-size:12px;outline:none}
#internals{margin-top:44px;border-top:1px solid var(--line);padding-top:14px}
#internals>summary{text-transform:uppercase;letter-spacing:.08em;font-weight:600}

/* tabs */
nav.tabs{position:sticky;top:0;z-index:5;background:var(--bg);
  border-bottom:1px solid var(--line);padding:0 24px;display:flex;gap:2px;
  overflow-x:auto;scrollbar-width:none}
nav.tabs::-webkit-scrollbar{display:none}
nav.tabs button{background:none;border:0;border-bottom:2px solid transparent;
  border-radius:0;padding:12px 14px;color:var(--dim);font-size:13.5px;font-weight:520;
  white-space:nowrap;transition:.12s}
nav.tabs button:hover{color:var(--txt)}
nav.tabs button.sel{color:var(--txt);border-bottom-color:var(--accent)}
nav.tabs .n{font-size:11px;padding:1px 6px;border-radius:20px;background:var(--panel);
  border:1px solid var(--line);margin-left:6px;color:var(--dim)}
nav.tabs button.sel .n{border-color:var(--accent);color:var(--accent)}

/* reminders, built to be read at a glance */
.rem{display:flex;gap:0;background:var(--panel);border:1px solid var(--line);
  border-radius:12px;margin-bottom:9px;overflow:hidden}
.rail{flex:0 0 104px;padding:14px 12px;text-align:right;border-right:1px solid var(--line);
  background:linear-gradient(180deg,transparent,rgba(122,162,247,.04))}
.rail b{display:block;font-size:15px;font-weight:640;letter-spacing:-.01em;white-space:nowrap}
.rail span{display:block;color:var(--dim);font-size:11.5px;margin-top:2px}
.rail.ctx b{color:var(--dim);font-size:13px}
.body{flex:1;min-width:0;padding:14px 16px;display:flex;flex-direction:column;justify-content:center}
.body .t{font-size:15.5px;font-weight:560;letter-spacing:-.01em}
.body .s{color:var(--dim);font-size:12.5px;margin-top:3px;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.soon .rail b{color:var(--warn)}
.grp{font-size:11.5px;text-transform:uppercase;letter-spacing:.07em;color:var(--dim);
  margin:20px 0 8px;font-weight:600}
.grp:first-child{margin-top:4px}
.grpNote{text-transform:none;letter-spacing:0;font-weight:400;opacity:.65}
.prov{color:var(--dim);font-size:12px;line-height:1.5;margin-top:2px}
.prov .dim,.dim{opacity:.6}
.rem.t1{border-color:rgba(247,118,142,.5)}
.rem.t1 .rail{background:linear-gradient(180deg,transparent,rgba(247,118,142,.10))}
.rem.t1 .rail b{color:var(--bad)}
.rem.t4{opacity:.72}
.acts{display:flex;flex-direction:column;gap:5px;padding:13px 13px 13px 0;justify-content:center}
.acts button{font-size:11.5px;padding:4px 9px}

/* teaching surface */
.teach{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:20px 22px}
.teachTop{display:flex;justify-content:space-between;align-items:center;
  color:var(--dim);font-size:12px;margin-bottom:14px}
.teachAct{font-size:19px;font-weight:600;letter-spacing:-.01em;line-height:1.35}
.quote{margin:12px 0 0;padding:9px 13px;border-left:2px solid var(--line);
  color:var(--dim);font-size:13px;font-style:italic}
.feat{display:flex;gap:6px;flex-wrap:wrap;margin-top:13px}
.feat span{font-size:10.5px;padding:2px 8px;border-radius:5px;background:var(--bg);
  border:1px solid var(--line);color:var(--dim);font-family:ui-monospace,Menlo,monospace}
.teachBtns{display:flex;gap:9px;margin-top:18px;flex-wrap:wrap}
.teachBtns button{padding:9px 16px;font-size:13.5px;border-radius:9px}
kbd{font:11px ui-monospace,Menlo,monospace;border:1px solid var(--line);border-bottom-width:2px;
  border-radius:4px;padding:1px 5px;color:var(--dim);margin-left:5px}
.bar{height:5px;border-radius:3px;background:var(--line);overflow:hidden;margin:12px 0 6px}
.bar>i{display:block;height:100%;background:var(--accent);transition:width .3s}
.trained{background:rgba(158,206,106,.10);border:1px solid rgba(158,206,106,.35);
  border-radius:10px;padding:12px 14px;margin-top:12px;font-size:13px}
.up{color:var(--good)}.down{color:var(--bad)}
.wt{display:flex;justify-content:space-between;gap:10px;padding:5px 0;
  border-bottom:1px solid var(--line);font-size:12.5px}
.wt:last-child{border:0}
.mono{font-family:ui-monospace,Menlo,monospace}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:22px}
@media(max-width:840px){.grid2{grid-template-columns:1fr}.ctx{max-width:100%}}
</style>
<header>
  <h1>Contextual Reminders</h1>
  <span id="watch" class="pill"></span>
  <span class="ctx" id="ctx">…</span>
</header>
<nav class="tabs" id="tabs"></nav>
<main>
  <section data-tab="reminders">
    <div id="rem"></div>
  </section>

  <section data-tab="delivered" hidden>
    <div id="notifs"></div>
  </section>

  <section data-tab="teach" hidden>
    <div id="teach"></div>
    <div id="trainbar"></div>
    <details id="restQueue" style="margin-top:10px">
      <summary>see the whole queue</summary>
      <div id="sugg" style="margin-top:10px"></div>
    </details>
  </section>

  <section data-tab="settings" hidden>
    <h2>Keyboard shortcuts</h2>
    <div id="hotkeys"></div>
    <div class="card" style="margin-top:12px">
      <div class="meta">Click a shortcut, then press the keys you want.
        Needs at least one of control / option / command — a bare key would fire
        while you type. The <b>fn</b> key can't be used: supporting it requires
        watching every keystroke on the system, which drops characters.</div>
      <div style="margin-top:10px"><button onclick="resetHotkeys()">Reset all to defaults</button></div>
    </div>
  </section>

  <section data-tab="internals" hidden>
    <div class="stats" id="devstats" style="margin-top:4px"></div>
    <div class="grid2">
      <div>
        <h2>What it's learned</h2>
        <div class="card" id="weights"></div>
      </div>
      <div>
        <h2>Latest captures</h2>
        <div id="caps"></div>
      </div>
    </div>
  </section>
</main>
<script>
const esc = s => (s??'').toString().replace(/[&<>"]/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

// Every section renders from one load(); a null element threw and took the
// whole page down with it — renaming a heading blanked the reminders list,
// which is the one thing the page exists to show. A missing node now costs
// its own section and says so in the console, instead of everything after it.
function $(id){
  const n = document.getElementById(id);
  if(!n) console.warn('[cr] missing element:', id);
  return n || {innerHTML:'', textContent:'', style:{}, classList:{toggle(){}, add(){}}};
}

// Every section renders from one load(), so an exception anywhere used to blank
// everything after it — including the reminders, which is the one thing the
// page exists to show. A section that throws now costs only itself and says so
// on the page, rather than failing silently as empty space.
function section(name, fn){
  try { fn(); }
  catch(e){
    console.error('[cr] ' + name + ' failed:', e);
    const box = document.getElementById(name);
    if(box) box.innerHTML = `<div class="card empty">
      Couldn't render this section — ${esc(e.message)}<br>
      <span style="opacity:.6">details in the browser console</span></div>`;
  }
}

let state = null; // latest /api/state payload, for channel toggling

// Words, never numbers — "tier 2" is an internal model, not something to
// put in front of a person.
const TIERS = {
  1: {name:'Critical',   note:'interrupts you as soon as it fires'},
  2: {name:'Upcoming',   note:'waits for a natural break'},
  3: {name:'In context', note:'waits until you’re done with the thing'},
  4: {name:'Ambient',    note:'never interrupts — lives here and in the menu bar'},
};

// ------------------------------------------------------------- tabs ---------
// Four jobs, one at a time. Everything used to stack into a single scroll, so
// the reminders — the only thing you open this page to check — were buried
// under diagnostics. Selection persists: whichever view you live in is the one
// you get back.
const TABS = [
  {id:'reminders', label:'Reminders', count:d=>d.counts.reminders_active},
  {id:'delivered', label:'Delivered', count:d=>d.counts.notified_today},
  {id:'teach',     label:'Teach',     count:d=>d.counts.open},
  {id:'internals', label:'Internals', count:()=>null},
  {id:'settings',  label:'Settings',  count:()=>null},
];
let tab = localStorage.getItem('cr.tab') || 'reminders';

function setTab(id){
  tab = id;
  localStorage.setItem('cr.tab', id);
  document.querySelectorAll('main > section').forEach(s=>{
    s.hidden = s.dataset.tab !== id;
  });
  document.querySelectorAll('nav.tabs button').forEach(b=>{
    b.classList.toggle('sel', b.dataset.tab === id);
  });
}

function renderTabs(d){
  // a tab for a disabled experiment is a dead end; drop it entirely
  const shown = TABS.filter(t => t.id !== 'teach' || d.suggestions_on);
  if(!d.suggestions_on && tab === 'teach') setTab('reminders');
  $('tabs').innerHTML = shown.map(t=>{
    const n = t.count(d);
    return `<button data-tab="${t.id}" class="${t.id===tab?'sel':''}"
      onclick="setTab('${t.id}')">${t.label}${
        n ? `<span class="n">${n}</span>` : ''}</button>`;
  }).join('');
  window.__tabs = shown;   // number keys index what's actually shown
}

function fmtDue(ts){
  const s = ts - Date.now()/1000;
  const clock = new Date(ts*1000).toLocaleTimeString([], {hour:'numeric', minute:'2-digit'});
  if (s <= 0) return 'now';
  if (s < 90) return `in ${Math.round(s)}s (${clock})`;
  if (s < 5400) return `in ${Math.round(s/60)} min (${clock})`;
  if (s < 129600) return `in ${(s/3600).toFixed(1)} hr (${clock})`;
  return `in ${Math.round(s/86400)} d (${clock})`;
}

function fmtAgo(iso){
  if(!iso) return '';
  const d = new Date(iso), s = (Date.now() - d.getTime())/1000;
  const clock = d.toLocaleTimeString([], {hour:'numeric', minute:'2-digit'});
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s/60)} min ago`;
  if (d.toDateString() === new Date().toDateString()) return clock;
  return d.toLocaleDateString([], {weekday:'short'}) + ' ' + clock;
}

// ------------------------------------------------------- reminders ----------
// Read at a glance means: answer "when" before "what". The time is pulled out
// into a fixed left rail so a column of reminders scans vertically as a
// schedule, instead of forcing you to read each sentence to find the clock.
// Timed ones sort by when they fire; contextual ones can't be sorted that way
// (they fire on an event, not a time) so they group below under their own
// heading rather than pretending to have a place in the order.

function railFor(r){
  if(r.dueAt){
    const s = r.dueAt - Date.now()/1000;
    const clock = new Date(r.dueAt*1000).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'});
    const day = new Date(r.dueAt*1000).toDateString() !== new Date().toDateString()
      ? new Date(r.dueAt*1000).toLocaleDateString([],{weekday:'short'}) + ' ' : '';
    let rel;
    if(s <= 0) rel = 'now';
    else if(s < 90) rel = `${Math.round(s)}s`;
    else if(s < 5400) rel = `${Math.round(s/60)} min`;
    else if(s < 129600) rel = `${(s/3600).toFixed(1)} hr`;
    else rel = `${Math.round(s/86400)} days`;
    return {cls: s < 900 ? 'soon' : '', top: day+clock, sub: rel};
  }
  const map = {pending:'waiting', armed:'watching', cooldown:'watching',
               ready:'any moment', snoozed:'snoozed', fired:'reminded'};
  // only a sub-label that adds something: "on your screen" restated the state
  return {cls:'ctx', top: map[r.state] || r.state,
          sub: r.state==='pending' ? 'not seen yet' : ''};
}

function renderReminders(list){
  const el = $('rem');
  if(!list.length){
    el.innerHTML = `<div class="card empty">
      Nothing yet.<br>Say “hey screenreader, remind me to …” or press control+option+command+N.</div>`;
    return;
  }

  // Provenance before state. The first question about a reminder you didn't
  // expect is always "when did I ask for this?" — so that line comes first,
  // then why it's timed/bound, then what happens next in a full sentence.
  const lines = r => {
    const out = [];
    const made = r.createdAt
      ? new Date(r.createdAt*1000).toLocaleTimeString([], {hour:'numeric', minute:'2-digit'})
      : null;
    if(made) out.push(`you said this at ${made}${r.via ? ', by ' + esc(r.via) : ''}`);
    if(r.whenPhrase) out.push(`you said “${esc(r.whenPhrase)}” → ${esc(fmtDue(r.dueAt))}`);
    if(r.condPhrase) out.push(`you said “${esc(r.condPhrase)}”`);
    const place = r.referent && r.referent.label;
    if(place && place !== 'anywhere'){
      // A binding is only a trigger for contextual reminders. On a timed one
      // the window is just where you were standing — labelling both with the
      // same pin taught you to distrust the pin.
      out.push(r.dueAt
        ? `set while you were in ${esc(place)} <span class="dim">(not a trigger)</span>`
        : `while you were in ${esc(place)}`);
    }
    // No line here for "surfaces when you're done" — the group header above
    // already says exactly that, and a row that restates its own heading is
    // three sentences to learn one fact.
    return out;
  };

  const row = r => {
    const rail = railFor(r);
    const t = r.tier || 2;
    return `<div class="rem ${rail.cls} t${t}">
      <div class="rail ${rail.cls==='ctx'?'ctx':''}">
        <b>${esc(rail.top)}</b><span>${esc(rail.sub)}</span>
      </div>
      <div class="body">
        <div class="t">${esc(r.text)}</div>
        ${lines(r).map(l=>`<div class="prov">↳ ${l}</div>`).join('')}
        <div class="chips">${chipRow(r)}</div>
      </div>
      <div class="acts">
        <button class="y" title="Mark done" onclick="setRemState('${esc(r.id)}','done')">Done</button>
        <button title="Edit text" onclick="editRem('${esc(r.id)}')">Edit</button>
        <button class="n" title="Cancel" onclick="setRemState('${esc(r.id)}','cancelled')">✕</button>
      </div>
    </div>`;
  };

  // Sorted by what it costs to miss, not by clock: the thing that can hurt
  // you is always at the top.
  let html = '';
  for(const t of [1,2,3,4]){
    const group = list.filter(r => (r.tier||2) === t);
    if(!group.length) continue;
    group.sort((a,b)=> (a.dueAt||Infinity) - (b.dueAt||Infinity));
    html += `<div class="grp">${TIERS[t].name}<span class="grpNote"> · ${TIERS[t].note}</span></div>`
         +  group.map(row).join('');
  }
  el.innerHTML = html;
}

// one plain-language line per reminder — no state-machine jargon
function stateLine(r){
  if (r.state === 'scheduled') return '⏰ ' + fmtDue(r.dueAt);
  if (r.state === 'pending')   return "⏳ will start watching when it appears";
  if (r.state === 'armed')     return "👁 watching — reminds you when you're done";
  if (r.state === 'cooldown' || r.state === 'ready') return "👀 you stepped away — reminding you soon";
  if (r.state === 'snoozed')   return '💤 snoozed';
  if (r.state === 'fired')     return '🔔 reminded — mark it done on the card';
  return r.state;
}

function chipRow(r){
  return (state.channels_available||[]).map(c=>{
    const active = (r.channels||['card']).includes(c.name);
    return `<span class="chip ${active?'chipOn':''} ${c.configured?'':'chipNA'}"
      title="${esc(c.desc)}${c.configured?'':' — not configured yet'}"
      onclick="toggleCh('${esc(r.id)}','${esc(c.name)}')">${esc(c.name)}</span>`;
  }).join('');
}

async function toggleCh(id, name){
  const r = (state.reminders||[]).find(x=>x.id===id);
  if(!r) return;
  const cur = r.channels || ['card'];
  const next = cur.includes(name) ? cur.filter(c=>c!==name) : cur.concat([name]);
  if(!next.length) return; // a reminder must land somewhere
  await fetch('/api/reminder/channels',{method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({id, channels: next})});
  load();
}

async function load(){
  const d = await (await fetch('/api/state')).json();
  state = d;

  $('ctx').textContent = '👁 ' + d.context;
  const w = $('watch');
  w.innerHTML = `<span class="dot ${d.watching?'on':'off'}"></span>`
    + `${d.watching?'watching':'idle'}${d.voice?' · 🎙 listening':''}`;

  const c = d.counts;
  section('tabs', () => renderTabs(d));
  section('hotkeys', () => renderHotkeys());

  // non-default delivery is worth calling out; a plain local card is assumed
  const chPills = ch => (ch && (ch.length > 1 || ch[0] !== 'card'))
    ? ch.map(x=>`<span class="pill">📣 ${esc(x)}</span>`).join('') : '';
  const nots = d.notifications || [];
  $('notifs').innerHTML = (nots.length
    ? `<div class="row" style="margin:0 2px 10px">
         <div class="grow meta">${nots.length} shown${d.delivered_hidden?` · ${d.delivered_hidden} cleared`:''}</div>
         <button class="n" onclick="clearDelivered()">Clear all</button>
         ${d.delivered_hidden?`<button onclick="restoreDelivered()">Restore cleared</button>`:''}
       </div>` : '')
    + (nots.length
      ? nots.slice(-12).reverse().map(n=>`<div class="card" id="n-${esc(n._key)}"><div class="row">
          <div class="grow">
            <div class="act">${esc(n.body||n.title||'')}</div>
            <div class="meta">${n.referent?'from '+esc(n.referent):''}</div>
          </div>
          ${chPills(n.channels)}
          <span class="when">${esc(fmtAgo(n.iso))}</span>
          <button title="Clear this one" onclick="dismissDelivered('${esc(n._key)}')">✕</button>
        </div></div>`).join('')
      : `<div class="card empty">Nothing delivered${d.delivered_hidden?' — '+d.delivered_hidden+' cleared':''}.<br>
           Try “hey screenreader, remind me to stretch in 2 minutes”.</div>`);

  const open = d.suggestions || [];
  queue = open;   // the count now lives in the tab bar, not a heading
  section('teach', () => renderTeach());
  section('trainbar', () => renderTrainBar());

  $('sugg').innerHTML = open.length
    ? open.map(s=>`<div class="card" id="c-${esc(s.id)}"><div class="row">
        <div class="grow">
          <div class="act">${esc(s.action)}</div>
          <div class="meta">spotted in ${esc(s.app||s.source||'your screen')}</div>
        </div>
        <button class="y" onclick="judge('${esc(s.id)}','accept')">Remind me</button>
        <button class="n" onclick="judge('${esc(s.id)}','dismiss')">No</button>
        <button onclick="judge('${esc(s.id)}','not_mine')">Not mine</button>
      </div></div>`).join('')
    : `<div class="card empty">Nothing waiting.</div>`;

  section('rem', () => renderReminders(d.reminders || []));

  $('devstats').innerHTML = [
    ['ocr captures today', c.captures_today],
    ['capture files', c.capture_files],
    ['candidates found', c.candidates],
    ['labels given', c.labels],
    ['precision', c.precision===null?'—':c.precision+'%'],
  ].map(([k,v])=>`<div class="stat"><b>${v}</b><span>${k}</span></div>`).join('');

  $('weights').innerHTML = d.weights.length
    ? d.weights.map(w=>`<div class="wt"><span class="mono">${esc(w.feature)}</span>
        <span><b class="mono">${w.multiplier.toFixed(2)}×</b>
        <span style="color:var(--dim)"> ${w.accept}✓ ${w.dismiss}✗</span></span></div>`).join('')
    : `<div class="empty">No weights yet — answer a few suggestions, then run<br>
       <span class="mono">extract.py --learn</span></div>`;

  $('caps').innerHTML = d.captures.slice(0,8).map(c=>`<div class="card">
      <div class="meta">${esc(fmtAgo(c.iso))} · ${c.chars} chars · ${c.ms}ms · ${esc(c.mode||'')}</div>
      <div class="act" style="font-size:13px">${esc(c.source)}</div>
      <details><summary>text</summary><pre>${esc(c.text)}</pre></details>
    </div>`).join('') || `<div class="card empty">No captures yet.</div>`;
}

// remember whether the internals drawer was open
setTab(tab);  // restore the view you were last in, before the first fetch lands

// ---------------------------------------------------------- teaching --------
// Labeling is the only thing the learning layer runs on, so the cost of one
// label has to be near zero: one card at a time, one keystroke each, and an
// undo — because a wrong label is worse than no label.

let queue = [], cursor = 0, lastTrain = null, busy = false;

function renderTeach(){
  const el = $('teach');
  const c = queue[cursor];
  if(!c){
    el.innerHTML = `<div class="card empty">
      All caught up — nothing left to review.<br>
      New suggestions appear here as they're spotted on your screen.</div>`;
    return;
  }
  const feats = (c.features||[]).map(f=>`<span>${esc(f)}</span>`).join('');
  el.innerHTML = `<div class="teach">
    <div class="teachTop">
      <span>${cursor+1} of ${queue.length} · spotted in ${esc(c.app||c.source||'your screen')}</span>
      <span>confidence ${(c.confidence??c.score??0).toFixed(2)}</span>
    </div>
    <div class="teachAct">${esc(c.action)}</div>
    ${c.evidence?`<div class="quote">“${esc(c.evidence)}”</div>`:''}
    <div class="feat">${feats}</div>
    <div class="teachBtns">
      <button class="y" onclick="label('accept')">Remind me<kbd>Y</kbd></button>
      <button class="n" onclick="label('dismiss')">Not a task<kbd>N</kbd></button>
      <button onclick="label('not_mine')">Not mine<kbd>M</kbd></button>
      <button onclick="skip()">Skip<kbd>→</kbd></button>
      <button onclick="undo()" style="margin-left:auto">Undo<kbd>U</kbd></button>
    </div>
  </div>`;
}

function renderTrainBar(){
  const t = state.training || {labels:0, target:20, accepts:0, dismisses:0};
  const pct = Math.min(100, Math.round(100*t.labels/Math.max(t.target,1)));
  const ready = t.labels >= t.target;
  $('trainbar').innerHTML = `<div class="card">
    <div class="row">
      <div class="grow">
        <div class="meta">${t.labels} labels · ${t.accepts} kept · ${t.dismisses} rejected${
          t.features_learned?` · ${t.features_learned} features learned`:''}</div>
        <div class="bar"><i style="width:${pct}%"></i></div>
        <div class="meta">${ready
          ? 'Enough signal to train on.'
          : `${t.target - t.labels} more before the weights mean much (each feature needs a few examples).`}</div>
      </div>
      <button class="${ready?'y':''}" onclick="train()" ${busy?'disabled':''}>
        ${busy?'Training…':'Train now'}</button>
    </div>
    ${lastTrain?renderTrained():''}
  </div>`;
}

function renderTrained(){
  if(!lastTrain.ok) return `<div class="trained">Training failed: ${esc(lastTrain.message)}</div>`;
  const rows = (lastTrain.weights||[]).slice(0,8).map(w=>{
    const d = w.is_new ? '<span class="pill">new</span>'
      : w.delta > 0 ? `<span class="up">▲ ${w.delta.toFixed(2)}</span>`
      : w.delta < 0 ? `<span class="down">▼ ${Math.abs(w.delta).toFixed(2)}</span>` : '';
    return `<div class="wt"><span class="mono">${esc(w.feature)}</span>
      <span><b class="mono">${w.multiplier.toFixed(2)}×</b> ${d}
      <span style="color:var(--dim)"> ${w.accept}✓ ${w.dismiss}✗</span></span></div>`;
  }).join('');
  return `<div class="trained"><b>${esc(lastTrain.message)}</b>
    <div style="margin-top:8px">${rows}</div>
    <div class="meta" style="margin-top:8px">Scores below 1.00× are suppressed, above are boosted.
      New suggestions are scored with these from now on.</div></div>`;
}

async function label(value){
  const c = queue[cursor];
  if(!c) return;
  queue.splice(cursor, 1);                    // advance immediately
  if(cursor >= queue.length) cursor = Math.max(0, queue.length-1);
  section('teach', () => renderTeach());
  await fetch('/api/feedback',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({id:c.id, value})});
  load();
}

function skip(){ if(queue.length){ cursor = (cursor+1) % queue.length; renderTeach(); } }

async function undo(){
  const r = await (await fetch('/api/undo',{method:'POST',
    headers:{'Content-Type':'application/json'}, body:'{}'})).json();
  if(r.ok && r.undone) cursor = 0;
  load();
}

async function train(){
  if(busy) return;
  busy = true; renderTrainBar();
  try{
    lastTrain = await (await fetch('/api/learn',{method:'POST',
      headers:{'Content-Type':'application/json'}, body:'{}'})).json();
  }catch(e){ lastTrain = {ok:false, message:String(e), weights:[]}; }
  busy = false;
  load();
}

document.addEventListener('keydown', e=>{
  if(recording) return;   // the recorder owns the keyboard while it's armed
  if(e.metaKey||e.ctrlKey||e.altKey) return;
  if(/^(input|textarea)$/i.test(e.target.tagName)) return;
  // 1-4 jump between views from anywhere
  const n = parseInt(e.key, 10);
  const tabs = window.__tabs || TABS;
  if(n >= 1 && n <= tabs.length){ setTab(tabs[n-1].id); e.preventDefault(); return; }
  if(tab !== 'teach') return;   // labeling keys belong to the teaching view only
  const k = e.key.toLowerCase();
  if(k==='y') label('accept');
  else if(k==='n') label('dismiss');
  else if(k==='m') label('not_mine');
  else if(k==='u') undo();
  else if(e.key==='ArrowRight') skip();
  else return;
  e.preventDefault();
});

// Clearing hides a row; it never edits the event log, which is the record of
// what was actually delivered. "Restore cleared" is therefore always possible.
async function dismissDelivered(key){
  const el = $('n-'+key); if(el) el.style.opacity = .3;
  await fetch('/api/delivered/dismiss',{method:'POST',
    headers:{'Content-Type':'application/json'}, body:JSON.stringify({key})});
  load();
}

async function clearDelivered(){
  // only what's on screen — a delivery that lands mid-click shouldn't vanish unseen
  const keys = (state.notifications||[]).map(n=>n._key);
  await fetch('/api/delivered/clear',{method:'POST',
    headers:{'Content-Type':'application/json'}, body:JSON.stringify({keys})});
  load();
}

async function restoreDelivered(){
  await fetch('/api/delivered/restore',{method:'POST',
    headers:{'Content-Type':'application/json'}, body:'{}'});
  load();
}

// ------------------------------------------------------- hotkey editing ----
// Capture is a live keydown listener rather than a text field, because typing
// "control + option + command + N" as text is both tedious and a source of
// chords that don't exist. Recording ends on the first non-modifier key.
let recording = null;

function renderHotkeys(){
  const list = state.hotkeys || [];
  if(!list.length){
    $('hotkeys').innerHTML = `<div class="card empty">
      Hammerspoon isn't reachable, so shortcuts can't be read or changed.</div>`;
    return;
  }
  $('hotkeys').innerHTML = list.map(h=>`
    <div class="card"><div class="row">
      <div class="grow">
        <div class="act">${esc(h.label)}</div>
        <div class="meta">${recording===h.id
          ? '<span style="color:var(--accent)">press the keys now… (esc to cancel)</span>'
          : esc(h.chord) + (h.isDefault ? '' : ` · default was ${esc(h.default)}`)}</div>
      </div>
      ${recording===h.id
        ? `<button onclick="stopRecording()">Cancel</button>`
        : `<button onclick="record('${esc(h.id)}')">Change</button>`}
      ${h.isDefault ? '' : `<button onclick="resetHotkeys('${esc(h.id)}')">Reset</button>`}
    </div></div>`).join('')
    + `<div id="hkErr" class="meta" style="color:var(--bad);padding:4px 4px 0"></div>`;
}

function record(id){ recording = id; renderHotkeys(); }
function stopRecording(){ recording = null; renderHotkeys(); }

async function resetHotkeys(id){
  await fetch('/api/hotkey/reset',{method:'POST',
    headers:{'Content-Type':'application/json'}, body:JSON.stringify(id?{id}:{})});
  load();
}

document.addEventListener('keydown', async e=>{
  if(!recording) return;
  e.preventDefault(); e.stopPropagation();
  if(e.key === 'Escape'){ stopRecording(); return; }
  // wait for a real key — a chord is not finished while only modifiers are down
  if(['Meta','Control','Alt','Shift'].includes(e.key)) return;
  const mods = [];
  if(e.ctrlKey)  mods.push('ctrl');
  if(e.altKey)   mods.push('alt');
  if(e.metaKey)  mods.push('cmd');
  if(e.shiftKey) mods.push('shift');
  const id = recording;
  recording = null;
  const r = await (await fetch('/api/hotkey',{method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({id, mods, key:e.key.toLowerCase()})})).json();
  await load();
  if(!r.ok){
    const el = $('hkErr');
    if(el) el.textContent = "Couldn't set that: " + (r.error || 'rejected');
  }
}, true);

async function setRemState(id, st){
  await fetch('/api/reminder/state',{method:'POST',
    headers:{'Content-Type':'application/json'}, body:JSON.stringify({id, state:st})});
  load();
}

async function editRem(id){
  const r = (state.reminders||[]).find(x=>x.id===id);
  if(!r) return;
  const text = prompt('Reminder text:', r.text);
  if(text === null || !text.trim() || text === r.text) return;
  await fetch('/api/reminder/text',{method:'POST',
    headers:{'Content-Type':'application/json'}, body:JSON.stringify({id, text})});
  load();
}

async function judge(id, value){
  const el = $('c-'+id);
  if(el){ el.style.opacity=.35; }
  await fetch('/api/feedback',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({id,value})});
  load();
}

load(); setInterval(load, 4000);
</script>
"""


# --------------------------------------------------------------- server ------


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            self._send(200, PAGE.encode(), "text/html; charset=utf-8")
        elif path == "/api/state":
            self._send(200, json.dumps(snapshot()).encode(), "application/json")
        else:
            self._send(404, b"not found", "text/plain")

    def do_POST(self):  # noqa: N802
        path = urlparse(self.path).path
        n = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            self._send(400, b'{"ok":false}', "application/json")
            return

        if path == "/api/feedback":
            cand = find_candidate(payload.get("id", ""))
            if cand:
                write_feedback(cand, payload.get("value", "dismiss"))
            self._send(200, json.dumps({"ok": bool(cand)}).encode(), "application/json")

        elif path == "/api/reminder/state":
            # Lua owns reminders.json; going through it keeps its in-memory
            # copy and the file from diverging.
            rid = str(payload.get("id", ""))
            st = str(payload.get("state", ""))
            if not rid.isalnum() or st not in ("done", "cancelled", "pending"):
                self._send(400, b'{"ok":false}', "application/json"); return
            lua = ("local r = CR.reminders.get('%s'); if not r then return 'no' end; "
                   "CR.reminders.setState(r, '%s', 'web'); "
                   "if CR.menubar then pcall(CR.menubar.refresh) end; return 'ok'") % (rid, st)
            ok = hs(lua, timeout=10) == "ok"
            self._send(200, json.dumps({"ok": ok}).encode(), "application/json")

        elif path == "/api/reminder/text":
            rid = str(payload.get("id", ""))
            text = str(payload.get("text", "")).strip()[:200]
            if not rid.isalnum() or not text:
                self._send(400, b'{"ok":false}', "application/json"); return
            safe = text.replace("\\", "\\\\").replace("'", "\\'").replace("\n", " ")
            lua = ("local r = CR.reminders.get('%s'); if not r then return 'no' end; "
                   "r.text = '%s'; CR.reminders.persist(); "
                   "if CR.menubar then pcall(CR.menubar.refresh) end; return 'ok'") % (rid, safe)
            ok = hs(lua, timeout=10) == "ok"
            self._send(200, json.dumps({"ok": ok}).encode(), "application/json")

        elif path == "/api/hotkey":
            # Validation lives in Lua with the binder, not here: only it knows
            # what macOS will actually accept and what's already taken.
            hid = str(payload.get("id", ""))
            key = str(payload.get("key", "")).lower()
            mods = [m for m in payload.get("mods", [])
                    if m in ("ctrl", "alt", "cmd", "shift")]
            if not hid.isalpha() or len(key) != 1 or not key.isalnum():
                self._send(200, json.dumps({"ok": False, "error": "invalid key"}).encode(),
                           "application/json")
                return
            lua = "local ok, err = CR.hotkeys.set('%s', {%s}, '%s'); return hs.json.encode({ok=ok, err=err})" % (
                hid, ",".join(f"'{m}'" for m in mods), key)
            try:
                res = json.loads(hs(lua, timeout=15) or '{"ok":false}')
            except json.JSONDecodeError:
                res = {"ok": False, "err": "Hammerspoon unreachable"}
            self._send(200, json.dumps({"ok": bool(res.get("ok")),
                                        "error": res.get("err")}).encode(),
                       "application/json")

        elif path == "/api/hotkey/reset":
            hid = str(payload.get("id", ""))
            lua = ("CR.hotkeys.reset('%s'); return 'ok'" % hid) if hid.isalpha() \
                else "CR.hotkeys.reset(); return 'ok'"
            ok = hs(lua, timeout=15) == "ok"
            self._send(200, json.dumps({"ok": ok}).encode(), "application/json")

        elif path == "/api/delivered/dismiss":
            key = str(payload.get("key", ""))
            keys = load_dismissed()
            if key:
                keys.add(key)
                save_dismissed(keys)
            self._send(200, json.dumps({"ok": bool(key)}).encode(), "application/json")

        elif path == "/api/delivered/clear":
            # hide everything currently visible, not everything ever — a row
            # that arrives while you're reading shouldn't vanish unseen
            keys = load_dismissed()
            for k in payload.get("keys", []):
                if isinstance(k, str):
                    keys.add(k)
            save_dismissed(keys)
            self._send(200, json.dumps({"ok": True, "hidden": len(keys)}).encode(),
                       "application/json")

        elif path == "/api/delivered/restore":
            save_dismissed(set())
            self._send(200, b'{"ok":true}', "application/json")

        elif path == "/api/learn":
            try:
                self._send(200, json.dumps(run_learn()).encode(), "application/json")
            except Exception as e:  # a failed train must not take the UI down
                self._send(200, json.dumps({"ok": False, "message": str(e)[:200],
                                            "weights": []}).encode(), "application/json")

        elif path == "/api/undo":
            row = undo_last_feedback()
            self._send(200, json.dumps({"ok": row is not None,
                                        "undone": row}).encode(), "application/json")

        elif path == "/api/reminder/channels":
            # channel edits go through the running Hammerspoon so its in-memory
            # state and reminders.json can't diverge (Lua owns that file)
            rid = str(payload.get("id", ""))
            channels = payload.get("channels", [])
            valid = {"card", "system", "discord", "slack", "webhook"}
            if (not rid.isalnum() or not channels
                    or not all(isinstance(c, str) and c in valid for c in channels)):
                self._send(400, b'{"ok":false}', "application/json")
                return
            lua = "return tostring(CR.reminders.setChannels('%s', {%s}))" % (
                rid, ",".join(f"'{c}'" for c in channels))
            ok = hs(lua) == "true"
            self._send(200, json.dumps({"ok": ok}).encode(), "application/json")

        else:
            self._send(404, b"not found", "text/plain")

    def log_message(self, *a):  # silence per-request logging
        pass


def main() -> None:
    print(f"Contextual Reminders UI → http://localhost:{PORT}")
    print("(ctrl-C to stop)")
    try:
        HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
