import Foundation
import Network

/// Performs a single availability check for an endpoint.
enum EndpointChecker {
    static let timeout: TimeInterval = 10

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Monitoring/1.0 (macOS)"]
        return URLSession(configuration: config)
    }()

    static func check(_ endpoint: Endpoint) async -> EndpointCheck {
        switch endpoint.kind {
        case .http(let url): await checkHTTP(url)
        case .tcp(let host, let port): await checkTCP(host: host, port: port)
        case .ping(let host): await checkPing(host: host)
        }
    }

    // MARK: HTTP

    static func checkHTTP(_ url: URL) async -> EndpointCheck {
        let start = ContinuousClock.now
        do {
            // bytes(for:) returns once headers arrive, so we don't download the body.
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
            let latency = (ContinuousClock.now - start).seconds
            bytes.task.cancel()
            let code = (response as? HTTPURLResponse)?.statusCode
            let isUp = code.map { $0 < 400 } ?? false
            return EndpointCheck(date: Date(), isUp: isUp, latency: latency, statusCode: code,
                                 error: isUp ? nil : code.map { "HTTP \($0) \(HTTPURLResponse.localizedString(forStatusCode: $0))" })
        } catch {
            return EndpointCheck(date: Date(), isUp: false, latency: nil, statusCode: nil, error: error.localizedDescription)
        }
    }

    // MARK: TCP

    static func checkTCP(host: String, port: UInt16) async -> EndpointCheck {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return EndpointCheck(date: Date(), isUp: false, latency: nil, statusCode: nil, error: "Invalid port")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = ContinuousClock.now
        let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(()))
                case .failed(let error): once.resume(.failure(error))
                case .waiting(let error): once.resume(.failure(error))
                case .cancelled: once.resume(.failure(CheckError.timeout))
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(CheckError.timeout))
            }
        }
        let latency = (ContinuousClock.now - start).seconds
        connection.cancel()
        switch outcome {
        case .success:
            return EndpointCheck(date: Date(), isUp: true, latency: latency, statusCode: nil, error: nil)
        case .failure(let error):
            return EndpointCheck(date: Date(), isUp: false, latency: nil, statusCode: nil, error: describe(error))
        }
    }

    // MARK: Ping

    static func checkPing(host: String) async -> EndpointCheck {
        do {
            let result = try await Shell.runAsync("/sbin/ping", ["-c", "1", "-W", "3000", "-q", host])
            if result.status == 0, let rtt = parsePingRTT(result.stdout) {
                return EndpointCheck(date: Date(), isUp: true, latency: rtt, statusCode: nil, error: nil)
            }
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return EndpointCheck(date: Date(), isUp: false, latency: nil, statusCode: nil,
                                 error: message.isEmpty ? "No reply" : message)
        } catch {
            return EndpointCheck(date: Date(), isUp: false, latency: nil, statusCode: nil, error: error.localizedDescription)
        }
    }

    /// Extracts the average RTT (seconds) from "round-trip min/avg/max/stddev = 1.2/3.4/5.6/0.1 ms".
    static func parsePingRTT(_ output: String) -> TimeInterval? {
        guard let line = output.split(separator: "\n").first(where: { $0.contains("min/avg/max") }),
              let equals = line.firstIndex(of: "=") else { return nil }
        let values = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard values.count >= 2, let avg = Double(values[1]) else { return nil }
        return avg / 1000
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? CheckError { return error.description }
        if let error = error as? NWError {
            switch error {
            case .posix(let code) where code == .ECONNREFUSED: return "Connection refused"
            case .posix(let code) where code == .ETIMEDOUT: return "Timed out"
            case .dns: return "Host not found"
            default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    enum CheckError: Error, CustomStringConvertible {
        case timeout
        var description: String { "Timed out" }
    }
}

/// Resumes a continuation at most once (NWConnection reports several states).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?

    init(_ continuation: CheckedContinuation<Result<Void, Error>, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Result<Void, Error>) {
        let pending: CheckedContinuation<Result<Void, Error>, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (s, attoseconds) = components
        return TimeInterval(s) + TimeInterval(attoseconds) / 1e18
    }
}
