import pytest

from blablatotext.summarizer import SummarizationError, Summarizer
from tests.conftest import MOCK_SUMMARY


def test_summarize_returns_text(mock_summarizer):
    result = mock_summarizer.summarize(
        "Texto de prueba suficientemente largo para el modelo de resumen."
    )
    assert result == MOCK_SUMMARY


def test_summarize_empty_text_raises_error(mock_summarizer):
    with pytest.raises(SummarizationError, match="empty"):
        mock_summarizer.summarize("")


def test_summarize_whitespace_only_raises_error(mock_summarizer):
    with pytest.raises(SummarizationError):
        mock_summarizer.summarize("   \n  ")


def test_lazy_load_not_called_before_summarize():
    """El modelo no debe cargarse al instanciar la clase."""
    summarizer = Summarizer()
    assert summarizer._pipeline is None


def test_summarize_long_text_uses_chunking(mock_summarizer):
    """Texto > 200 palabras debe dividirse en chunks y concatenar resumenes."""
    # 400 palabras → 2 chunks de 200 palabras exactos
    long_text = " ".join(["palabra"] * 400)
    result = mock_summarizer.summarize(long_text)

    # El pipeline debe haberse llamado una vez por chunk
    assert mock_summarizer._pipeline.call_count == 2
    # El resultado es la concatenacion de ambos resumenes parciales
    assert result == f"{MOCK_SUMMARY} {MOCK_SUMMARY}"


def test_summarize_short_text_single_chunk(mock_summarizer):
    """Texto corto (< 200 palabras) no debe chunkificar: una sola llamada."""
    short_text = " ".join(["palabra"] * 50)
    mock_summarizer.summarize(short_text)
    assert mock_summarizer._pipeline.call_count == 1
