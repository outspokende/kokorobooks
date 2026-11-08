"""Kokoro-specific configuration, fixed voices, and engine adapter tests."""
import sys
import types

import numpy as np
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(db):
    from app import config
    from app.server import create_app
    from app.supervisor import Supervisor
    result = TestClient(create_app(db, Supervisor(db)))
    result.headers.update({
        "Authorization": f"Bearer {config.get_or_create_token()}"})
    return result


def test_builtin_us_male_voices_have_stable_ids(db):
    voices = db.voices()
    assert [(v["id"], v["name"], v["ref_wav_path"]) for v in voices[:5]] == [
        (1, "Michael", "am_michael"),
        (2, "Adam", "am_adam"),
        (3, "Eric", "am_eric"),
        (4, "Liam", "am_liam"),
        (5, "Onyx", "am_onyx"),
    ]
    assert [(v["id"], v["name"], v["ref_wav_path"]) for v in voices[5:]] == [
        (6, "Emma (UK)", "bf_emma"),
        (7, "Isabella (UK)", "bf_isabella"),
    ]
    assert all(v["source_path"] == "builtin:kokoro" for v in voices)


def test_voice_api_is_read_only(client):
    # The iOS API client decodes this endpoint as a plain array.
    assert [v["id"] for v in client.get("/api/voices").json()] == [1, 2, 3, 4, 5, 6, 7]
    assert client.post("/api/voices", json={}).status_code == 405
    assert client.patch("/api/voices/1", json={"name": "Changed"}).status_code in (404, 405)
    assert client.delete("/api/voices/1").status_code in (404, 405)


def test_kokoro_engine_loads_and_concatenates(monkeypatch):
    calls = {}

    class Result:
        def __init__(self, values):
            self.audio = np.asarray(values, dtype=np.float32)
            self.sample_rate = 24000

    class Model:
        sample_rate = 24000

        def generate(self, **kwargs):
            calls.update(kwargs)
            return iter((Result([0.1, 0.2]), Result([0.3])))

    utils = types.ModuleType("mlx_audio.tts.utils")
    utils.load_model = lambda repo: Model()
    monkeypatch.setitem(sys.modules, "mlx_audio", types.ModuleType("mlx_audio"))
    monkeypatch.setitem(sys.modules, "mlx_audio.tts", types.ModuleType("mlx_audio.tts"))
    monkeypatch.setitem(sys.modules, "mlx_audio.tts.utils", utils)

    from app.engine.kokoro import KokoroEngine
    engine = KokoroEngine("test/repo")
    engine.load()
    audio, sample_rate = engine.synthesize("Hello", "am_michael", "ignored")
    assert sample_rate == 24000
    assert np.allclose(audio, [0.1, 0.2, 0.3])
    assert calls == {"text": "Hello", "voice": "am_michael",
                     "speed": 1.0, "lang_code": "a"}
    engine.synthesize("Hello", "bf_emma", "ignored")
    assert calls == {"text": "Hello", "voice": "bf_emma",
                     "speed": 1.0, "lang_code": "b"}


def test_separate_defaults_and_shared_library(env, monkeypatch):
    from app import config
    assert config.APP_NAME == "KokoroBooks"
    assert config.SERVER_PORT == 8724
    assert config.KOKORO_TTS_REPO == "mlx-community/Kokoro-82M-bf16"
