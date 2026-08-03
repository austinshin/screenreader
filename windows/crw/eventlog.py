"""Append-only JSONL event log — one file per day, same shape as the Lua
side's logs/events-*.jsonl so the dashboard's Delivered tab keeps working."""

from __future__ import annotations

import json
import time
from pathlib import Path

from . import config


def today_path() -> Path:
    return config.logs_dir() / time.strftime("events-%Y-%m-%d.jsonl")


def append(event: dict) -> None:
    event.setdefault("ts", int(time.time()))
    event.setdefault("iso", time.strftime("%Y-%m-%dT%H:%M:%S"))
    try:
        with open(today_path(), "a", encoding="utf-8") as f:
            f.write(json.dumps(event, ensure_ascii=False, default=str) + "\n")
    except OSError:
        pass  # logging must never take the app down
