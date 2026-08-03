#!/usr/bin/env python3
"""Launcher:  python windows/run.py  (or: cd windows && python run.py)"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from crw.app import main  # noqa: E402

main()
