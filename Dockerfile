# ── Stage 1: builder ─────────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /app

# Instalar uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Copiar archivos de dependencias primero (mejor cache de capas)
COPY pyproject.toml .
COPY uv.lock .
COPY README.md .
COPY src/ src/

# Instalar dependencias de produccion en un venv dentro del proyecto
RUN uv sync --no-dev --frozen


# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

# ffmpeg es necesario para decodificar formatos de audio via transcriber
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copiar el venv y el codigo fuente desde el builder
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/src /app/src
COPY --from=builder /app/pyproject.toml /app/pyproject.toml

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

EXPOSE 8000

CMD ["uvicorn", "blablatotext.api:app", "--host", "0.0.0.0", "--port", "8000"]
