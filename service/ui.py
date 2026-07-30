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


def hs(lua: str) -> str:
    """Ask the running Hammerspoon instance for live state."""
    try:
        out = subprocess.run(
            ["hs", "-c", lua], capture_output=True, text=True, timeout=4
        )
        return out.stdout.strip().splitlines()[-1] if out.stdout.strip() else ""
    except Exception:
        return ""


def snapshot() -> dict:
    ocr = _tail_jsonl(today("ocr"), 40)
    events = _tail_jsonl(today("events"), 600)
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

    ctx = hs("local c=CR.observer.current; return c and ((c.app or '?')..' — '..(c.tab or c.title or '')) or 'no context'")
    watching = hs("return tostring(CR.screenText.watching)") == "true"

    # candidates not yet judged
    judged_ids = {f.get("id") for f in feedback}
    open_cands = [c for c in cands if c.get("id") not in judged_ids]

    caps_dir = LOGS / "captures"
    return {
        "context": ctx or "Hammerspoon not reachable",
        "watching": watching,
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
        "fires": [
            e for e in events if e.get("event") in ("trigger.fired", "suggestion.card")
        ][-10:],
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
  font:14px/1.55 ui-sans-serif,-apple-system,"SF Pro Text",system-ui,sans-serif}
header{padding:20px 24px 14px;border-bottom:1px solid var(--line);
  display:flex;align-items:baseline;gap:14px;flex-wrap:wrap}
h1{font-size:17px;margin:0;font-weight:650;letter-spacing:-.01em}
.ctx{color:var(--dim);font-size:12.5px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:46vw}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:5px}
.on{background:var(--good)}.off{background:var(--dim)}
main{padding:20px 24px 60px;max-width:1180px;margin:0 auto}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(118px,1fr));gap:10px;margin-bottom:22px}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:12px 14px}
.stat b{display:block;font-size:22px;font-weight:640;letter-spacing:-.02em}
.stat span{color:var(--dim);font-size:11.5px;text-transform:uppercase;letter-spacing:.05em}
h2{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--dim);
  margin:26px 0 10px;font-weight:600}
.card{background:var(--panel);border:1px solid var(--line);border-radius:11px;
  padding:13px 15px;margin-bottom:9px}
