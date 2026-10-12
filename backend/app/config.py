from functools import lru_cache
from pathlib import Path

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """All configuration comes from environment variables (or a .env file)."""

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Bearer token the iOS app sends. Generate with: python -c "import secrets; print(secrets.token_urlsafe(32))"
    api_token: SecretStr = Field(min_length=24)

    # Groww Trade API. Provide ONE of:
    #   GROWW_ACCESS_TOKEN                     (expires daily at 06:00 IST; manual)
    #   GROWW_API_KEY + GROWW_TOTP_SECRET      (fully automatic daily renewal)
    #   GROWW_API_KEY + GROWW_API_SECRET       (approval flow; approve the key daily on groww.in)
    groww_access_token: SecretStr | None = None
    groww_api_key: SecretStr | None = None
    groww_totp_secret: SecretStr | None = None
    groww_api_secret: SecretStr | None = None
    groww_base_url: str = "https://api.groww.in/v1"
    groww_quote_concurrency: int = 5

    # Interactive Brokers via IB Gateway / TWS (socket API). Port 4001 = Gateway live, 4002 = paper.
    ibkr_enabled: bool = False
    ibkr_host: str = "127.0.0.1"
    ibkr_port: int = 4001
    ibkr_client_id: int = 17
    ibkr_account: str = ""  # blank = the gateway's first managed account
    # 1 live, 2 frozen, 3 delayed, 4 delayed-frozen. Live data is still used when you have a subscription.
    ibkr_market_data_type: int = 4

    # USD-based spot rates. Frankfurter (ECB reference rates) needs no key.
    fx_url: str = "https://api.frankfurter.dev/v1/latest"

    cache_ttl_seconds: float = 60
    refresh_seconds: float = 300
    history_days: int = 30
    database_path: Path = Path("data/portfolio.db")

    @property
    def groww_enabled(self) -> bool:
        return bool(self.groww_access_token or self.groww_api_key)


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
