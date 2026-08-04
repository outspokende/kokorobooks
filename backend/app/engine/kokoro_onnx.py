"""Kokoro TTS backed by ONNX Runtime — runs on any x86/ARM CPU.

Drop-in replacement for the MLX engine; same voice keys (af_sarah, am_michael,
etc.) since it's the same Kokoro-82M model exported to ONNX.

Model files are expected at:
  $KBS_DATA_DIR/models/kokoro-v1.0.int8.onnx   (88 MB)
  $KBS_DATA_DIR/models/voices-v1.0.bin          (27 MB)

Override paths via env:
  KBS_ONNX_MODEL   — path to .onnx file
  KBS_ONNX_VOICES  — path to voices .bin file
"""
from __future__ import annotations

import os
from typing import Tuple

import numpy as np

from .. import config


def _default_model_path() -> str:
    return os.environ.get(
        "KBS_ONNX_MODEL",
        str(config.data_dir() / "models" / "kokoro-v1.0.int8.onnx"))


def _default_voices_path() -> str:
    return os.environ.get(
        "KBS_ONNX_VOICES",
        str(config.data_dir() / "models" / "voices-v1.0.bin"))


class KokoroOnnxEngine:
    def __init__(self):
        self.kokoro = None
        self.sample_rate = config.SAMPLE_RATE

    def load(self) -> None:
        if self.kokoro is not None:
            return
        import onnxruntime
        from kokoro_onnx import Kokoro

        model_path = _default_model_path()
        voices_path = _default_voices_path()

        # ONNX Runtime tuning for small x86 CPUs (e.g. Intel N95, 4 cores, no AVX-512).
        # Benchmarking on N95 (355-char sample, 18.8s audio) showed:
        #   intra=4 inter=2 (default)      -> 85.8s, RTF=0.219x
        #   intra=2 inter=1, ORT_ENABLE_ALL, ORT_SEQUENTIAL -> 63.2s, RTF=0.298x (~36% faster)
        # The Kokoro model is small and memory-bound on weak CPUs; using all 4 cores
        # causes thread-synchronization overhead that hurts more than it helps.
        # ORT_ENABLE_ALL fuses ops in the quantized graph; SEQUENTIAL execution mode
        # avoids the parallel-executor overhead since the model is already a single
        # inference call with batch=1.
        sess_options = onnxruntime.SessionOptions()
        sess_options.intra_op_num_threads = 2
        sess_options.inter_op_num_threads = 1
        sess_options.graph_optimization_level = (
            onnxruntime.GraphOptimizationLevel.ORT_ENABLE_ALL
        )
        sess_options.execution_mode = (
            onnxruntime.ExecutionMode.ORT_SEQUENTIAL
        )
        session = onnxruntime.InferenceSession(
            model_path, sess_options,
            providers=["CPUExecutionProvider"])

        self.kokoro = Kokoro.from_session(session, voices_path)
        self.sample_rate = config.SAMPLE_RATE  # Kokoro outputs 24 kHz

    def synthesize(self, text: str, ref_audio: str, ref_text: str,
                   language: str = "auto") -> Tuple[np.ndarray, int]:
        """Generate audio. ref_audio carries the Kokoro voice key (e.g.
        'af_sarah'). ref_text and language are unused (Kokoro doesn't clone)."""
        assert self.kokoro is not None, "call load() first"

        # kokoro-onnx returns (samples, sample_rate)
        samples, sr = self.kokoro.create(
            text, voice=ref_audio, speed=1.0, lang="en-us")

        audio = np.asarray(samples, dtype=np.float32).reshape(-1)
        self.sample_rate = int(sr)
        return audio, self.sample_rate
