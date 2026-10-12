"""Response contract for GET /v1/portfolio.

Mirrors the Swift models in Shared/Models/Portfolio.swift. The backend sends raw
facts only (quantity, price, previous close, cash, FX); the app derives totals
and P&L so the numbers always reconcile.
"""

from datetime import UTC, datetime
from enum import StrEnum

from pydantic import BaseModel, ConfigDict
from pydantic.alias_generators import to_camel

SCHEMA_VERSION = 1


def utcnow() -> datetime:
    # Whole seconds keep timestamps trivially parseable by ISO8601FormatStyle on iOS.
    return datetime.now(UTC).replace(microsecond=0)


class CamelModel(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)


class SyncStatus(StrEnum):
    OK = "ok"
    STALE = "stale"
    ERROR = "error"


class Position(CamelModel):
    symbol: str
    name: str
    exchange: str
    currency: str
    quantity: float
    last_price: float
    previous_close: float

    @property
    def market_value(self) -> float:
        return self.quantity * self.last_price


class BrokerHoldings(CamelModel):
    id: str
    display_name: str
    short_name: str
    currency: str
    cash: float
    synced_at: datetime
    sync_status: SyncStatus
    positions: list[Position]


class FXRates(CamelModel):
    base: str
    rates: dict[str, float]
    as_of: datetime

    def convert(self, amount: float, source: str, target: str) -> float | None:
        if source == target:
            return amount
        from_rate = 1.0 if source == self.base else self.rates.get(source)
        to_rate = 1.0 if target == self.base else self.rates.get(target)
        if not from_rate or to_rate is None:
            return None
        return amount / from_rate * to_rate


class HistoryPoint(CamelModel):
    timestamp: datetime
    values: dict[str, float]


class PortfolioSummary(CamelModel):
    schema_version: int = SCHEMA_VERSION
    as_of: datetime
    fx: FXRates
    brokers: list[BrokerHoldings]
    history: list[HistoryPoint]


def broker_total(broker: BrokerHoldings, fx: FXRates) -> float | None:
    """Cash + positions in the broker's own currency (positions may be in other currencies)."""
    total = broker.cash
    for position in broker.positions:
        value = fx.convert(position.market_value, position.currency, broker.currency)
        if value is None:
            return None
        total += value
    return total
