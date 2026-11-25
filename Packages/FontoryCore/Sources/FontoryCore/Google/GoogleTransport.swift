import Foundation

/// Fetches one URL. Abstracted so tests use an in-memory fake and never hit the network.
public protocol GoogleTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

public enum GoogleTransportError: Error, Equatable {
    /// The server answered with a non-2xx status.
    case http(Int)
}

/// Production transport. Task cancellation cancels the in-flight request.
public struct URLSessionGoogleTransport: GoogleTransport {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GoogleTransportError.http(http.statusCode)
        }
        return data
    }
}
