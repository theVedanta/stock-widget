from typing import Protocol

from app.schemas import BrokerHoldings


class BrokerError(Exception):
    """A broker could not be read (auth, network, unexpected payload)."""


class BrokerAdapter(Protocol):
    id: str
    display_name: str
    short_name: str
    currency: str

    async def fetch(self) -> BrokerHoldings: ...

    async def close(self) -> None: ...
