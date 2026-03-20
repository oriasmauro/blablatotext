from pathlib import Path

import typer
from rich.console import Console
from rich.panel import Panel

from blablatotext.summarizer import SummarizationError, Summarizer
from blablatotext.transcriber import Transcriber, TranscriptionError

app = typer.Typer(
    name="blablatotext",
    help="Transcribe y resume archivos de audio usando Whisper y BART.",
    add_completion=False,
)
console = Console()


@app.command()
def run(
    audio: Path = typer.Argument(
        ...,
        exists=True,
        file_okay=True,
        dir_okay=False,
        readable=True,
        help="Ruta al archivo de audio (.wav, .mp3, .flac)",
    ),
    no_summary: bool = typer.Option(
        False,
        "--no-summary",
        help="Solo transcribir, sin generar resumen.",
    ),
    output: Path | None = typer.Option(
        None,
        "--output",
        "-o",
        help="Guardar resultado en un archivo .txt",
    ),
) -> None:
    """
    Transcribe AUDIO al español y opcionalmente genera un resumen.
    """
    transcriber = Transcriber()
    summarizer = Summarizer()

    try:
        with console.status("[bold green]Cargando modelo ASR y transcribiendo..."):
            transcript = transcriber.transcribe(audio)
    except TranscriptionError as e:
        console.print(f"[bold red]Error de transcripcion:[/] {e}")
        raise typer.Exit(code=1) from e

    console.print(
        Panel(transcript or "(vacio)", title="Transcripcion", border_style="cyan")
    )

    if not transcript:
        console.print(
            "[yellow]Advertencia:[/] Transcripcion vacia. Verifica el archivo de audio."
        )
        raise typer.Exit(code=0)

    if no_summary:
        _save_if_requested(output, transcript)
        return

    try:
        with console.status("[bold green]Generando resumen..."):
            summary = summarizer.summarize(transcript)
    except SummarizationError as e:
        console.print(f"[bold red]Error de resumen:[/] {e}")
        raise typer.Exit(code=1) from e

    console.print(Panel(summary, title="Resumen", border_style="green"))
    _save_if_requested(output, f"TRANSCRIPCION:\n{transcript}\n\nRESUMEN:\n{summary}")


def _save_if_requested(path: Path | None, content: str) -> None:
    if path is not None:
        path.write_text(content, encoding="utf-8")
        console.print(f"[dim]Resultado guardado en:[/] {path}")


def main() -> None:
    app()


if __name__ == "__main__":
    main()
