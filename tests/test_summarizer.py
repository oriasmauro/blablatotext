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
