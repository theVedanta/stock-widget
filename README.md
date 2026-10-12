# Stock Widget

A dark, minimal iOS home-screen widget (WidgetKit + SwiftUI, iOS 17+) that combines a **Groww** (INR) and **Interactive Brokers** (USD) portfolio into one net-worth view.

| Medium | Large |
| --- | --- |
| Net worth + today's P&L on the left; Groww / IBKR balances, allocation bar and top 2 movers on the right | Net worth, P&L badge, 30-day sparkline, broker cards, top 5 positions, market status + FX footer |

## Project layout

```
project.yml                     XcodeGen spec (app + widget extension, App Group, Keychain group)
backend/                        FastAPI aggregation server (Groww + IBKR → one JSON payload)
Shared/                         Compiled into both targets
  Models/Currency.swift         CurrencyCode, FXRates (conversion)
  Models/Portfolio.swift        PortfolioSummary, BrokerHoldings, Position, HistoryPoint (wire models)
  Models/PortfolioDisplayModel  Everything pre-computed in the chosen base currency
  Services/PortfolioDataSource  Remote REST client, errors, data-source factory
  Services/PortfolioRepository  Cache (App Group), throttling, request de-duplication
  Services/AppGroup.swift       App Group, endpoint setting, Keychain token store
  Support/MarketHours.swift     NSE / NYSE sessions + refresh policy
  Support/Formatters.swift      ₹ lakh/crore + $ K/M formatting, "Updated Xm ago"
Widget/                         Widget extension
  PortfolioWidget.swift         @main bundle, AppIntentConfiguration, family switch
  PortfolioTimelineProvider     AppIntentTimelineProvider
  PortfolioEntry.swift          TimelineEntry
  PortfolioConfigurationIntent  "Show total in ₹ / $" widget setting
  Theme.swift                   Colours + type
  Views/                        Medium, Large, shared components (badge, pills, sparkline)
App/StockWidgetApp.swift        Host app: set endpoint + token, reload widgets
```

## Backend

`backend/` is a small FastAPI service that logs into both brokers, prices every holding, and serves the payload the widget reads.

