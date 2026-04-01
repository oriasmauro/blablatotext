import tempfile
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from blablatotext.summarizer import SummarizationError, Summarizer
from blablatotext.transcriber import Transcriber, TranscriptionError

# --- Schemas ---


class HealthResponse(BaseModel):
    status: str


class TranscriptResponse(BaseModel):
    transcript: str


class SummarizeRequest(BaseModel):
    text: str


class SummaryResponse(BaseModel):
    summary: str


class ProcessResponse(BaseModel):
    transcript: str
    summary: str


# --- Lifespan: carga los singletons una vez al arrancar ---


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.transcriber = Transcriber()
    app.state.summarizer = Summarizer()
    yield


# --- App ---

app = FastAPI(
    title="blablatotext API",
    description="Transcripcion y resumen automatico de audio en español.",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# --- Helpers ---


async def _save_upload(upload: UploadFile) -> Path:
    """Guarda el UploadFile en un archivo temporal y devuelve su ruta."""
    suffix = Path(upload.filename or "audio.wav").suffix or ".wav"
    tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)  # noqa: SIM115
    try:
        tmp.write(await upload.read())
    finally:
        tmp.close()
    return Path(tmp.name)


# --- Routes ---


@app.get("/health", response_model=HealthResponse, tags=["ops"])
def health() -> HealthResponse:
    """Healthcheck para el load balancer."""
    return HealthResponse(status="ok")


@app.post("/transcribe", response_model=TranscriptResponse, tags=["inference"])
async def transcribe(audio: UploadFile = File(...)) -> TranscriptResponse:
    """
    Transcribe un archivo de audio al español usando Whisper.

    - **audio**: archivo de audio (.wav, .mp3, .flac, .mp4, etc.)
    """
    tmp_path = await _save_upload(audio)
    try:
        transcript = app.state.transcriber.transcribe(tmp_path)
    except TranscriptionError as e:
        raise HTTPException(status_code=422, detail=str(e)) from e
    finally:
        tmp_path.unlink(missing_ok=True)
    return TranscriptResponse(transcript=transcript)


@app.post("/summarize", response_model=SummaryResponse, tags=["inference"])
def summarize(body: SummarizeRequest) -> SummaryResponse:
    """
    Genera un resumen del texto proporcionado usando LED.

    - **text**: texto de entrada (min. ~50 palabras recomendado)
    """
    try:
        summary = app.state.summarizer.summarize(body.text)
    except SummarizationError as e:
        raise HTTPException(status_code=422, detail=str(e)) from e
    return SummaryResponse(summary=summary)


@app.post("/process", response_model=ProcessResponse, tags=["inference"])
async def process(audio: UploadFile = File(...)) -> ProcessResponse:
    """
    Transcribe un archivo de audio y genera su resumen en un solo paso.

    - **audio**: archivo de audio (.wav, .mp3, .flac, .mp4, etc.)
    """
    tmp_path = await _save_upload(audio)
    try:
        transcript = app.state.transcriber.transcribe(tmp_path)
    except TranscriptionError as e:
        raise HTTPException(status_code=422, detail=str(e)) from e
    finally:
        tmp_path.unlink(missing_ok=True)

    if not transcript:
        return ProcessResponse(transcript="", summary="")

    # Liberar Whisper antes de cargar mT5: ambos juntos no caben en 4 GiB.
    # El próximo /transcribe recargará Whisper desde EFS (~segundos).
    app.state.transcriber.unload()

    try:
        summary = app.state.summarizer.summarize(transcript)
    except SummarizationError as e:
        raise HTTPException(status_code=422, detail=str(e)) from e

    return ProcessResponse(transcript=transcript, summary=summary)
