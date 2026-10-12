# Stock Widget

A dark, minimal iOS home-screen widget (WidgetKit + SwiftUI, iOS 17+) that combines a **Groww** (INR) and **Interactive Brokers** (USD) portfolio into one net-worth view.

| Medium | Large |
| --- | --- |
| Net worth + today's P&L on the left; Groww / IBKR balances, allocation bar and top 2 movers on the right | Net worth, P&L badge, 30-day sparkline, broker cards, top 5 positions, market status + FX footer |

## Project layout

No server: the app and widget call the brokers directly, with keys in the Keychain.

```
project.yml                     XcodeGen spec (app + widget extension, App Group, Keychain group)
Shared/                         Compiled into both targets
  Models/Currency.swift         CurrencyCode, FXRates (conversion)
  Models/Portfolio.swift        PortfolioSummary, BrokerHoldings, Position, HistoryPoint
  Models/PortfolioDisplayModel  Everything pre-computed in the chosen base currency
  Services/GrowwClient.swift    Groww Trade API: login (TOTP), holdings, quotes, cash
  Services/IBKRClient.swift     IBKR Flex Web Service: positions + cash (XML)
  Services/MarketData.swift     Yahoo Finance chart API: live prices for IBKR holdings, FX
  Services/TOTP.swift           RFC 6238 codes for Groww's daily login
  Services/PortfolioAggregator  Fetches both brokers, FX, records daily history
  Services/PortfolioRepository  Cache (App Group), throttling, request de-duplication
  Services/AppGroup.swift       App Group + Keychain credential store
  Support/MarketHours.swift     NSE / NYSE sessions + refresh policy
  Support/Formatters.swift      ₹ lakh/crore + $ K/M formatting, "Updated Xm ago"
Widget/                         Widget extension (provider, entry, intent, views)
App/StockWidgetApp.swift        Host app: enter keys, refresh now
```

## Setup

```sh
brew install xcodegen
xcodegen            # generates StockWidget.xcodeproj
open StockWidget.xcodeproj
```

1. Set your team, then replace `com.example.stockwidget` / `group.com.example.stockwidget` in `project.yml` **and** `Shared/Services/AppGroup.swift`.
2. **Groww** (needs the Trade API subscription): on groww.in go to Trade API → Generate API key → *Generate TOTP token*. Copy the **TOTP token** and the **TOTP secret**.
3. **IBKR**: in Client Portal → Performance & Reports → Flex Queries, create an *Activity Flex Query*:
   - **Open Positions**, with *Options: Summary*. Fields: Symbol, Description, Currency, Listing Exchange, Asset Class, Quantity, Mark Price, Multiplier.
   - **Cash Report**. Fields: Currency, Ending Cash.
   - **Account Information**. Field: Currency.
   - Format XML, period *Last Business Day*.

   Note the **Query ID**. Then enable *Flex Web Service* under Settings to get a **token**. Tokens last up to a year.
4. Run the app, paste the four values and tap **Save**. It refreshes straight away and shows each broker's total, or the error if a key is wrong. Then add the widget.

## Where the data comes from

| | Source | Notes |
| --- | --- | --- |
| Groww holdings, prices, cash | [Groww Trade API](https://groww.in/trade-api/docs): `/holdings/user`, `/live-data/quote`, `/margins/detail/user` | Access token expires 06:00 IST daily. The app logs in again by itself using a TOTP code generated on the phone. |
| IBKR holdings, cash | [Flex Web Service](https://www.interactivebrokers.com/campus/ibkr-api-page/flex-web-service) (`SendRequest` → `GetStatement`) | End-of-day snapshot, re-fetched at most every 6 hours. *Refresh now* in the app forces a new one. |
| IBKR live prices + previous close | Yahoo Finance chart endpoint | Unofficial, no key. Non-US listings are mapped by exchange (`.L`, `.DE`, …). If no sensible quote comes back, IBKR's mark price is used. |
| FX | Yahoo Finance (`USDINR=X`, …) | If the lookup fails, the last good rate is reused. |
| 30-day sparkline | Recorded on device | Each refresh saves per-broker totals in the App Group. The line starts the day you install. |

**Failures.** If one broker fails, its last good holdings stay on screen marked stale. If it has never loaded, it shows as an error. Either way its pill gets a ⚠︎, and the app shows the reason.

**Limitations**
- Groww's API doesn't expose mutual funds.
- IBKR quantities only update when a new Flex statement is generated. Trades you make today appear after the next statement, or straight away if you tap *Refresh now*.

## How it behaves

**Currency.** Each broker card shows its native currency (₹ Groww, $ IBKR). Underneath is the converted amount and the broker's share of the total. The combined total is shown in the base currency picked in *Edit Widget* (₹ by default). Day P&L converts yesterday's value at today's rate, so currency moves don't show up as stock P&L. If a rate is missing, that broker is left out instead of being converted at a wrong rate (`hasMissingFX`). The large widget's footer shows the rate it used (`USD/INR 88.65`).

**Refresh.**
- While NSE (09:15–15:30 IST) or NYSE (09:30–16:00 ET) is open, the widget refreshes every 20 minutes, plus once 2 minutes after each close. A full trading day is about 40 reloads, which fits WidgetKit's daily budget. Change it in `RefreshPolicy.marketHoursInterval` (15–30 min all work).
- Outside market hours it refreshes at the next open, or every 3 hours, whichever comes first. A failed fetch retries after 10 minutes.
- Each reload fetches once, then adds minute-by-minute timeline entries so "Updated Xm ago" keeps ticking without using extra reloads.
- If the cache is under 5 minutes old, no network call is made. Concurrent medium + large reloads share a single request.
- If the network fails, the last good payload is shown from the App Group cache with a ⚠︎ offline icon.
- Opening the app and tapping *Refresh now* does the slow part, a fresh IBKR Flex statement, and reloads the widgets.
- Exchange holidays aren't modelled. On a holiday the widget just refreshes on the normal cadence and sees no change.

**Privacy.** These are marked `.privacySensitive()` and get redacted wherever iOS hides sensitive widget data on a locked device (Lock Screen, StandBy, and the Home Screen when *Allow Access When Locked → Widgets* is off):
- totals, P&L amounts, broker balances, the allocation bar and the sparkline.

These stay visible because they're public: tickers, market prices and % moves.

Broker keys live in a Keychain access group shared by the app and the widget, as `AfterFirstUnlockThisDeviceOnly`: readable while the phone is locked after its first unlock, never backed up or synced. The settings screen never shows saved keys again. Cached data uses `completeUntilFirstUserAuthentication`. The URLSession is ephemeral, with no URL cache.

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
