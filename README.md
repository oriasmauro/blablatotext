# blablatotext

> **Proof of Concept** — Herramienta orientada a periodistas y community managers que reciben audios en español y necesitan transcripciones precisas y resumenes listos para usar, sin intervención manual.

Herramienta de linea de comandos para **transcribir audio al español** y generar **resumenes automaticos** usando modelos de Hugging Face (Whisper + LED).

Soporta cualquier formato de audio/video compatible con ffmpeg: `.wav`, `.mp3`, `.flac`, `.mp4`, `.mkv`, etc.

### Casos de uso

- Periodista recibe una nota de voz o grabacion de entrevista y necesita un resumen rapido antes de redactar.
- Community manager recibe audios de WhatsApp y necesita el contenido en texto para responder o publicar.
- Cualquier flujo donde convertir voz a texto estructurado ahorra tiempo de escucha y edicion.

### Calidad garantizada

| Componente | Modelo | Por que |
|---|---|---|
| Transcripcion | `openai/whisper-small` | Whisper es el estado del arte en ASR multilingue, entrenado especificamente en español con alta precision en acentos y ruido de fondo |
| Resumen | `pszemraj/led-large-book-summary` | LED (Longformer Encoder-Decoder) maneja hasta 16 384 tokens, evitando el truncado que degrada la calidad en audios largos |

Ambos modelos son de codigo abierto, corren localmente y no envian datos a servicios externos.

## Requisitos

- Python 3.11+ (< 3.13 en macOS x86_64 por limitaciones de PyTorch)
- [uv](https://docs.astral.sh/uv/) >= 0.5
- [ffmpeg](https://ffmpeg.org/) instalado en el sistema

```bash
# macOS
brew install ffmpeg
```

## Instalacion

```bash
git clone https://github.com/tu-usuario/blablatotext.git
cd blablatotext
uv sync
```

La primera ejecucion descargara los modelos automaticamente (~1.6 GB para LED, ~460 MB para Whisper small).

## Uso

```bash
# Transcribir y resumir
uv run blablatotext audios/mi_audio.mp4

# Solo transcribir (sin resumen)
uv run blablatotext audios/mi_audio.wav --no-summary

# Guardar resultado en archivo
uv run blablatotext audios/mi_audio.mp3 --output resultado.txt

# Ver ayuda
uv run blablatotext --help
```

## Variables de entorno

Todos los parametros pueden sobreescribirse sin modificar codigo, usando variables de entorno o un archivo `.env`:

| Variable                          | Default                            | Descripcion                      |
|-----------------------------------|------------------------------------|----------------------------------|
| `BLABLATOTEXT_ASR_MODEL`          | `openai/whisper-small`             | Modelo de transcripcion Whisper  |
| `BLABLATOTEXT_SUMMARIZER_MODEL`   | `pszemraj/led-large-book-summary`  | Modelo de resumen (LED)          |
| `BLABLATOTEXT_DEVICE`             | `cpu`                              | Dispositivo (`cpu` o `cuda`)     |
| `BLABLATOTEXT_ASR_LANGUAGE`       | `es`                               | Idioma de transcripcion          |
| `BLABLATOTEXT_MAX_SUMMARY_LENGTH` | `512`                              | Longitud maxima del resumen      |
| `BLABLATOTEXT_MIN_SUMMARY_LENGTH` | `32`                               | Longitud minima del resumen      |

Ejemplo con modelo mas potente:

```bash
BLABLATOTEXT_ASR_MODEL=openai/whisper-large-v3 uv run blablatotext audio.mp4
```

## Notas de compatibilidad

- **macOS Intel (x86_64):** PyTorch no tiene wheels >= 2.4 para esta plataforma. El proyecto usa torch 2.2.x con `transformers<4.47.0`.
- **Audios largos (> 30 segundos):** soportados de forma nativa gracias a `return_timestamps=True` en Whisper y al contexto extendido de LED (hasta 16 384 tokens).

## Desarrollo

```bash
# Instalar dependencias incluyendo las de desarrollo
uv sync --group dev

# Ejecutar tests con cobertura
uv run pytest

# Linting
uv run ruff check src tests

# Formateo
uv run ruff format src tests
```

## Arquitectura

```
src/blablatotext/
├── config.py       # Configuracion centralizada via pydantic-settings
├── transcriber.py  # Wrapper ASR con Whisper (lazy-loading, decodifica via ffmpeg)
├── summarizer.py   # Wrapper de resumen con LED (lazy-loading)
└── main.py         # CLI construido con Typer + Rich
```

Los modelos usan **lazy-loading**: se descargan solo cuando se ejecuta la primera inferencia, no al importar el modulo. Esto permite tests rapidos sin GPU ni conexion a internet.

## Licencia

MIT
