import Foundation

/// Live prices and FX from Yahoo Finance's public chart endpoint (no key; unofficial, fine for
/// a personal app). Used for IBKR holdings — Flex only has end-of-day marks — and for FX.
enum MarketData {
    struct Quote: Sendable {
        let price: Double
        let previousClose: Double
    }

    static func quote(_ symbol: String) async throws -> Quote {
        let path = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        var request = URLRequest(url: URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(path)?range=1d&interval=1d")!)
        // Yahoo throttles requests that don't look like a browser.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTP.send(request)
        guard response.statusCode == 200,
              let meta = try JSONDecoder().decode(ChartResponse.self, from: data).chart.result?.first?.meta,
              let price = meta.regularMarketPrice else {
            throw PortfolioError.prices("No quote for \(symbol).")
        }
        // London (GBp), Johannesburg (ZAc) and Tel Aviv (ILA) quote in minor units.
        let scale = ["GBp", "ZAc", "ILA"].contains(meta.currency ?? "") ? 0.01 : 1
        let previous = meta.previousClose ?? meta.chartPreviousClose ?? price
        return Quote(price: price * scale, previousClose: previous * scale)
    }

    /// USD-based rates for every currency in `currencies` (e.g. INR via "USDINR=X").
    static func fxRates(for currencies: Set<CurrencyCode>) async throws -> FXRates {
        let needed = currencies.subtracting([.usd]).sorted { $0.rawValue < $1.rawValue }
        let rates = await needed.concurrentMap(limit: 4) { currency -> (String, Double?) in
            (currency.rawValue, try? await quote("USD\(currency.rawValue)=X").price)
        }
        var resolved: [String: Double] = [:]
        for (code, rate) in rates {
            guard let rate, rate > 0 else { throw PortfolioError.prices("No USD/\(code) rate.") }
            resolved[code] = rate
        }
        return FXRates(base: .usd, rates: resolved, asOf: .now)
    }

    /// IBKR symbol + listing exchange → Yahoo ticker.
    static func symbol(for holding: FlexStatement.Holding) -> String {
        let base = holding.symbol.replacingOccurrences(of: " ", with: "-") // "BRK B" → "BRK-B"
        let suffixes: [String: String] = [
            "LSE": ".L", "LSEETF": ".L", "IBIS": ".DE", "IBIS2": ".DE", "FWB": ".F", "GETTEX": ".DE",
            "AEB": ".AS", "SBF": ".PA", "BVME": ".MI", "BVME.ETF": ".MI", "EBS": ".SW", "SWX": ".SW",
            "TSE": ".TO", "VENTURE": ".V", "ASX": ".AX", "SEHK": ".HK", "SGX": ".SI", "TSEJ": ".T",
            "NSE": ".NS", "BSE": ".BO",
        ]
        return base + (holding.exchange.flatMap { suffixes[$0] } ?? "")
    }
}

private struct ChartResponse: Decodable {
    struct Chart: Decodable { let result: [Result]? }
    struct Result: Decodable { let meta: Meta }
    struct Meta: Decodable {
        let currency: String?
        let regularMarketPrice: Double?
        let previousClose: Double?
        let chartPreviousClose: Double?
    }

    let chart: Chart
}
