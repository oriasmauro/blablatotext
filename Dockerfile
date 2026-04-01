# ── Stage 1: builder ─────────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /app

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

COPY pyproject.toml .
COPY uv.lock .
COPY README.md .
COPY src/ src/

# CPU-only torch (via pytorch-cpu index en pyproject.toml)
RUN uv sync --no-dev --frozen

# Limpiar el venv: eliminar todo lo que no se ejecuta en runtime
RUN find /app/.venv -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true \
 && find /app/.venv -type f -name "*.pyc" -delete \
 && find /app/.venv -type f -name "*.pyi" -delete \
 && rm -rf /app/.venv/lib/python3.11/site-packages/torch/test \
 && rm -rf /app/.venv/lib/python3.11/site-packages/torch/testing \
 && rm -rf /app/.venv/lib/python3.11/site-packages/torch/ao/ns


# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/src /app/src

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    # Silenciar warnings de tokenizers paralelos (no aplica en uvicorn single-worker)
    TOKENIZERS_PARALLELISM=false

EXPOSE 8000

CMD ["uvicorn", "blablatotext.api:app", "--host", "0.0.0.0", "--port", "8000"]
