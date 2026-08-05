"""Piper TTS engine (ONNX backend). Fast CPU-first TTS.

Uses en_US-joe-medium. ~30-50x realtime on N95.
"""
from __future__ import annotations

from typing import Tuple

import numpy as np
import piper

# Piper sample rates: low=16000, medium=22050, high=22050
PIPER_SR = 22050


class PiperEngine:
    """Wrapper satisfying the TTSEngine protocol."""

    def __init__(self, model_path: str | None = None):
        self._model_path = model_path
        self._voice: piper.PiperVoice | None = None

    # ---- TTSEngine interface ----

    def load(self) -> None:
        from pathlib import Path

        if self._model_path is None:
            base = Path(__file__).resolve().parents[3] / "data" / "piper-voices"
            model_dir = base / "en_US-joe-medium"
        else:
            model_dir = Path(self._model_path)

        onnx = str(model_dir / "en_US-joe-medium.onnx")
        conf = str(model_dir / "en_US-joe-medium.onnx.json")
        self._voice = piper.PiperVoice.load(onnx, config_path=conf)

    def synthesize(
        self,
        text: str,
        ref_audio: str = "",
        ref_text: str = "",
        language: str = "auto",
    ) -> Tuple[np.ndarray, int]:
        """Return (float32 mono samples, sample_rate)."""
        assert self._voice is not None, "call load() first"

        # Piper returns AudioChunk iterable. Each chunk is int16 PCM at the
        # model's native rate. Concatenate all chunks into a single waveform.
        parts: list[np.ndarray] = []
        for chunk in self._voice.synthesize(text):
            # chunk is a bytes buffer of 16-bit PCM
            raw = chunk.audio_int16_bytes
            if raw and len(raw) > 0:
                parts.append(np.frombuffer(raw, dtype=np.int16))

        if not parts:
            return np.zeros(0, dtype=np.float32), PIPER_SR

        pcm = np.concatenate(parts)
        audio32 = pcm.astype(np.float32) / 32768.0
        return audio32, PIPER_SR
