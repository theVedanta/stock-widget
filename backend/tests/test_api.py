from fastapi.testclient import TestClient

from app.aggregator import AllBrokersFailed
from app.main import app
from app.schemas import FXRates, PortfolioSummary, utcnow

TOKEN = "test-token-0123456789abcdefghij"


class FakeAggregator:
    def __init__(self, result):
        self.result = result

    async def summary(self, force=False):
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def client_with(result):
    client = TestClient(app)  # no context manager: skip lifespan (no real brokers)
    app.state.aggregator = FakeAggregator(result)
    return client


def test_requires_bearer_token():
    client = client_with(None)
    assert client.get("/v1/portfolio").status_code == 401
    assert client.get("/v1/portfolio", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_serialises_camel_case_contract():
    summary = PortfolioSummary(as_of=utcnow(), fx=FXRates(base="USD", rates={"INR": 88}, as_of=utcnow()), brokers=[], history=[])
    response = client_with(summary).get("/v1/portfolio", headers={"Authorization": f"Bearer {TOKEN}"})
    assert response.status_code == 200
    body = response.json()
    assert body["schemaVersion"] == 1
    assert body["asOf"].endswith("Z")
    assert body["fx"] == {"base": "USD", "rates": {"INR": 88.0}, "asOf": body["fx"]["asOf"]}
    assert response.headers["cache-control"] == "no-store"


def test_all_brokers_down_is_503():
    response = client_with(AllBrokersFailed("x")).get("/v1/portfolio", headers={"Authorization": f"Bearer {TOKEN}"})
    assert response.status_code == 503
