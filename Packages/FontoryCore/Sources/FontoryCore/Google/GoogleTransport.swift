import Foundation

/// Fetches one URL. Abstracted so tests use an in-memory fake and never hit the network.
public protocol GoogleTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

public enum GoogleTransportError: Error, Equatable {
    /// The server answered with a non-2xx status (including a 3xx whose redirect was refused).
    case http(Int)
}

/// Production transport. Task cancellation cancels the in-flight request. Redirects are followed only to
/// https on fonts.google.com or fonts.gstatic.com (allowed-hosts rule); a refused redirect surfaces as
/// `GoogleTransportError.http(3xx)`.
public struct URLSessionGoogleTransport: GoogleTransport {
    static let allowedHosts: Set<String> = ["fonts.google.com", "fonts.gstatic.com"]

    private let session: URLSession
    private let guardDelegate = RedirectGuard()

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: guardDelegate, delegateQueue: nil)
    }

    /// Whether a redirect target may be followed: https and a host exactly in `allowedHosts`.
    static func isAllowedRedirect(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    public func data(from url: URL) async throws -> Data {
        // The guard is passed per task too: async convenience methods route task callbacks to a task delegate.
        let (data, response) = try await session.data(from: url, delegate: guardDelegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GoogleTransportError.http(http.statusCode)
        }
        return data
    }
}

/// Refuses redirects outside the allowed hosts by completing with nil, which returns the 3xx response itself.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, URLSessionGoogleTransport.isAllowedRedirect(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
