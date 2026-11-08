"""Kokoro TTS backed by MLX Audio on Apple Silicon.

The worker's existing ``ref_audio`` argument carries a built-in Kokoro voice
key (for example ``am_michael``). Kokoro does not clone voices and therefore
does not consume reference recordings or reference transcripts.
"""
from __future__ import annotations

from typing import Tuple

import numpy as np

from .. import config


class KokoroEngine:
    def __init__(self, repo: str = config.KOKORO_TTS_REPO):
        self.repo = repo
        self.model = None
        self.sample_rate = config.SAMPLE_RATE

    def load(self) -> None:
        if self.model is not None:
            return
        from mlx_audio.tts.utils import load_model
        self.model = load_model(self.repo)
        self.sample_rate = int(getattr(self.model, "sample_rate", config.SAMPLE_RATE))

    def synthesize(self, text: str, ref_audio: str, ref_text: str,
                   language: str = "auto") -> Tuple[np.ndarray, int]:
        assert self.model is not None, "call load() first"
        # mlx-audio returns an iterator of generation results. Long input can
        # be split internally, so concatenate every emitted audio block.
        generated = self.model.generate(
            text=text, voice=ref_audio, speed=1.0,
            lang_code="b" if ref_audio.startswith(("bf_", "bm_")) else "a")
        blocks = []
        for result in generated:
            audio = getattr(result, "audio", result)
            if hasattr(audio, "tolist"):
                audio = np.asarray(audio.tolist(), dtype=np.float32)
            else:
                audio = np.asarray(audio, dtype=np.float32)
            blocks.append(audio.reshape(-1))
            result_sr = getattr(result, "sample_rate", None)
            if result_sr:
                self.sample_rate = int(result_sr)
        if not blocks:
            return np.empty(0, dtype=np.float32), self.sample_rate
        return np.concatenate(blocks).astype(np.float32, copy=False), self.sample_rate
