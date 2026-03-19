from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from blablatotext.api import app
from blablatotext.summarizer import SummarizationError
from blablatotext.transcriber import TranscriptionError
from tests.conftest import MOCK_SUMMARY, MOCK_TRANSCRIPT

# --- Fixtures ---

@pytest.fixture
def mock_t():
    m = MagicMock()
    m.transcribe.return_value = MOCK_TRANSCRIPT
    return m


@pytest.fixture
def mock_s():
    m = MagicMock()
    m.summarize.return_value = MOCK_SUMMARY
    return m


@pytest.fixture
def client(mock_t, mock_s):
    """TestClient con Transcriber y Summarizer mockeados via lifespan."""
    with (
        patch("blablatotext.api.Transcriber", return_value=mock_t),
        patch("blablatotext.api.Summarizer", return_value=mock_s),
        TestClient(app) as c,
    ):
        yield c


@pytest.fixture
def wav_bytes():
    """Bytes minimos de un archivo WAV valido."""
    return b"RIFF" + b"\x00" * 40


# --- /health ---

def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


# --- /transcribe ---

def test_transcribe_success(client, wav_bytes):
    r = client.post(
        "/transcribe",
        files={"audio": ("test.wav", wav_bytes, "audio/wav")},
    )
    assert r.status_code == 200
    assert r.json() == {"transcript": MOCK_TRANSCRIPT}


def test_transcribe_error_returns_422(client, mock_t, wav_bytes):
    mock_t.transcribe.side_effect = TranscriptionError("fallo ffmpeg")
    r = client.post(
        "/transcribe",
        files={"audio": ("test.wav", wav_bytes, "audio/wav")},
    )
    assert r.status_code == 422
    assert "fallo ffmpeg" in r.json()["detail"]


def test_transcribe_requires_file(client):
    r = client.post("/transcribe")
    assert r.status_code == 422


# --- /summarize ---

def test_summarize_success(client):
    r = client.post("/summarize", json={"text": "Texto de prueba para el resumen."})
    assert r.status_code == 200
    assert r.json() == {"summary": MOCK_SUMMARY}


def test_summarize_empty_text_returns_422(client, mock_s):
    mock_s.summarize.side_effect = SummarizationError("Cannot summarize empty text.")
    r = client.post("/summarize", json={"text": ""})
    assert r.status_code == 422
    assert "empty" in r.json()["detail"]


def test_summarize_missing_body_returns_422(client):
    r = client.post("/summarize", json={})
    assert r.status_code == 422


# --- /process ---

def test_process_success(client, wav_bytes):
    r = client.post(
        "/process",
        files={"audio": ("test.wav", wav_bytes, "audio/wav")},
    )
    assert r.status_code == 200
    data = r.json()
    assert data["transcript"] == MOCK_TRANSCRIPT
    assert data["summary"] == MOCK_SUMMARY


def test_process_empty_transcript_skips_summary(client, mock_t, mock_s, wav_bytes):
    mock_t.transcribe.return_value = ""
    r = client.post(
        "/process",
        files={"audio": ("test.wav", wav_bytes, "audio/wav")},
    )
    assert r.status_code == 200
    assert r.json() == {"transcript": "", "summary": ""}
    mock_s.summarize.assert_not_called()


def test_process_transcription_error_returns_422(client, mock_t, wav_bytes):
    mock_t.transcribe.side_effect = TranscriptionError("audio corrupto")
    r = client.post(
        "/process",
        files={"audio": ("test.wav", wav_bytes, "audio/wav")},
    )
    assert r.status_code == 422


def test_process_summarization_error_returns_422(client, mock_s, wav_bytes):
    mock_s.summarize.side_effect = SummarizationError("modelo fallo")
    r = client.post(
        "/process",
        files={"audio": ("test.wav", wav_bytes, "audio/wav")},
    )
    assert r.status_code == 422
