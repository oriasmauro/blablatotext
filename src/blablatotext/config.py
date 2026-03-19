from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """
    Configuracion de la aplicacion.

    Todos los valores pueden sobreescribirse mediante variables de entorno
    con el prefijo BLABLATOTEXT_ o mediante un archivo .env.

    Ejemplo:
        BLABLATOTEXT_ASR_MODEL=openai/whisper-medium
        BLABLATOTEXT_DEVICE=cuda
    """

    model_config = SettingsConfigDict(
        env_prefix="BLABLATOTEXT_",
        env_file=".env",
        env_file_encoding="utf-8",
    )

    asr_model: str = "openai/whisper-small"
    summarizer_model: str = "pszemraj/led-large-book-summary"
    device: str = "cpu"
    asr_language: str = "es"
    max_summary_length: int = 512
    min_summary_length: int = 32


# Singleton — importar desde aqui en toda la app
settings = Settings()
