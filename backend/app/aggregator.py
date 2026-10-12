import asyncio
import logging
import time

from app.brokers.base import BrokerAdapter
from app.fx import FXProvider
from app.history import HistoryStore
from app.schemas import BrokerHoldings, PortfolioSummary, SyncStatus, broker_total, utcnow

log = logging.getLogger(__name__)


class AllBrokersFailed(Exception):
    pass


class Aggregator:
    """Fetches every broker concurrently, merges them with FX + history, and caches the result.

    A broker that fails keeps serving its last good holdings marked `stale`; one that has
    never succeeded is reported as `error` with no holdings, so the app can flag it
    instead of silently showing a smaller total.
    """

    def __init__(
        self,
        brokers: list[BrokerAdapter],
        fx: FXProvider,
        history: HistoryStore,
        *,
        cache_ttl: float,
        history_days: int,
        broker_timeout: float = 25,
    ) -> None:
        self._brokers = brokers
        self._fx = fx
        self._history = history
        self._cache_ttl = cache_ttl
        self._history_days = history_days
        self._broker_timeout = broker_timeout
        self._lock = asyncio.Lock()
        self._summary: PortfolioSummary | None = None
        self._summary_at = 0.0
        self._last_good: dict[str, BrokerHoldings] = {}

    async def summary(self, *, force: bool = False) -> PortfolioSummary:
        async with self._lock:
            if not force and self._summary and time.monotonic() - self._summary_at < self._cache_ttl:
                return self._summary
            self._summary = await self._refresh()
            self._summary_at = time.monotonic()
            return self._summary

    async def _refresh(self) -> PortfolioSummary:
        results = await asyncio.gather(
            *(asyncio.wait_for(b.fetch(), self._broker_timeout) for b in self._brokers),
            return_exceptions=True,
        )

        holdings: list[BrokerHoldings] = []
        for broker, result in zip(self._brokers, results):
            if isinstance(result, BrokerHoldings):
                self._last_good[broker.id] = result
                holdings.append(result)
                continue
            log.warning("%s fetch failed: %r", broker.id, result)
            if previous := self._last_good.get(broker.id):
                holdings.append(previous.model_copy(update={"sync_status": SyncStatus.STALE}))
            else:
                holdings.append(
                    BrokerHoldings(
                        id=broker.id, display_name=broker.display_name, short_name=broker.short_name,
                        currency=broker.currency, cash=0, synced_at=utcnow(),
                        sync_status=SyncStatus.ERROR, positions=[],
                    )
                )

        if all(h.sync_status == SyncStatus.ERROR for h in holdings):
            raise AllBrokersFailed("No broker returned data")

        currencies = {h.currency for h in holdings} | {p.currency for h in holdings for p in h.positions}
        fx = await self._fx.rates(currencies)

        now = utcnow()
        fresh_totals = {
            h.id: total
            for h in holdings
            if h.sync_status == SyncStatus.OK and (total := broker_total(h, fx)) is not None
        }
        self._history.record(now, fresh_totals)

        return PortfolioSummary(
            as_of=now,
            fx=fx,
            brokers=holdings,
            history=self._history.daily(now, self._history_days, [h.id for h in holdings]),
        )
