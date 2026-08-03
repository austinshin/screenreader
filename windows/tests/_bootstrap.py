"""Shared test setup: put the package on the path and point the data/log
directories at a throwaway temp dir so tests never touch the real store.
Import this FIRST in every test module."""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from crw import config  # noqa: E402

_tmp = Path(tempfile.mkdtemp(prefix="crw-test-"))
config.DATA_DIR = _tmp / "data"
config.LOGS_DIR = _tmp / "logs"
