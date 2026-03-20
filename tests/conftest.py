from unittest.mock import MagicMock

import pytest

from blablatotext.summarizer import Summarizer
from blablatotext.transcriber import Transcriber

MOCK_TRANSCRIPT = (
    "La tokenizacion es el proceso de dividir texto en unidades "
    "mas pequeñas llamadas tokens."
)
MOCK_SUMMARY = "La tokenizacion divide texto en unidades llamadas tokens."


@pytest.fixture
def audio_file(tmp_path):
    """Archivo WAV minimo para tests."""
    f = tmp_path / "test.wav"
    # Cabecera RIFF valida (44 bytes) para que Path.exists() sea True
    f.write_bytes(b"RIFF" + b"\x00" * 40)
    return f


@pytest.fixture
def mock_transcriber(audio_file):
    """Transcriber con pipeline mockeado. No descarga ningun modelo ni invoca ffmpeg."""
    transcriber = Transcriber()
    transcriber._pipeline = MagicMock(return_value={"text": MOCK_TRANSCRIPT})
    transcriber._load = MagicMock()
    transcriber._load_audio = MagicMock(
        return_value={"array": [0.0] * 100, "sampling_rate": 16000}
    )
    return transcriber


@pytest.fixture
def mock_summarizer():
    """Summarizer con pipeline mockeado. No descarga ningun modelo."""
    summarizer = Summarizer()
    summarizer._pipeline = MagicMock(return_value=[{"summary_text": MOCK_SUMMARY}])
    summarizer._load = MagicMock()
    return summarizer
