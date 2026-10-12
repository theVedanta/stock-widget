from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from app.aggregator import Aggregator, AllBrokersFailed
from app.brokers.base import BrokerError
from app.history import HistoryStore
from app.schemas import BrokerHoldings, FXRates, Position, SyncStatus, utcnow


class StubBroker:
    def __init__(self, id, currency, results):
        self.id = id
        self.display_name = id.title()
        self.short_name = id.upper()
        self.currency = currency
        self._results = list(results)

    async def fetch(self):
        result = self._results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result

    async def close(self):
        pass


class StaticFX:
    async def rates(self, currencies):
        return FXRates(base="USD", rates={"INR": 88.0, "EUR": 0.9}, as_of=utcnow())


def holdings(id, currency, cash, *positions):
    return BrokerHoldings(
        id=id, display_name=id, short_name=id.upper(), currency=currency, cash=cash,
        synced_at=utcnow(), sync_status=SyncStatus.OK, positions=list(positions),
    )


def position(symbol, currency, quantity, last, previous):
    return Position(symbol=symbol, name=symbol, exchange="X", currency=currency,
                    quantity=quantity, last_price=last, previous_close=previous)


def make(brokers):
    return Aggregator(brokers, StaticFX(), HistoryStore(Path(":memory:")), cache_ttl=60, history_days=30)


async def test_failed_broker_serves_last_good_as_stale():
    good = holdings("ibkr", "USD", 100, position("VOO", "USD", 1, 500, 495))
    agg = make([StubBroker("ibkr", "USD", [good, BrokerError("down")])])

    first = await agg.summary()
    second = await agg.summary(force=True)

    assert first.brokers[0].sync_status == SyncStatus.OK
    assert second.brokers[0].sync_status == SyncStatus.STALE
    assert second.brokers[0].positions == good.positions


async def test_never_succeeded_broker_is_reported_as_error():
    agg = make([
        StubBroker("groww", "INR", [holdings("groww", "INR", 10)]),
        StubBroker("ibkr", "USD", [BrokerError("down")]),
    ])
    summary = await agg.summary()
    assert [b.sync_status for b in summary.brokers] == [SyncStatus.OK, SyncStatus.ERROR]


async def test_all_failing_raises():
    agg = make([StubBroker("ibkr", "USD", [BrokerError("down")])])
    with pytest.raises(AllBrokersFailed):
        await agg.summary()


async def test_cache_is_reused_within_ttl():
    broker = StubBroker("ibkr", "USD", [holdings("ibkr", "USD", 1)])
    agg = make([broker])
    assert await agg.summary() is await agg.summary()


def test_history_records_native_totals_and_carries_gaps_forward():
    store = HistoryStore(Path(":memory:"))
    today = datetime(2026, 10, 12, 12, tzinfo=UTC)
    store.record(today - timedelta(days=3), {"groww": 100.0})                 # before ibkr existed: skipped
    store.record(today - timedelta(days=2), {"groww": 110.0, "ibkr": 5.0})
    store.record(today - timedelta(days=1), {"ibkr": 6.0})                    # groww missing: carried
    store.record(today, {"groww": 999.0, "ibkr": 999.0})                      # today: excluded

    points = store.daily(today, 30, ["groww", "ibkr"])

    assert [p.values for p in points] == [{"groww": 110.0, "ibkr": 5.0}, {"groww": 110.0, "ibkr": 6.0}]


async def test_mixed_currency_positions_are_converted_into_broker_currency_for_history():
    eur_etf = position("VWCE", "EUR", 10, 90, 90)  # 900 EUR = 1000 USD
    agg = make([StubBroker("ibkr", "USD", [holdings("ibkr", "USD", 0, eur_etf)])])
    await agg.summary()
    rows = agg._history._db.execute("SELECT value FROM daily_values").fetchall()
    assert rows == [(pytest.approx(1000.0),)]
