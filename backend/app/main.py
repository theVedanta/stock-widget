import asyncio
import contextlib
import hmac
import logging
from collections.abc import AsyncIterator
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Request, Response, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.aggregator import Aggregator, AllBrokersFailed
from app.brokers.base import BrokerAdapter
from app.brokers.groww import GrowwAdapter
from app.brokers.ibkr import IBKRAdapter
from app.config import Settings, get_settings
from app.fx import FXProvider
from app.history import HistoryStore
from app.schemas import PortfolioSummary

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("portfolio")


def build_brokers(settings: Settings) -> list[BrokerAdapter]:
    brokers: list[BrokerAdapter] = []
    if settings.groww_enabled:
        brokers.append(GrowwAdapter(settings))
    if settings.ibkr_enabled:
        brokers.append(IBKRAdapter(settings))
    if not brokers:
        raise RuntimeError("No brokers configured: set Groww credentials and/or IBKR_ENABLED=true")
    return brokers


async def _refresh_forever(aggregator: Aggregator, interval: float) -> None:
    """Keeps the cache warm (fast widget responses) and records history even when no phone is polling."""
    while True:
        try:
            await aggregator.summary(force=True)
        except AllBrokersFailed as error:
            log.warning("Background refresh: %s", error)
        except Exception:
            log.exception("Background refresh failed")
        await asyncio.sleep(interval)


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    brokers = build_brokers(settings)
    fx = FXProvider(settings.fx_url)
    history = HistoryStore(settings.database_path)
    app.state.aggregator = Aggregator(
        brokers, fx, history, cache_ttl=settings.cache_ttl_seconds, history_days=settings.history_days
    )
    refresher = asyncio.create_task(_refresh_forever(app.state.aggregator, settings.refresh_seconds))
    try:
        yield
    finally:
        refresher.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await refresher
        for broker in brokers:
            await broker.close()
        await fx.close()
        history.close()


app = FastAPI(title="Portfolio Aggregator", version="1.0.0", lifespan=lifespan, docs_url=None, redoc_url=None)
bearer = HTTPBearer(auto_error=False)


def require_token(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> None:
    expected = settings.api_token.get_secret_value().encode()
    supplied = credentials.credentials.encode() if credentials else b""
    if not hmac.compare_digest(supplied, expected):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token", headers={"WWW-Authenticate": "Bearer"})


@app.get("/healthz", include_in_schema=False)
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get(
    "/v1/portfolio",
    response_model=PortfolioSummary,
    response_model_by_alias=True,
    dependencies=[Depends(require_token)],
)
async def portfolio(request: Request, response: Response) -> PortfolioSummary:
    response.headers["Cache-Control"] = "no-store"
    try:
        return await request.app.state.aggregator.summary()
    except AllBrokersFailed as error:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(error)) from error
