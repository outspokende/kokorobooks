"""Pocket TTS voice cloning.

Runs only inside the worker child process, never in the app process.
"""
from __future__ import annotations

from typing import Tuple

import numpy as np

from .. import config


class PocketEngine:
    def __init__(self, repo: str = config.POCKET_TTS_REPO):
        self.repo = repo
        self.model = None
        self.sample_rate = config.SAMPLE_RATE
        self._voice_cache: dict = {}

    def load(self) -> None:
        if self.model is not None:
            return
        from pocket_tts import TTSModel
        self.model = TTSModel.load_model()
        self.sample_rate = self.model.sample_rate

    def _voice_state(self, ref_audio: str):
        """Encode the reference voice once and reuse it for every chunk.

        Kyutai's guidance is explicit: keep voice states in memory. Without
        this cache the voice embedding was re-encoded for each of the
        thousands of chunks in a book — pure wasted CPU per chunk.
        """
        state = self._voice_cache.get(ref_audio)
        if state is None:
            state = self.model.get_state_for_audio_prompt(ref_audio)
            self._voice_cache[ref_audio] = state
        return state

    def synthesize(self, text: str, ref_audio: str, ref_text: str,
                  language: str = "auto") -> Tuple[np.ndarray, int]:
        assert self.model is not None, "call load() first"
        voice_state = self._voice_state(ref_audio)
        audio = self.model.generate_audio(voice_state, text)
        audio_np = audio.numpy().astype(np.float32)
        if audio_np.ndim > 1:
            audio_np = audio_np.squeeze()
        return audio_np, self.sample_rate


_LANGUAGES = {
    "auto", "english", "french", "german", "portuguese", "italian", "spanish",
}


def _normalize_language(language: str) -> str:
    if not language:
        return "english"
    norm = language.strip().lower().replace("_", " ").replace(" ", "")
    if "auto" in norm:
        return "english"
    return norm if norm in _LANGUAGES else "english"
