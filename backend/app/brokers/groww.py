"""Groww Trade API adapter (https://groww.in/trade-api/docs).

Endpoints used (all GET, base https://api.groww.in/v1, `{"status", "payload"}` envelope):
  /holdings/user          demat holdings: trading_symbol, quantity, average_price, isin
  /live-data/quote        per-symbol quote: last_price, day_change, ohlc
  /margins/detail/user    clear_cash
Auth: daily access token from POST /token/api/access (TOTP or API-secret checksum flow).
"""

import asyncio
import hashlib
import logging
import time
import uuid
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import httpx
import pyotp

from app.brokers.base import BrokerError
from app.config import Settings
from app.schemas import BrokerHoldings, Position, SyncStatus, utcnow

log = logging.getLogger(__name__)
IST = ZoneInfo("Asia/Kolkata")


def _headers(token: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-API-VERSION": "1.0",
        "x-request-id": str(uuid.uuid4()),
    }


def _next_token_expiry(now: datetime) -> datetime:
    """Groww access tokens expire at 06:00 IST every day."""
    local = now.astimezone(IST)
    expiry = local.replace(hour=6, minute=0, second=0, microsecond=0)
    if local >= expiry:
        expiry += timedelta(days=1)
    return expiry


class GrowwTokenProvider:
    def __init__(self, settings: Settings, client: httpx.AsyncClient) -> None:
        self._settings = settings
        self._client = client
        self._token: str | None = None
        self._expires_at: datetime | None = None
        self._lock = asyncio.Lock()

    async def token(self) -> str:
        async with self._lock:
            if self._token and self._expires_at and utcnow() < self._expires_at:
                return self._token
            self._token = await self._obtain()
            self._expires_at = _next_token_expiry(utcnow())
            return self._token

    def invalidate(self) -> None:
        self._token = None

    async def _obtain(self) -> str:
        s = self._settings
        if s.groww_access_token and not s.groww_api_key:
            return s.groww_access_token.get_secret_value()
        if not s.groww_api_key:
            raise BrokerError("Groww credentials are not configured")

        if s.groww_totp_secret:
            body: dict[str, object] = {
                "key_type": "totp",
                "totp": pyotp.TOTP(s.groww_totp_secret.get_secret_value()).now(),
            }
        elif s.groww_api_secret:
            timestamp = str(int(time.time()))
            checksum = hashlib.sha256((s.groww_api_secret.get_secret_value() + timestamp).encode()).hexdigest()
            body = {"key_type": "approval", "checksum": checksum, "timestamp": int(timestamp)}
        else:
            raise BrokerError("Set GROWW_TOTP_SECRET or GROWW_API_SECRET alongside GROWW_API_KEY")

        response = await self._client.post(
            f"{s.groww_base_url}/token/api/access",
            headers=_headers(s.groww_api_key.get_secret_value()),
            json=body,
        )
        if response.status_code != 200:
            raise BrokerError(f"Groww token request failed ({response.status_code}): {response.text[:200]}")
        token = response.json().get("token")
        if not token:
            raise BrokerError("Groww token response had no token")
        log.info("Obtained new Groww access token")
        return token


class GrowwAdapter:
    id = "groww"
    display_name = "Groww"
    short_name = "GROWW"
    currency = "INR"

    def __init__(self, settings: Settings, client: httpx.AsyncClient | None = None) -> None:
        self._settings = settings
        self._client = client or httpx.AsyncClient(timeout=httpx.Timeout(10.0))
        self._tokens = GrowwTokenProvider(settings, self._client)
        self._quote_slots = asyncio.Semaphore(settings.groww_quote_concurrency)

    async def close(self) -> None:
        await self._client.aclose()

    async def fetch(self) -> BrokerHoldings:
        holdings_payload, margins_payload = await asyncio.gather(
            self._get("/holdings/user"),
            self._get("/margins/detail/user"),
        )
        holdings = [h for h in holdings_payload.get("holdings") or [] if float(h.get("quantity") or 0) > 0]
        positions = await asyncio.gather(*(self._position(h) for h in holdings))

        return BrokerHoldings(
            id=self.id,
            display_name=self.display_name,
            short_name=self.short_name,
            currency=self.currency,
            cash=float(margins_payload.get("clear_cash") or 0),
            synced_at=utcnow(),
            sync_status=SyncStatus.OK,
            positions=list(positions),
        )

    async def _position(self, holding: dict) -> Position:
        symbol = holding["trading_symbol"]
        quantity = float(holding["quantity"])
        quote, exchange = await self._quote(symbol)

        if quote is None:
            # No live price (suspended / delisted): value at cost so the total isn't understated to zero.
            price = float(holding.get("average_price") or 0)
            return Position(
                symbol=symbol, name=symbol, exchange="NSE", currency=self.currency,
                quantity=quantity, last_price=price, previous_close=price,
            )

        last = float(quote["last_price"])
        day_change = quote.get("day_change")
        previous_close = last - float(day_change) if day_change is not None else float(
            (quote.get("ohlc") or {}).get("close") or last
        )
        return Position(
            symbol=symbol, name=symbol, exchange=exchange, currency=self.currency,
            quantity=quantity, last_price=last, previous_close=previous_close,
        )

    async def _quote(self, symbol: str) -> tuple[dict | None, str]:
        """Holdings don't say which exchange; try NSE first, then BSE."""
        for exchange in ("NSE", "BSE"):
            try:
                async with self._quote_slots:
                    payload = await self._get(
                        "/live-data/quote",
                        params={"exchange": exchange, "segment": "CASH", "trading_symbol": symbol},
                    )
                if payload.get("last_price") is not None:
                    return payload, exchange
            except BrokerError as error:
                log.debug("No %s quote for %s: %s", exchange, symbol, error)
        log.warning("No Groww quote for %s on NSE or BSE", symbol)
        return None, "NSE"

    async def _get(self, path: str, params: dict | None = None, *, retry_auth: bool = True) -> dict:
        token = await self._tokens.token()
        try:
            response = await self._client.get(
                f"{self._settings.groww_base_url}{path}", headers=_headers(token), params=params
            )
        except httpx.HTTPError as error:
            raise BrokerError(f"Groww request to {path} failed: {error}") from error

        if response.status_code in (401, 403) and retry_auth:
            self._tokens.invalidate()
            return await self._get(path, params, retry_auth=False)

        try:
            body = response.json()
        except ValueError as error:
            raise BrokerError(f"Groww {path} returned non-JSON ({response.status_code})") from error

        if body.get("status") == "FAILURE" or response.status_code >= 400:
            error = body.get("error") or {}
            raise BrokerError(f"Groww {path} failed ({response.status_code}): {error.get('message') or error}")
        return body.get("payload", body)
