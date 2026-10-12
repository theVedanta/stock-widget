import logging
import time

import httpx

from app.schemas import FXRates, utcnow

log = logging.getLogger(__name__)


class FXProvider:
    """USD-based spot rates from Frankfurter (ECB reference rates, refreshed daily).

    Rates are cached for an hour; if the provider is down, the last good rates are reused.
    """

    base = "USD"
    max_age_seconds = 3600

    def __init__(self, url: str, client: httpx.AsyncClient | None = None) -> None:
        self._url = url
        self._client = client or httpx.AsyncClient(timeout=httpx.Timeout(8.0))
        self._cached: FXRates | None = None
        self._fetched_at = 0.0

    async def close(self) -> None:
        await self._client.aclose()

    async def rates(self, currencies: set[str]) -> FXRates:
        wanted = sorted(currencies - {self.base})
        cached = self._cached
        fresh = time.monotonic() - self._fetched_at < self.max_age_seconds
        if cached and fresh and all(c in cached.rates for c in wanted):
            return cached
        if not wanted:
            return FXRates(base=self.base, rates={}, as_of=utcnow())

        try:
            response = await self._client.get(self._url, params={"base": self.base, "symbols": ",".join(wanted)})
            response.raise_for_status()
            body = response.json()
            rates = {code: float(rate) for code, rate in body["rates"].items()}
        except (httpx.HTTPError, KeyError, ValueError) as error:
            if cached:
                log.warning("FX refresh failed, reusing rates from %s: %s", cached.as_of, error)
                return cached
            raise

        self._cached = FXRates(base=self.base, rates=rates, as_of=utcnow())
        self._fetched_at = time.monotonic()
        return self._cached
