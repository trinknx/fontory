import CoreText
import Foundation

public enum RegistrationOutcome: Sendable, Equatable { case ok, alreadyRegistered, failed(String) }

public protocol FontRegistrar: Sendable {
    func register(_ urls: [URL]) async -> [URL: RegistrationOutcome]
    func unregister(_ urls: [URL]) async -> [URL: RegistrationOutcome]
    /// `CTFontManagerCopyAvailablePostScriptNames`; expensive, call once per operation.
    func availablePostScriptNames() -> Set<String>
}

public struct CoreTextRegistrar: FontRegistrar {
    public let scope: CTFontManagerScope
    private let availableFontURLs: @Sendable () -> [URL]

    public init(
        scope: CTFontManagerScope = .session,
        availableFontURLs: @escaping @Sendable () -> [URL] = { (CTFontManagerCopyAvailableFontURLs() as? [URL]) ?? [] }
    ) {
        self.scope = scope
        self.availableFontURLs = availableFontURLs
    }

    public func register(_ urls: [URL]) async -> [URL: RegistrationOutcome] {
        await run(urls, enabled: true, benign: .alreadyRegistered)
    }

    public func unregister(_ urls: [URL]) async -> [URL: RegistrationOutcome] {
        await run(urls, enabled: false, benign: .notRegistered)
    }

    public func availablePostScriptNames() -> Set<String> {
        Set((CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? [])
    }

    /// One error as delivered by the CoreText handler.
    struct RegistrationError: Sendable {
        var code: Int
        var description: String
        var urls: [URL]
    }

    private static func pathKeys(_ url: URL) -> [String] {
        [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
    }

    /// Turns the handler's errors into per-input outcomes. Errors naming inputs are applied to
    /// exactly those inputs. An error with no URLs, or with any URL matching no input, is not
    /// guessed at: the remaining inputs are resolved against `availableURLs` (real registration state).
    static func outcomes(
        inputs: [URL], errors: [RegistrationError], enabled: Bool, benign: CTFontManagerError,
        availableURLs: () -> [URL]
    ) -> [URL: RegistrationOutcome] {
        var results = Dictionary(inputs.map { ($0, RegistrationOutcome.ok) }, uniquingKeysWith: { a, _ in a })
        var byPath: [String: URL] = [:]
        for url in inputs { for k in pathKeys(url) { byPath[k] = url } }

        var uncertain: String?
        for err in errors {
            let outcome: RegistrationOutcome =
                err.code == Int(benign.rawValue) ? .alreadyRegistered : .failed(err.description)
            var unmatched = err.urls.isEmpty
            for u in err.urls {
                if let input = pathKeys(u).lazy.compactMap({ byPath[$0] }).first {
                    results[input] = outcome
                } else {
                    unmatched = true
                }
            }
            if unmatched, uncertain == nil { uncertain = err.description }
        }

        if let uncertain, results.values.contains(.ok) {
            var present = Set<String>()
            for u in availableURLs() { present.formUnion(pathKeys(u)) }
            for url in inputs where results[url] == .ok {
                let isPresent = pathKeys(url).contains { present.contains($0) }
                if isPresent != enabled { results[url] = .failed(uncertain) }
            }
        }
        return results
    }

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var errors: [RegistrationError] = []
        var resumed = false
    }

    private func run(_ urls: [URL], enabled: Bool, benign: CTFontManagerError) async -> [URL: RegistrationOutcome] {
        guard !urls.isEmpty else { return [:] }
        let collector = Collector()
        let scope = self.scope
        let available = availableFontURLs
        return await withCheckedContinuation { (cont: CheckedContinuation<[URL: RegistrationOutcome], Never>) in
            let handler: (CFArray, Bool) -> Bool = { errors, done in
                collector.lock.lock()
                defer { collector.lock.unlock() }
                for case let err as NSError in (errors as [AnyObject]) {
                    collector.errors.append(RegistrationError(
                        code: err.code, description: err.localizedDescription,
                        urls: (err.userInfo[kCTFontManagerErrorFontURLsKey as String] as? [URL]) ?? []))
                }
                if done, !collector.resumed {
                    collector.resumed = true
                    cont.resume(returning: Self.outcomes(
                        inputs: urls, errors: collector.errors, enabled: enabled, benign: benign, availableURLs: available))
                }
                return true
            }
            if enabled {
                CTFontManagerRegisterFontURLs(urls as CFArray, scope, true, handler)
            } else {
                CTFontManagerUnregisterFontURLs(urls as CFArray, scope, handler)
            }
        }
    }
}
