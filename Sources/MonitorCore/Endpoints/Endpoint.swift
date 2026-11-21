import Foundation

/// A website or server the user wants watched.
public struct Endpoint: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: Codable, Sendable, Hashable {
        /// GET request; "up" means a response with status < 400 arrived.
        case http(url: URL)
        /// TCP connect to host:port (databases, SSH, game servers, ...).
        case tcp(host: String, port: UInt16)
        /// ICMP ping via /sbin/ping.
        case ping(host: String)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Seconds between checks (min 5).
    public var interval: TimeInterval
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, kind: Kind, interval: TimeInterval = 30, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.interval = max(5, interval)
        self.isEnabled = isEnabled
    }

    /// Human-readable target, e.g. "https://example.com" or "db.local:5432".
    public var target: String {
        switch kind {
        case .http(let url): url.absoluteString
        case .tcp(let host, let port): "\(host):\(port)"
        case .ping(let host): host
        }
    }

    /// Parses user input: a URL ("https://…"), "host:port" (TCP), or a bare host (ping).
    /// A bare domain such as "example.com" becomes an HTTPS check.
    public static func parse(_ input: String, name: String? = nil, interval: TimeInterval = 30) -> Endpoint? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let label = name?.isEmpty == false ? name! : text

        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            guard let url = URL(string: text), url.host != nil else { return nil }
            return Endpoint(name: label, kind: .http(url: url), interval: interval)
        }
        if let colon = text.lastIndex(of: ":"), !text.contains("::"),
           let port = UInt16(text[text.index(after: colon)...]), port > 0 {
            let host = String(text[..<colon])
            guard !host.isEmpty else { return nil }
            return Endpoint(name: label, kind: .tcp(host: host, port: port), interval: interval)
        }
        let looksLikeIP = text.allSatisfy { $0.isNumber || $0 == "." } || text.contains(":")
        if !looksLikeIP, text.contains("."), let url = URL(string: "https://\(text)") {
            return Endpoint(name: label, kind: .http(url: url), interval: interval)
        }
        return Endpoint(name: label, kind: .ping(host: text), interval: interval)
    }
}

public struct EndpointCheck: Sendable, Hashable, Identifiable {
    public var date: Date
    public var isUp: Bool
    /// Response time in seconds (HTTP: time to headers; TCP: connect time; ping: RTT).
    public var latency: TimeInterval?
    public var statusCode: Int?
    public var error: String?
    public var id: Date { date }

    public init(date: Date, isUp: Bool, latency: TimeInterval?, statusCode: Int?, error: String?) {
        self.date = date
        self.isUp = isUp
        self.latency = latency
        self.statusCode = statusCode
        self.error = error
    }
}

public struct EndpointStatus: Sendable, Hashable {
    public enum State: String, Sendable, Hashable { case unknown, up, down }

    public var state: State
    public var lastCheck: EndpointCheck?
    /// Most recent checks, oldest first (max 100).
    public var history: [EndpointCheck]

    /// Share of successful checks in `history`, 0...100.
    public var uptimePercent: Double? {
        guard !history.isEmpty else { return nil }
        return Double(history.filter(\.isUp).count) / Double(history.count) * 100
    }

    public var averageLatency: TimeInterval? {
        let values = history.compactMap(\.latency)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public init(state: State = .unknown, lastCheck: EndpointCheck? = nil, history: [EndpointCheck] = []) {
        self.state = state
        self.lastCheck = lastCheck
        self.history = history
    }

    mutating func record(_ check: EndpointCheck, limit: Int = 100) {
        lastCheck = check
        state = check.isUp ? .up : .down
        history.append(check)
        if history.count > limit { history.removeFirst(history.count - limit) }
    }
}
