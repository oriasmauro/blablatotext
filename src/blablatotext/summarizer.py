from transformers import pipeline as hf_pipeline

from blablatotext.config import settings

# mT5-base tiene un contexto de ~512 tokens.
# Con texto en español (~1.3-1.5 tokens/palabra), 200 palabras ≈ 300 tokens,
# lo que deja margen para el decodificador sin llegar al límite.
_CHUNK_MAX_WORDS = 200


class SummarizationError(Exception):
    """Error especifico del proceso de resumen."""


class Summarizer:
    """
    Wrapper sobre el pipeline de mT5 para resumen abstractivo en español.

    Usa lazy-loading: el modelo se carga solo cuando se llama
    a `summarize()` por primera vez, evitando descargas en tests.

    Para transcripciones largas que exceden el contexto del modelo (~512 tokens),
    el texto se divide en chunks de hasta 200 palabras, se resume cada uno
    por separado y los resumenes parciales se concatenan.
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

    @staticmethod
    def _chunk_text(text: str) -> list[str]:
        """Divide el texto en chunks de hasta _CHUNK_MAX_WORDS palabras."""
        words = text.split()
        return [
            " ".join(words[i : i + _CHUNK_MAX_WORDS])
            for i in range(0, len(words), _CHUNK_MAX_WORDS)
            if words[i : i + _CHUNK_MAX_WORDS]
        ]

    def summarize(self, text: str) -> str:
        """
        Genera un resumen abstractivo del texto en español.

        Si el texto supera el contexto del modelo, se procesa por chunks
        y los resumenes parciales se concatenan en el resultado final.

        Args:
            text: Texto de entrada en español.

        Returns:
            Resumen generado por el modelo. Puede ser la concatenacion de
            resumenes parciales para textos largos.

        Raises:
            SummarizationError: Si el texto esta vacio o el modelo falla.
        """
        if not text.strip():
            raise SummarizationError("Cannot summarize empty text.")

        self._load()

        partial: list[str] = []
        for chunk in self._chunk_text(text):
            input_len = len(chunk.split())
            max_len = min(settings.max_summary_length, max(1, input_len - 1))
            min_len = min(settings.min_summary_length, max(1, max_len - 1))
            result = self._pipeline(  # type: ignore[misc]
                chunk,
                max_length=max_len,
                min_length=min_len,
                do_sample=False,
                truncation=True,
            )
            summary = result[0].get("summary_text", "").strip()
            if summary:
                partial.append(summary)

        return " ".join(partial)
