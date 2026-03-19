from unittest.mock import patch

from typer.testing import CliRunner

from blablatotext.main import app
from tests.conftest import MOCK_SUMMARY, MOCK_TRANSCRIPT

runner = CliRunner()


def test_run_happy_path(audio_file):
    with (
        patch("blablatotext.main.Transcriber") as MockT,
        patch("blablatotext.main.Summarizer") as MockS,
    ):
        MockT.return_value.transcribe.return_value = MOCK_TRANSCRIPT
        MockS.return_value.summarize.return_value = MOCK_SUMMARY

        result = runner.invoke(app, [str(audio_file)])

        assert result.exit_code == 0
        # Rich wraps texto en Panel — verificamos palabras clave
        assert "tokenizacion" in result.output
        assert "tokens" in result.output
        assert "divide" in result.output


def test_run_no_summary_flag(audio_file):
    with patch("blablatotext.main.Transcriber") as MockT:
        MockT.return_value.transcribe.return_value = MOCK_TRANSCRIPT

        result = runner.invoke(app, [str(audio_file), "--no-summary"])

        assert result.exit_code == 0
        assert MOCK_SUMMARY not in result.output


def test_run_output_file(audio_file, tmp_path):
    out = tmp_path / "resultado.txt"
    with (
        patch("blablatotext.main.Transcriber") as MockT,
        patch("blablatotext.main.Summarizer") as MockS,
    ):
        MockT.return_value.transcribe.return_value = MOCK_TRANSCRIPT
        MockS.return_value.summarize.return_value = MOCK_SUMMARY

        runner.invoke(app, [str(audio_file), "--output", str(out)])

        assert out.exists()
        content = out.read_text()
        assert "TRANSCRIPCION" in content
        assert "RESUMEN" in content


def test_run_transcription_error(audio_file):
    from blablatotext.transcriber import TranscriptionError

    with patch("blablatotext.main.Transcriber") as MockT:
        MockT.return_value.transcribe.side_effect = TranscriptionError("fallo")

        result = runner.invoke(app, [str(audio_file)])

        assert result.exit_code == 1
        assert "Error de transcripcion" in result.output


def test_run_file_not_found():
    result = runner.invoke(app, ["/archivo/que/no/existe.wav"])
    assert result.exit_code != 0
