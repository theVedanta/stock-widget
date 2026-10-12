# Stock Widget

A dark, minimal iOS home-screen widget (WidgetKit + SwiftUI, iOS 17+) that combines a **Groww** (INR) and **Interactive Brokers** (USD) portfolio into one net-worth view.

| Medium | Large |
| --- | --- |
| Net worth + today's P&L on the left; Groww / IBKR balances, allocation bar and top 2 movers on the right | Net worth, P&L badge, 30-day sparkline, broker cards, top 5 positions, market status + FX footer |

## Project layout

```
project.yml                     XcodeGen spec (app + widget extension, App Group, Keychain group)
Backend/portfolio.sample.json   Backend response contract / sample payload
Shared/                         Compiled into both targets
  Models/Currency.swift         CurrencyCode, FXRates (conversion)
  Models/Portfolio.swift        PortfolioSummary, BrokerHoldings, Position, HistoryPoint (wire models)
  Models/PortfolioDisplayModel  Everything pre-computed in the chosen base currency
  Services/PortfolioDataSource  Remote REST client, errors, data-source factory
  Services/PortfolioRepository  Cache (App Group), throttling, request de-duplication
  Services/MockPortfolioData…   Sample data (gain / loss / stale-broker scenarios)
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

## Getting started

```sh
brew install xcodegen
xcodegen            # generates StockWidget.xcodeproj
open StockWidget.xcodeproj
```

1. Set your team, then replace `com.example.stockwidget` / `group.com.example.stockwidget` in `project.yml` **and** `Shared/Services/AppGroup.swift`.
2. Open `Widget/Views/MediumPortfolioView.swift` or `LargePortfolioView.swift` — the `#Preview` timelines render from mock data immediately (gain day, loss day, stale IBKR, offline).
3. Run the app and enter your backend URL + token. Until then, the widget shows sample data with a `SAMPLE` tag.

## Backend contract

`GET <endpoint>` with `Authorization: Bearer <token>` → `200 application/json`. Full example: [`Backend/portfolio.sample.json`](Backend/portfolio.sample.json).

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

The backend sends raw facts only (quantity, price, previous close, cash, FX). The device derives market values, totals, day P&L and percentages, so the numbers always add up. Dates are ISO-8601, fractional seconds optional. Unknown fields are ignored. Bump `schemaVersion` for breaking changes; the widget shows "Update the app" when it sees a version it doesn't know.

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
