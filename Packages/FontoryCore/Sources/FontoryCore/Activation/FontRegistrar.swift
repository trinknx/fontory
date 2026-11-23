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

    public init(scope: CTFontManagerScope = .session) { self.scope = scope }

    public func register(_ urls: [URL]) async -> [URL: RegistrationOutcome] {
        await run(urls, enabled: true, benign: .alreadyRegistered)
    }

    public func unregister(_ urls: [URL]) async -> [URL: RegistrationOutcome] {
        await run(urls, enabled: false, benign: .notRegistered)
    }

    public func availablePostScriptNames() -> Set<String> {
        Set((CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? [])
    }

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var results: [URL: RegistrationOutcome]
        var resumed = false
        init(urls: [URL]) { results = Dictionary(urls.map { ($0, .ok) }, uniquingKeysWith: { a, _ in a }) }
    }

    private func run(_ urls: [URL], enabled: Bool, benign: CTFontManagerError) async -> [URL: RegistrationOutcome] {
        guard !urls.isEmpty else { return [:] }
        let collector = Collector(urls: urls)
        let scope = self.scope
        var byPath: [String: URL] = [:]
        for url in urls {
            byPath[url.standardizedFileURL.path] = url
            byPath[url.resolvingSymlinksInPath().path] = url
        }
        let pathIndex = byPath
        return await withCheckedContinuation { (cont: CheckedContinuation<[URL: RegistrationOutcome], Never>) in
            let handler: (CFArray, Bool) -> Bool = { errors, done in
                collector.lock.lock()
                defer { collector.lock.unlock() }
                for case let err as NSError in (errors as [AnyObject]) {
                    let outcome: RegistrationOutcome =
                        err.code == Int(benign.rawValue) ? .alreadyRegistered : .failed(err.localizedDescription)
                    // CoreText reports standardized URLs; map them back to the input URLs.
                    let reported = (err.userInfo[kCTFontManagerErrorFontURLsKey as String] as? [URL]) ?? []
                    var attributed = false
                    for u in reported {
                        if let input = pathIndex[u.standardizedFileURL.path] ?? pathIndex[u.resolvingSymlinksInPath().path] {
                            collector.results[input] = outcome
                            attributed = true
                        }
                    }
                    if !attributed {  // unattributed error: applies to the whole batch
                        for url in urls where collector.results[url] == .ok { collector.results[url] = outcome }
                    }
                }
                if done, !collector.resumed {
                    collector.resumed = true
                    cont.resume(returning: collector.results)
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
