import Foundation

/// Interactive Brokers, without a gateway: the Flex Web Service is plain HTTPS with a
/// long-lived token, so it works from a phone.
///
/// Flex statements are end-of-day snapshots, so they're only used for *what you hold*
/// (quantities, cash) and refreshed every few hours. Live prices and previous closes
/// come from `MarketData` on every widget reload.
///
/// Flex Query setup (Client Portal → Performance & Reports → Flex Queries → Activity):
///   • Open Positions: Symbol, Description, Currency, Listing Exchange, Asset Class,
///     Quantity, Mark Price, Multiplier — Options: Summary
///   • Cash Report: Currency, Ending Cash
///   • Account Information: Currency
///   Format XML, Period "Last Business Day".
struct IBKRClient: Sendable {
    static let brokerID = BrokerID.ibkr
    static let displayName = "Interactive Brokers"
    static let shortName = "IBKR"
    static let defaultCurrency = CurrencyCode.usd

    /// Flex data changes once a day; don't spend the widget's time budget regenerating it more often.
    static let statementMaxAge: TimeInterval = 6 * 3_600

    private static let flexBase = "https://ndcdyn.interactivebrokers.com/AccountManagement/FlexWebService"

    var keychain: Keychain = .shared
    var statementCache = StatementCache()

    var isConfigured: Bool {
        keychain.string(.ibkrFlexToken) != nil && keychain.string(.ibkrFlexQueryID) != nil
    }

    func fetchHoldings(forceStatement: Bool = false) async throws -> BrokerHoldings {
        let statement = try await statement(force: forceStatement)
        let currency = statement.accountCurrency.map(CurrencyCode.init(rawValue:)) ?? Self.defaultCurrency

        let positions = await statement.positions.concurrentMap(limit: 6) { held -> Position in
            var quote = try? await MarketData.quote(MarketData.symbol(for: held))
            // A wildly different price means the symbol mapped to the wrong listing; trust IBKR's mark.
            if let price = quote?.price, held.markPrice > 0, abs(price / held.markPrice - 1) > 0.5 { quote = nil }
            let last = quote?.price ?? held.markPrice
            return Position(
                symbol: held.symbol,
                name: held.description ?? held.symbol,
                exchange: held.exchange ?? "SMART",
                currency: CurrencyCode(rawValue: held.currency),
                quantity: held.quantity,
                lastPrice: last,
                previousClose: quote?.previousClose ?? last
            )
        }

        return BrokerHoldings(
            id: Self.brokerID,
            displayName: Self.displayName,
            shortName: Self.shortName,
            currency: currency,
            cash: statement.cash ?? 0,
            syncedAt: statement.fetchedAt,
            syncStatus: .ok,
            positions: positions
        )
    }

    // MARK: - Flex statement

    private func statement(force: Bool) async throws -> FlexStatement {
        let cached = statementCache.read()
        if !force, let cached, Date.now.timeIntervalSince(cached.fetchedAt) < Self.statementMaxAge {
            return cached
        }
        do {
            let fresh = try await requestStatement()
            statementCache.write(fresh)
            return fresh
        } catch {
            // Positions rarely change intraday; a day-old statement still prices correctly.
            if let cached { return cached }
            throw error
        }
    }

    private func requestStatement() async throws -> FlexStatement {
        guard let token = keychain.string(.ibkrFlexToken),
              let queryID = keychain.string(.ibkrFlexQueryID) else { throw PortfolioError.notConfigured }

        let send = try FlexXML.parse(try await flexGET("SendRequest", query: ["t": token, "q": queryID, "v": "3"]))
        guard send.text["Status"] == "Success", let reference = send.text["ReferenceCode"] else {
            throw PortfolioError.ibkr(send.text["ErrorMessage"] ?? "Flex request failed.")
        }

        // Generation usually takes a few seconds; 1019 means "still generating".
        for delay in [2.0, 3.0, 4.0, 5.0] {
            try await Task.sleep(for: .seconds(delay))
            let document = try FlexXML.parse(try await flexGET("GetStatement", query: ["t": token, "q": reference, "v": "3"]))
            if document.root == "FlexQueryResponse" {
                return FlexStatement(document: document)
            }
            guard document.text["ErrorCode"] == "1019" else {
                throw PortfolioError.ibkr(document.text["ErrorMessage"] ?? "Flex statement failed.")
            }
        }
        throw PortfolioError.ibkr("Flex statement is taking too long; will retry.")
    }

    private func flexGET(_ endpoint: String, query: [String: String]) async throws -> Data {
        var components = URLComponents(string: "\(Self.flexBase)/\(endpoint)")!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("StockWidget/1.0", forHTTPHeaderField: "User-Agent") // Flex rejects requests without one
        let (data, response) = try await HTTP.send(request)
        guard response.statusCode == 200 else { throw PortfolioError.ibkr("Flex HTTP \(response.statusCode).") }
        return data
    }
}

// MARK: - Statement model + cache

struct FlexStatement: Codable, Sendable {
    struct Holding: Codable, Sendable {
        let symbol: String
        let description: String?
        let currency: String
        let exchange: String?
        let assetCategory: String?
        let quantity: Double
        let markPrice: Double
    }

    let accountCurrency: String?
    /// Ending cash in the account's base currency.
    let cash: Double?
    let positions: [Holding]
    let fetchedAt: Date

    init(document: FlexXML, fetchedAt: Date = .now) {
        accountCurrency = document.elements("AccountInformation").first?["currency"]
        cash = document.elements("CashReportCurrency")
            .first { $0["currency"] == "BASE_SUMMARY" }
            .flatMap { $0["endingCash"] }
            .flatMap(Double.init)
        positions = document.elements("OpenPosition").compactMap { attributes in
            // With "Options: Summary" there's one row per holding; ignore lot-level rows if present.
            if let level = attributes["levelOfDetail"], level != "SUMMARY" { return nil }
            guard let symbol = attributes["symbol"], let currency = attributes["currency"],
                  let quantity = attributes["position"].flatMap(Double.init), quantity != 0,
                  let mark = attributes["markPrice"].flatMap(Double.init) else { return nil }
            let multiplier = attributes["multiplier"].flatMap(Double.init) ?? 1
            return Holding(
                symbol: symbol,
                description: attributes["description"],
                currency: currency,
                exchange: attributes["listingExchange"],
                assetCategory: attributes["assetCategory"],
                quantity: quantity * multiplier,
                markPrice: mark
            )
        }
        self.fetchedAt = fetchedAt
    }
}

struct StatementCache: Sendable {
    var fileURL: URL? = AppGroup.fileURL("ibkr-statement.json")

    func read() -> FlexStatement? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.portfolio.decode(FlexStatement.self, from: data)
    }

    func write(_ statement: FlexStatement) {
        guard let fileURL, let data = try? JSONEncoder.portfolio.encode(statement) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }
}

/// Minimal XML reader: element attributes in document order plus text of leaf elements.
final class FlexXML: NSObject, XMLParserDelegate {
    private(set) var root: String?
    private(set) var text: [String: String] = [:]
    private var attributesByElement: [String: [[String: String]]] = [:]
    private var currentText = ""

    static func parse(_ data: Data) throws -> FlexXML {
        let document = FlexXML()
        let parser = XMLParser(data: data)
        parser.delegate = document
        guard parser.parse() else { throw PortfolioError.ibkr("Unreadable Flex response.") }
        return document
    }

    func elements(_ name: String) -> [[String: String]] { attributesByElement[name] ?? [] }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if root == nil { root = name }
        attributesByElement[name, default: []].append(attributes)
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { text[name] = trimmed }
        currentText = ""
    }
}