| Broker | How it connects | What it reads |
| --- | --- | --- |
| Groww | [Trade API](https://groww.in/trade-api/docs) over REST (needs the Trade API subscription) | `/holdings/user`, `/live-data/quote` per holding (last price + day change), `/margins/detail/user` (cash) |
| IBKR | IB Gateway socket API via [`ib_async`](https://github.com/ib-api-reloaded/ib_async), read-only | portfolio positions + IB's mark price, snapshot prior close, `TotalCashValue` |

FX rates come from [Frankfurter](https://frankfurter.dev) (ECB reference rates, no key). Every refresh records each broker's total in SQLite, and the last value of each day feeds the 30-day sparkline. The history starts the day you first run the backend.

**Behaviour**
- A background task refreshes every 5 minutes, so widget requests return from cache straight away and history keeps filling even when no phone is asking.
- If one broker fails, its last good holdings are served marked `stale`. If it has never succeeded, it's marked `error`, which shows the ⚠︎ on its pill. If every broker fails, the API returns `503`.
- Groww tokens expire at 06:00 IST every day. With `GROWW_API_KEY` + `GROWW_TOTP_SECRET` the backend renews them itself. A `401` triggers one re-login.
- For IBKR, `docker-compose.yml` runs [`gnzsnz/ib-gateway`](https://github.com/gnzsnz/ib-gateway-docker) with IBC, so the gateway logs in and restarts every night unattended. IBKR still asks for a 2FA approval on your phone about once a week.

**Limitations**
- Groww's Trade API only exposes demat stocks and ETFs. Mutual funds don't show up.
- Without an IBKR market-data subscription, prior closes use delayed data. That's fine for day change.

**Run it**

```sh
cd backend
cp .env.example .env          # fill in API_TOKEN, Groww key + TOTP secret, IBKR login
docker compose up -d          # API on 127.0.0.1:8000 + IB Gateway
```

Expose it over HTTPS (Caddy, Cloudflare Tunnel, Tailscale Funnel, …), then enter `https://<host>/v1/portfolio` and your `API_TOKEN` in the iOS app.

Local development and tests:

```sh
cd backend
python -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/pytest
.venv/bin/uvicorn app.main:app --reload
```

## Getting started (iOS)

```sh
brew install xcodegen
xcodegen            # generates StockWidget.xcodeproj
open StockWidget.xcodeproj
```

1. Set your team, then replace `com.example.stockwidget` / `group.com.example.stockwidget` in `project.yml` **and** `Shared/Services/AppGroup.swift`.
2. Run the app and enter your backend URL + token. Until then, the widget shows "Open the app to connect your backend."

## Backend contract

`GET /v1/portfolio` with `Authorization: Bearer <token>` → `200 application/json`. Pydantic models: [`backend/app/schemas.py`](backend/app/schemas.py); Swift models: [`Shared/Models/Portfolio.swift`](Shared/Models/Portfolio.swift).

```jsonc
{
  "schemaVersion": 1,
  "asOf": "2026-10-12T09:45:00Z",              // when prices were taken → "Updated Xm ago"
  "fx": { "base": "USD", "rates": { "INR": 88.65 }, "asOf": "…" },   // 1 USD = 88.65 INR
  "brokers": [
    {
      "id": "groww", "displayName": "Groww", "shortName": "GROWW",
      "currency": "INR", "cash": 48250.0,
      "syncedAt": "…", "syncStatus": "ok",      // ok | stale | error
      "positions": [
        { "symbol": "RELIANCE", "name": "Reliance Industries", "exchange": "NSE",
          "currency": "INR", "quantity": 120, "lastPrice": 2945.30, "previousClose": 2901.10 }
      ]
    },
    { "id": "ibkr", "currency": "USD", … }
  ],
  "history": [                                  // daily closes, native currency per broker
    { "timestamp": "2026-09-13T10:00:00Z", "values": { "groww": 1712345.12, "ibkr": 70123.45 } }
  ]
}
```

The backend sends raw facts only (quantity, price, previous close, cash, FX). The device derives market values, totals, day P&L and percentages, so the numbers always add up. A position's `currency` can differ from its broker's, for example an EUR-listed ETF in a USD IBKR account. `fx.rates` covers every currency that appears in the payload. Dates are ISO-8601, fractional seconds optional. Unknown fields are ignored. Bump `schemaVersion` for breaking changes; the widget shows "Update the app" when it sees a version it doesn't know.

The backend holds the broker credentials (Groww API, IBKR Client Portal / Flex Web Service). The phone only stores a read-only, revocable token for this one endpoint.

## How it behaves

**Currency.** Each broker card shows its native currency (₹ Groww, $ IBKR). Underneath is the converted amount and the broker's share of the total. The combined total is shown in the base currency picked in *Edit Widget* (₹ by default). Day P&L converts yesterday's value at today's rate, so currency moves don't show up as stock P&L. If a rate is missing, that broker is left out instead of being converted at a wrong rate (`hasMissingFX`). The large widget's footer shows the rate it used (`USD/INR 88.65`).

**Refresh.**
- While NSE (09:15–15:30 IST) or NYSE (09:30–16:00 ET) is open, the widget refreshes every 20 minutes, plus once 2 minutes after each close. A full trading day is about 40 reloads, which fits WidgetKit's daily budget. Change it in `RefreshPolicy.marketHoursInterval` (15–30 min all work).
- Outside market hours it refreshes at the next open, or every 3 hours, whichever comes first. A failed fetch retries after 10 minutes.
- Each reload fetches once, then adds minute-by-minute timeline entries so "Updated Xm ago" keeps ticking without using extra reloads.
- If the cache is under 5 minutes old, no network call is made. Concurrent medium + large reloads share a single request.
- If the network fails, the last good payload is shown from the App Group cache with a ⚠︎ offline icon.
- Exchange holidays aren't modelled. On a holiday the widget just refreshes on the normal cadence and sees no change.

**Privacy.** These are marked `.privacySensitive()` and get redacted wherever iOS hides sensitive widget data on a locked device (Lock Screen, StandBy, and the Home Screen when *Allow Access When Locked → Widgets* is off):
- totals, P&L amounts, broker balances, the allocation bar and the sparkline.

These stay visible because they're public: tickers, market prices and % moves.

The token is stored in the Keychain as `AfterFirstUnlockThisDeviceOnly`. The cache uses `completeUntilFirstUserAuthentication`. The URLSession is ephemeral, with no URL cache.

## Design tokens

| Token | Value |
| --- | --- |
| Background | `#000000` |
| Card / border | `#18181B` / `#27272A` |
| Text primary / secondary / tertiary | `#FAFAFA` / `#A1A1AA` / `#71717A` |
| Gain (emerald) | `#10B981` |
| Loss (muted crimson) | `#E5484D` |
| Broker dots | Groww `#A78BFA`, IBKR `#38BDF8` (kept separate from the green/red P&L colours) |

Numbers use SF Pro Rounded with `.monospacedDigit()`. Labels and tickers use SF Pro.
