from transformers import pipeline as hf_pipeline

from blablatotext.config import settings


class SummarizationError(Exception):
    """Error especifico del proceso de resumen."""


class Summarizer:
    """
    Wrapper sobre el pipeline de BART para resumen abstractivo.

    Usa lazy-loading: el modelo se carga solo cuando se llama
    a `summarize()` por primera vez, evitando descargas en tests.
    """

    def __init__(self) -> None:
        self._pipeline = None

    def _load(self) -> None:
        if self._pipeline is None:
            self._pipeline = hf_pipeline(
                "summarization",
                model=settings.summarizer_model,
                device=settings.device,
            )

    def summarize(self, text: str) -> str:
        """
        Genera un resumen abstractivo del texto proporcionado.

        Args:
            text: Texto de entrada (idealmente mas de 50 palabras).

        Returns:
            Resumen generado por el modelo.

        Raises:
            SummarizationError: Si el texto esta vacio o el modelo falla.
        """
        if not text.strip():
            raise SummarizationError("Cannot summarize empty text.")

        self._load()
        result = self._pipeline(  # type: ignore[misc]
            text,
            max_length=settings.max_summary_length,
            min_length=settings.min_summary_length,
            do_sample=False,
        )
        return result[0].get("summary_text", "")
