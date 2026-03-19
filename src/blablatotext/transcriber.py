import subprocess
from pathlib import Path

import numpy as np
from transformers import pipeline as hf_pipeline

from blablatotext.config import settings

SAMPLING_RATE = 16000


class TranscriptionError(Exception):
    """Error especifico del proceso de transcripcion."""


class Transcriber:
    """
    Wrapper sobre el pipeline de Whisper (ASR).

    Usa lazy-loading: el modelo se carga solo cuando se llama
    a `transcribe()` por primera vez, evitando descargas en tests.
    """

    def __init__(self) -> None:
        self._pipeline = None

    def _load(self) -> None:
        if self._pipeline is None:
            self._pipeline = hf_pipeline(
                "automatic-speech-recognition",
                model=settings.asr_model,
                device=settings.device,
                generate_kwargs={"language": settings.asr_language},
            )

    def _load_audio(self, path: Path) -> dict:
        """Decodifica cualquier formato (incluyendo MP4) a numpy array via ffmpeg."""
        cmd = [
            "ffmpeg", "-i", str(path),
            "-ar", str(SAMPLING_RATE),
            "-ac", "1",
            "-f", "f32le",
            "pipe:1",
        ]
        result = subprocess.run(cmd, capture_output=True)  # noqa: S603
        if result.returncode != 0:
            raise TranscriptionError(f"ffmpeg error: {result.stderr.decode()}")
        audio = np.frombuffer(result.stdout, dtype=np.float32)
        if audio.shape[0] == 0:
            raise TranscriptionError(f"No se pudo decodificar audio de: {path}")
        return {"array": audio, "sampling_rate": SAMPLING_RATE}

    def transcribe(self, audio_path: str | Path) -> str:
        """
        Transcribe un archivo de audio a texto en español.

        Args:
            audio_path: Ruta al archivo de audio (.wav, .mp3, .flac, .mp4, etc).

        Returns:
            Texto transcrito, o cadena vacia si el audio no contiene voz.

        Raises:
            TranscriptionError: Si el archivo no existe o el modelo falla.
        """
        path = Path(audio_path)
        if not path.exists():
            raise TranscriptionError(f"Audio file not found: {path}")

        self._load()
        audio = self._load_audio(path)
        result = self._pipeline(audio, return_timestamps=True)  # type: ignore[misc]
        return result.get("text", "").strip()
