import httpx
import pytest
import respx

from app.brokers.base import BrokerError
from app.brokers.groww import GrowwAdapter
from app.config import Settings

BASE = "https://api.groww.in/v1"


def ok(payload):
    return httpx.Response(200, json={"status": "SUCCESS", "payload": payload})


def settings(**overrides):
    values = {"api_token": "x" * 32, "groww_api_key": "key", "groww_totp_secret": "JBSWY3DPEHPK3PXP"}
    return Settings(**(values | overrides))


@respx.mock
async def test_fetch_builds_positions_from_holdings_quotes_and_cash():
    respx.post(f"{BASE}/token/api/access").respond(200, json={"token": "access"})
    respx.get(f"{BASE}/holdings/user").mock(return_value=ok({"holdings": [
        {"trading_symbol": "RELIANCE", "quantity": 10, "average_price": 2500},
        {"trading_symbol": "SMALLCO", "quantity": 4, "average_price": 90},
        {"trading_symbol": "SOLD", "quantity": 0, "average_price": 1},
    ]}))
    respx.get(f"{BASE}/margins/detail/user").mock(return_value=ok({"clear_cash": 1234.5}))

    def quote(request):
        params = request.url.params
        if params["trading_symbol"] == "RELIANCE" and params["exchange"] == "NSE":
            return ok({"last_price": 2950.0, "day_change": 50.0})
        if params["trading_symbol"] == "SMALLCO" and params["exchange"] == "BSE":
            return ok({"last_price": 100.0, "day_change": -2.0})
        return httpx.Response(400, json={"status": "FAILURE", "error": {"code": "GA001", "message": "not found"}})

    respx.get(f"{BASE}/live-data/quote").mock(side_effect=quote)

    holdings = await GrowwAdapter(settings()).fetch()

    assert holdings.cash == 1234.5
    assert holdings.currency == "INR"
    by_symbol = {p.symbol: p for p in holdings.positions}
    assert set(by_symbol) == {"RELIANCE", "SMALLCO"}
    assert by_symbol["RELIANCE"].previous_close == 2900.0
    assert by_symbol["SMALLCO"].exchange == "BSE"
    assert by_symbol["SMALLCO"].previous_close == 102.0
    assert respx.calls[0].request.headers["Authorization"] == "Bearer key"


@respx.mock
async def test_unpriced_holding_is_valued_at_cost():
    respx.get(f"{BASE}/holdings/user").mock(return_value=ok({"holdings": [
        {"trading_symbol": "HALTED", "quantity": 2, "average_price": 50},
    ]}))
    respx.get(f"{BASE}/margins/detail/user").mock(return_value=ok({}))
    respx.get(f"{BASE}/live-data/quote").respond(400, json={"status": "FAILURE", "error": {"message": "no"}})

    holdings = await GrowwAdapter(settings(groww_api_key=None, groww_access_token="static")).fetch()

    [position] = holdings.positions
    assert position.last_price == position.previous_close == 50


@respx.mock
async def test_expired_token_is_renewed_once():
    token = respx.post(f"{BASE}/token/api/access")
    token.side_effect = [httpx.Response(200, json={"token": "old"}), httpx.Response(200, json={"token": "new"})]

    def margins(request):
        if request.headers["Authorization"] == "Bearer old":
            return httpx.Response(401, json={"status": "FAILURE", "error": {"message": "expired"}})
        return ok({"clear_cash": 1})

    respx.get(f"{BASE}/margins/detail/user").mock(side_effect=margins)
    respx.get(f"{BASE}/holdings/user").mock(return_value=ok({"holdings": []}))

    holdings = await GrowwAdapter(settings()).fetch()
    assert holdings.cash == 1
    assert token.call_count == 2


@respx.mock
async def test_failure_envelope_raises():
    respx.post(f"{BASE}/token/api/access").respond(200, json={"token": "t"})
    respx.get(f"{BASE}/holdings/user").respond(200, json={"status": "FAILURE", "error": {"message": "boom"}})
    respx.get(f"{BASE}/margins/detail/user").mock(return_value=ok({}))

    with pytest.raises(BrokerError, match="boom"):
        await GrowwAdapter(settings()).fetch()
