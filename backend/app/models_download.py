"""Robust HuggingFace model pre-flight.

The naive HF downloader can hang forever on dead CDN connections, so:
- Xet high-performance transfer is enabled (hf_xet + HF_XET_HIGH_PERFORMANCE=1)
  plus a socket timeout,
- the download runs in a separate KILLABLE child process,
- progress is estimated by watching the cache directory grow,
- a stall watchdog kills and retries when no bytes arrive for a while.
"""
from __future__ import annotations

import subprocess
import sys
import threading
import time
from pathlib import Path

from . import config

STALL_TIMEOUT_S = 120
MAX_RETRIES = 3

_DL_SNIPPET = """
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1])
print("DOWNLOAD_COMPLETE")
"""


def _cache_size(repo: str) -> int:
    from huggingface_hub.constants import HF_HUB_CACHE
    d = Path(HF_HUB_CACHE) / ("models--" + repo.replace("/", "--"))
    if not d.exists():
        return 0
    return sum(f.stat().st_size for f in d.rglob("*") if f.is_file())


def is_model_cached(repo: str) -> bool:
    try:
        from huggingface_hub import snapshot_download
        snapshot_download(repo, local_files_only=True)
        return True
    except Exception:  # noqa: BLE001
        return False


def ensure_model(repo: str, expected_bytes: int, status: dict,
                 cancel: threading.Event) -> bool:
    """Download `repo` if missing. Mutates `status` for UI progress.
    Returns True when the model is fully available locally."""
    if is_model_cached(repo):
        return True

    for attempt in range(1, MAX_RETRIES + 1):
        if cancel.is_set():
            return False
        status.update({"repo": repo, "state": "downloading", "attempt": attempt,
                       "progress": 0.0, "bytes": 0})
        proc = subprocess.Popen(
            [sys.executable, "-c", _DL_SNIPPET, repo],
            env=config.hf_env(), stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True)
        last_size, last_change = 0, time.monotonic()
        while proc.poll() is None:
            if cancel.is_set():
                proc.kill()
                status.update({"state": "cancelled"})
                return False
            size = _cache_size(repo)
            if size != last_size:
                last_size, last_change = size, time.monotonic()
            elif time.monotonic() - last_change > STALL_TIMEOUT_S:
                proc.kill()  # stalled — kill and retry
                break
            status.update({"bytes": size,
                           "progress": min(size / max(expected_bytes, 1), 0.99)})
            time.sleep(2)
        proc.wait()
        if is_model_cached(repo):
            status.update({"state": "done", "progress": 1.0})
            return True
        time.sleep(min(5 * attempt, 20))
    status.update({"state": "failed"})
    return False
