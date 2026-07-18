"""Voice clone creation.

Pipeline: any audio/video file -> ffmpeg cut (~10-15 s, 24 kHz mono, edge
silence trimmed, level normalized) -> mlx-whisper transcription (runs in a
separate killable process with a timeout) -> stored voice row.
"""
from __future__ import annotations

import json
import subprocess
import sys
import threading
import time
from pathlib import Path

from . import config
from .db import DB
from .models_download import ensure_model
from .wavio import wav_info

CLIP_SECONDS = 15.0
TRANSCRIBE_TIMEOUT_S = 600

_WHISPER_SNIPPET = """
import json, sys
import mlx_whisper
result = mlx_whisper.transcribe(sys.argv[1], path_or_hf_repo=sys.argv[2])
print("@@" + json.dumps({"text": result.get("text", "").strip()}))
"""


def cut_reference_clip(source: str, dest_wav: Path,
                       start_s: float = 0.0,
                       duration_s: float = CLIP_SECONDS) -> tuple[int, float]:
    """Cut a clean reference clip. Returns (sample_rate, duration)."""
    dest_wav.parent.mkdir(parents=True, exist_ok=True)
    af = (
        # trim leading silence, then trailing (via double reverse)
        "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.15,"
        "areverse,silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.15,"
        "areverse,"
        "dynaudnorm=p=0.9"
    )
    cmd = [config.ffmpeg_path(), "-y", "-hide_banner", "-loglevel", "error",
           "-ss", str(max(start_s, 0.0)), "-i", str(source),
           "-t", str(duration_s + 5.0),  # cut generously, trim then cap
           "-vn", "-ac", "1", "-ar", str(config.SAMPLE_RATE),
           "-af", af, "-sample_fmt", "s16", str(dest_wav)]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if res.returncode != 0 or not dest_wav.exists():
        raise RuntimeError(f"ffmpeg clip cut failed: {res.stderr.strip()[:400]}")

    sr, dur = wav_info(dest_wav)
    if dur > duration_s:  # cap to target length
        tmp = dest_wav.with_suffix(".cap.wav")
        subprocess.run(
            [config.ffmpeg_path(), "-y", "-hide_banner", "-loglevel", "error",
             "-i", str(dest_wav), "-t", str(duration_s), str(tmp)],
            capture_output=True, timeout=120, check=True)
        tmp.replace(dest_wav)
        sr, dur = wav_info(dest_wav)
    if dur < 2.0:
        raise RuntimeError(
            f"reference clip too short after trimming ({dur:.1f}s) — "
            "pick a section with continuous speech")
    return sr, dur


def transcribe(wav_path: str, status: dict | None = None) -> str:
    """Transcribe with mlx-whisper in a killable child process."""
    cancel = threading.Event()
    if not ensure_model(config.WHISPER_REPO, config.WHISPER_SIZE_BYTES,
                        status if status is not None else {}, cancel):
        raise RuntimeError("Whisper model download failed")
    proc = subprocess.Popen(
        [sys.executable, "-c", _WHISPER_SNIPPET, wav_path, config.WHISPER_REPO],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        env=config.hf_env(), start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=TRANSCRIBE_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise RuntimeError("transcription timed out")
    for line in (out or "").splitlines():
        if line.startswith("@@"):
            return json.loads(line[2:])["text"]
    raise RuntimeError("transcription produced no result")


def create_voice(db: DB, name: str, source_path: str,
                 start_s: float = 0.0, status: dict | None = None) -> int:
    safe = "".join(c if c.isalnum() or c in "-_ " else "_" for c in name).strip() or "voice"
    dest = config.voices_dir() / f"{safe}_{int(time.time())}.wav"
    sr, dur = cut_reference_clip(source_path, dest, start_s=start_s)
    ref_text = transcribe(str(dest), status)
    return db.add_voice(name=name, ref_wav_path=str(dest), ref_text=ref_text,
                        source_path=source_path, sample_rate=sr, duration=dur)