.row{display:flex;gap:12px;align-items:flex-start}
.grow{flex:1;min-width:0}
.act{font-weight:520}
.meta{color:var(--dim);font-size:12px;margin-top:3px;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.score{font-family:ui-monospace,Menlo,monospace;font-size:12px;padding:2px 7px;
  border-radius:5px;background:rgba(122,162,247,.13);color:var(--accent);white-space:nowrap}
.score.hi{background:rgba(224,175,104,.16);color:var(--warn)}
button{font:inherit;font-size:12.5px;padding:5px 11px;border-radius:7px;cursor:pointer;
  border:1px solid var(--line);background:transparent;color:var(--txt);transition:.12s}
button:hover{border-color:var(--accent)}
button.y{border-color:rgba(158,206,106,.4);color:var(--good)}
button.y:hover{background:rgba(158,206,106,.12)}
button.n:hover{background:rgba(247,118,142,.12);border-color:rgba(247,118,142,.4)}
.pill{font-size:11px;padding:1.5px 7px;border-radius:20px;border:1px solid var(--line);
  color:var(--dim);white-space:nowrap}
.empty{color:var(--dim);padding:16px;text-align:center;font-size:13px}
pre{white-space:pre-wrap;word-break:break-word;font-size:11.5px;color:var(--dim);
  max-height:150px;overflow:auto;margin:8px 0 0;font-family:ui-monospace,Menlo,monospace}
details summary{cursor:pointer;color:var(--dim);font-size:12px;outline:none}
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
<main>
  <div class="stats" id="stats"></div>

  <h2>Suggestions — should these become reminders?</h2>
  <div id="sugg"></div>

  <div class="grid2">
    <div>
      <h2>Watching now</h2>
      <div id="rem"></div>
      <h2>Recent fires</h2>
      <div id="fires"></div>
    </div>
    <div>
      <h2>What it's learned</h2>
      <div class="card" id="weights"></div>
      <h2>Latest captures</h2>
      <div id="caps"></div>
    </div>
  </div>
</main>
<script>
const esc = s => (s??'').toString().replace(/[&<>"]/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

async function load(){
  const d = await (await fetch('/api/state')).json();

  document.getElementById('ctx').textContent = d.context;
  const w = document.getElementById('watch');
  w.innerHTML = `<span class="dot ${d.watching?'on':'off'}"></span>${d.watching?'watching':'idle'}`;

  const c = d.counts;
  document.getElementById('stats').innerHTML = [
    ['captures today', c.captures_today],
    ['candidates', c.candidates],
    ['awaiting you', c.open],
    ['watching', c.reminders_active],
    ['labels given', c.labels],
    ['precision', c.precision===null?'—':c.precision+'%'],
  ].map(([k,v])=>`<div class="stat"><b>${v}</b><span>${k}</span></div>`).join('');

  document.getElementById('sugg').innerHTML = d.suggestions.length
    ? d.suggestions.map(s=>`<div class="card" id="c-${esc(s.id)}"><div class="row">
        <span class="score ${s.score>=.55?'hi':''}">${(s.score??0).toFixed(2)}</span>
        <div class="grow">
          <div class="act">${esc(s.action)}</div>
          <div class="meta">${esc(s.source||'')} · ${esc(s.kind||'')} · via ${esc(s.backend||'')}</div>
        </div>
        <button class="y" onclick="judge('${esc(s.id)}','accept')">Yes</button>
        <button onclick="judge('${esc(s.id)}','not_mine')">Not mine</button>
        <button class="n" onclick="judge('${esc(s.id)}','dismiss')">No</button>
      </div></div>`).join('')
    : `<div class="card empty">Nothing waiting. Suggestions appear here as they're found.</div>`;

  document.getElementById('rem').innerHTML = d.reminders.length
    ? d.reminders.map(r=>`<div class="card"><div class="row">
        <span class="pill">${esc(r.state)}</span>
        <div class="grow"><div class="act">${esc(r.text)}</div>
        <div class="meta">${esc((r.referent&&r.referent.label)||'')}</div></div>
      </div></div>`).join('')
    : `<div class="card empty">No active reminders. Press ⌃⌥⌘R while looking at something.</div>`;

  document.getElementById('fires').innerHTML = d.fires.length
    ? d.fires.slice().reverse().map(f=>`<div class="card"><div class="meta">
        ${esc(f.iso||'')} — ${esc(f.text||f.title||f.event)}</div></div>`).join('')
    : `<div class="card empty">Nothing has fired yet.</div>`;

  document.getElementById('weights').innerHTML = d.weights.length
    ? d.weights.map(w=>`<div class="wt"><span class="mono">${esc(w.feature)}</span>
        <span><b class="mono">${w.multiplier.toFixed(2)}×</b>
        <span style="color:var(--dim)"> ${w.accept}✓ ${w.dismiss}✗</span></span></div>`).join('')
    : `<div class="empty">No weights yet — answer a few suggestions, then run<br>
       <span class="mono">extract.py --learn</span></div>`;

  document.getElementById('caps').innerHTML = d.captures.map(c=>`<div class="card">
      <div class="meta">${esc(c.iso)} · ${c.chars} chars · ${c.ms}ms · ${esc(c.mode||'')}</div>
      <div class="act" style="font-size:13px">${esc(c.source)}</div>
      <details><summary>text</summary><pre>${esc(c.text)}</pre></details>
    </div>`).join('') || `<div class="card empty">No captures yet.</div>`;
}

async function judge(id, value){
  const el = document.getElementById('c-'+id);
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
        if urlparse(self.path).path != "/api/feedback":
            self._send(404, b"not found", "text/plain")
            return
        n = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            self._send(400, b'{"ok":false}', "application/json")
            return
        cand = find_candidate(payload.get("id", ""))
        if cand:
            write_feedback(cand, payload.get("value", "dismiss"))
        self._send(200, json.dumps({"ok": bool(cand)}).encode(), "application/json")

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
