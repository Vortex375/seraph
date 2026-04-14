from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_host: str = "0.0.0.0"
    app_port: int = 8000
    runtime_env: str = "prd"
    ui_dev_server_url: str | None = None

    openai_api_key: str | None = None
    openai_base_url: str | None = None
    chat_model_name: str = "gpt-5.2"
    embedding_model_name: str = "text-embedding-3-small"
    embedding_dimensions: int = 1536

    db_host: str = "localhost"
    db_port: int = 5432
    db_user: str = "ai"
    db_pass: str = "ai"
    db_database: str = "ai"

    nats_url: str = "nats://localhost:4222"
    kb_ingest_enabled: bool = True
    kb_max_file_bytes: int = 20 * 1024 * 1024
    kb_pull_batch: int = 20
    kb_fetch_timeout: float = 10.0
    kb_ack_wait_seconds: float = 30.0
    kb_consumer_name: str = "seraph-agents-kb"
    kb_ingest_parallelism: int = 4
    kb_idle_backoff_base: float = 0.5
    kb_idle_backoff_max: float = 5.0

    seraph_auth_enabled: bool = True
    seraph_auth_user_header: str = "X-Seraph-User"


@lru_cache
def get_settings() -> Settings:
    return Settings()
