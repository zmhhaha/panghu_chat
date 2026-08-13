from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = "hublog"
    app_version: str = "0.1.0"
    environment: str = "development"
    database_url: str = Field(
        "postgresql+asyncpg://postgres:postgres@localhost:5432/hublog",
        validation_alias="DATABASE_URL",
    )
    redis_url: str = Field("redis://localhost:6379/0", validation_alias="REDIS_URL")
    redis_stream: str = "hublog.events"
    auto_create_schema: bool = Field(False, validation_alias="AUTO_CREATE_SCHEMA")
    allow_dev_auth: bool = Field(False, validation_alias="ALLOW_DEV_AUTH")
    feed_max_limit: int = 50
    outbox_batch_size: int = 50
    outbox_poll_seconds: float = 2.0


@lru_cache
def get_settings() -> Settings:
    return Settings()
