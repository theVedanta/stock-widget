"""Interactive Brokers adapter over the TWS socket API (ib_async).

Needs IB Gateway (or TWS) running with the API enabled — see docker-compose.yml,
which runs IB Gateway with IBC so it logs in and restarts unattended.

  positions + IB's own mark  ->  ib.portfolio()
  previous close              ->  snapshot tickers (Ticker.close)
  cash                        ->  account value "TotalCashValue"
"""

import asyncio
import logging
import math

from ib_async import IB, Contract

from app.brokers.base import BrokerError
from app.config import Settings
from app.schemas import BrokerHoldings, Position, SyncStatus, utcnow

log = logging.getLogger(__name__)


def _valid(value: float | None) -> bool:
    return value is not None and not math.isnan(value) and value > 0


class IBKRAdapter:
    id = "ibkr"
    display_name = "Interactive Brokers"
    short_name = "IBKR"

    def __init__(self, settings: Settings, ib: IB | None = None) -> None:
        self._settings = settings
        self._ib = ib or IB()
        self._lock = asyncio.Lock()
        self.currency = "USD"  # replaced by the account's base currency once connected

    async def close(self) -> None:
        if self._ib.isConnected():
            self._ib.disconnect()

    async def _connect(self) -> str:
        s = self._settings
        if not self._ib.isConnected():
            try:
                await self._ib.connectAsync(
                    s.ibkr_host, s.ibkr_port, clientId=s.ibkr_client_id,
                    timeout=10, readonly=True, account=s.ibkr_account,
                )
            except (OSError, asyncio.TimeoutError, ConnectionError) as error:
                raise BrokerError(f"Cannot reach IB Gateway at {s.ibkr_host}:{s.ibkr_port}: {error}") from error
            self._ib.reqMarketDataType(s.ibkr_market_data_type)
            log.info("Connected to IB Gateway")

        account = s.ibkr_account or next(iter(self._ib.managedAccounts()), "")
        if not account:
            raise BrokerError("IB Gateway reported no managed accounts")
        return account

    async def fetch(self) -> BrokerHoldings:
        async with self._lock:
            account = await self._connect()
            items = [item for item in self._ib.portfolio(account) if item.position != 0]

            cash_values = [
                v for v in self._ib.accountValues(account)
                if v.tag == "TotalCashValue" and v.currency not in ("", "BASE")
            ]
            if cash_values:
                self.currency = cash_values[0].currency
            cash = float(cash_values[0].value) if cash_values else 0.0

            previous_closes = await self._previous_closes([item.contract for item in items])

            positions = []
            for item in items:
                contract = item.contract
                last = item.marketPrice if _valid(item.marketPrice) else item.averageCost
                previous = previous_closes.get(contract.conId)
                positions.append(
                    Position(
                        symbol=contract.localSymbol or contract.symbol,
                        name=contract.symbol,
                        exchange=contract.primaryExchange or contract.exchange or "SMART",
                        currency=contract.currency or self.currency,
                        quantity=item.position * float(contract.multiplier or 1),
                        last_price=last,
                        previous_close=previous if _valid(previous) else last,
                    )
                )

            return BrokerHoldings(
                id=self.id,
                display_name=self.display_name,
                short_name=self.short_name,
                currency=self.currency,
                cash=cash,
                synced_at=utcnow(),
                sync_status=SyncStatus.OK,
                positions=positions,
            )

    async def _previous_closes(self, contracts: list[Contract]) -> dict[int, float]:
        if not contracts:
            return {}
        # Portfolio contracts often carry no routing exchange; SMART + conId is unambiguous.
        routed = [Contract(conId=c.conId, exchange="SMART", currency=c.currency) for c in contracts]
        try:
            tickers = await asyncio.wait_for(self._ib.reqTickersAsync(*routed), timeout=8)
        except asyncio.TimeoutError:
            log.warning("IBKR snapshot timed out; day change will read 0")
            return {}
        return {t.contract.conId: t.close for t in tickers if t.contract and _valid(t.close)}
