import pytest

from blablatotext.transcriber import Transcriber, TranscriptionError
from tests.conftest import MOCK_TRANSCRIPT


def test_transcribe_returns_text(mock_transcriber, audio_file):
    result = mock_transcriber.transcribe(audio_file)
    assert result == MOCK_TRANSCRIPT


def test_transcribe_strips_whitespace(mock_transcriber, audio_file):
    mock_transcriber._pipeline.return_value = {"text": "  texto con espacios  "}
    result = mock_transcriber.transcribe(audio_file)
    assert result == "texto con espacios"


def test_transcribe_missing_file_raises_error():
    transcriber = Transcriber()
    with pytest.raises(TranscriptionError, match="not found"):
        transcriber.transcribe("/ruta/inexistente/audio.wav")


def test_transcribe_empty_result(mock_transcriber, audio_file):
    mock_transcriber._pipeline.return_value = {"text": ""}
    result = mock_transcriber.transcribe(audio_file)
    assert result == ""


def test_lazy_load_not_called_before_transcribe():
    """El modelo no debe cargarse al instanciar la clase."""
    transcriber = Transcriber()
    assert transcriber._pipeline is None
