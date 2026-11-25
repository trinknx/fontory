import Foundation
import Testing
@testable import FontoryCore

/// Serves in-memory responses per URL. Never touches the network.
final class FakeGoogleTransport: GoogleTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: Data] = [:]
    private var failuresLeft: [URL: Int] = [:]
    private var requested: [URL] = []
    private var inFlight = 0
    private var maxInFlightValue = 0
    /// Delay applied to every font (gstatic) request.
    var fontDelay: Duration = .zero
    /// Called (outside the lock) before each request is answered.
    var onRequest: (@Sendable (URL) -> Void)?

    func set(_ url: URL, _ data: Data) { lock.withLock { responses[url] = data } }
    func remove(_ url: URL) { lock.withLock { _ = responses.removeValue(forKey: url) } }
    func fail(_ url: URL, times: Int) { lock.withLock { failuresLeft[url] = times } }
    var requests: [URL] { lock.withLock { requested } }
    var maxInFlight: Int { lock.withLock { maxInFlightValue } }

    func data(from url: URL) async throws -> Data {
        let isFont = url.host() == "fonts.gstatic.com"
        lock.withLock {
            requested.append(url)
            if isFont { inFlight += 1; maxInFlightValue = max(maxInFlightValue, inFlight) }
        }
        defer { if isFont { lock.withLock { inFlight -= 1 } } }
        onRequest?(url)
        if isFont, fontDelay > .zero { try await Task.sleep(for: fontDelay) }
        return try lock.withLock {
            if let n = failuresLeft[url], n > 0 {
                failuresLeft[url] = n - 1
                throw GoogleTransportError.http(503)
            }
            guard let d = responses[url] else { throw GoogleTransportError.http(404) }
            return d
        }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [GoogleRunEvent] = []
    func append(_ e: GoogleRunEvent) { lock.withLock { items.append(e) } }
    var events: [GoogleRunEvent] { lock.withLock { items } }
    var done: [String] { events.compactMap { if case .familyDone(let f) = $0 { f } else { nil } } }
    var failed: [String] { events.compactMap { if case .familyFailed(let f, _) = $0 { f } else { nil } } }
    var finished: Bool { events.contains { if case .finished = $0 { true } else { false } } }
    var rootUnavailable: Bool { events.contains { if case .rootUnavailable = $0 { true } else { false } } }
}

@Suite struct GoogleDownloaderTests {
    // MARK: Fixtures

    /// A fresh `<tmp>/<uuid>/root` directory; the parent lets tests check that siblings survive.
    private func makeRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("GoogleDL-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func makeStore() throws -> FontStore { try FontStore(database: Database(path: ":memory:")) }

    private func catalog(_ families: [(String, String)]) -> Data {
        let list = families.map {
            "{\"family\":\"\($0.0)\",\"category\":\"Sans Serif\",\"subsets\":[\"latin\"],\"designers\":[],\"lastModified\":\"\($0.1)\",\"popularity\":1}"
        }.joined(separator: ",")
        return Data(")]}'\n{\"familyMetadataList\":[\(list)]}".utf8)
    }

    private func fontURL(_ family: String, _ name: String, host: String = "fonts.gstatic.com", scheme: String = "https") -> URL {
        URL(string: "\(scheme)://\(host)/s/\(family.replacingOccurrences(of: " ", with: ""))/\(name.replacingOccurrences(of: "/", with: "_"))")!
    }

    private func manifest(_ refs: [(String, URL)], files: [(String, String)] = [("OFL.txt", "licence")]) -> Data {
        let f = files.map { "{\"filename\":\"\($0.0)\",\"contents\":\"\($0.1)\"}" }.joined(separator: ",")
        let r = refs.map { "{\"filename\":\"\($0.0)\",\"url\":\"\($0.1.absoluteString)\"}" }.joined(separator: ",")
        return Data(")]}'\n{\"manifest\":{\"files\":[\(f)],\"fileRefs\":[\(r)]}}".utf8)
    }

    /// Serves a manifest with the given static font files (name → bytes) for `family`.
    private func serve(_ t: FakeGoogleTransport, _ family: String, fonts: [String: String],
                       files: [(String, String)] = [("OFL.txt", "licence")]) {
        let refs = fonts.keys.sorted().map { ("static/\($0)", fontURL(family, "static/\($0)")) }
        t.set(GoogleCatalog.manifestURL(for: family), manifest(refs, files: files))
        for (name, bytes) in fonts { t.set(fontURL(family, "static/\(name)"), Data(bytes.utf8)) }
    }

    private func downloader(_ store: FontStore, _ root: URL, _ t: FakeGoogleTransport, minimum: Int = 1) -> GoogleFontsDownloader {
        GoogleFontsDownloader(store: store, root: root, transport: t, backoff: [.zero, .zero, .zero], minimumFamilies: minimum)
    }

    private func status(_ store: FontStore) throws -> [String: (status: Int, error: String?, downloaded: String?)] {
        try store.database.withLock {
            let s = try store.database.prepare("SELECT family, status, error, downloaded_modified FROM google_families")
            defer { s.reset() }
            var out: [String: (Int, String?, String?)] = [:]
            while try s.step() { out[s.text(0)] = (Int(s.int64(1)), s.isNull(2) ? nil : s.text(2), s.isNull(3) ? nil : s.text(3)) }
            return out
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func contents(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
    private func tmp(_ root: URL) -> URL { root.appendingPathComponent(".fontory-tmp") }

    // MARK: Tests

    @Test func firstDownloadWritesStaticAndLicence() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let store = try makeStore()
        let t = FakeGoogleTransport()
        var fams = [("Roboto", "2025-01-01")]
        for i in 1..<1000 { fams.append(("Fam\(i)", "2024-01-01")) }
        t.set(GoogleCatalog.catalogURL, catalog(fams))
        t.set(GoogleCatalog.manifestURL(for: "Roboto"), manifest([
            ("Roboto-VariableFont_wght.ttf", fontURL("Roboto", "Roboto-VariableFont_wght.ttf")),
            ("static/Roboto-Bold.ttf", fontURL("Roboto", "static/Roboto-Bold.ttf")),
        ]))
        t.set(fontURL("Roboto", "static/Roboto-Bold.ttf"), Data("bold".utf8))
        t.set(fontURL("Roboto", "Roboto-VariableFont_wght.ttf"), Data("var".utf8))

        let dl = GoogleFontsDownloader(store: store, root: root, transport: t, backoff: [])
        let summary = try await dl.refreshCatalog()
        #expect(summary.added == 1000)
        let log = EventLog()
        await dl.run { log.append($0) }

        #expect(contents(root.appendingPathComponent("Roboto/Roboto-Bold.ttf")) == "bold")
        #expect(contents(root.appendingPathComponent("Roboto/OFL.txt")) == "licence")
        #expect(!exists(root.appendingPathComponent("Roboto/Roboto-VariableFont_wght.ttf")))
        #expect(!t.requests.contains(fontURL("Roboto", "Roboto-VariableFont_wght.ttf")))
        #expect(!exists(tmp(root)))
        let s = try status(store)
        #expect(s["Roboto"]?.status == 1)
        #expect(s["Roboto"]?.downloaded == "2025-01-01")
        #expect(log.done == ["Roboto"])
        #expect(log.failed.count == 999)
        #expect(log.finished)
    }

    @Test func refreshRejectsBadCatalogWithoutChanges() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let store = try makeStore()
        let t = FakeGoogleTransport()
        t.set(GoogleCatalog.catalogURL, Data("<html><body>Sorry</body></html>".utf8))
        let dl = GoogleFontsDownloader(store: store, root: root, transport: t, backoff: [])
        await #expect(throws: GoogleCatalogError.malformed) { try await dl.refreshCatalog() }
        #expect(try store.googleProgress().total == 0)
        // Too few families (default minimum) is rejected too.
        t.set(GoogleCatalog.catalogURL, catalog([("A", "1")]))
        await #expect(throws: GoogleCatalogError.tooFewFamilies(1)) { try await dl.refreshCatalog() }
        #expect(try store.googleProgress().total == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func failedManifestMarksFamilyAndContinues() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let store = try makeStore()
        let t = FakeGoogleTransport()
        t.set(GoogleCatalog.catalogURL, catalog([("A", "1"), ("B", "1")]))
        serve(t, "B", fonts: ["B-Regular.ttf": "b"])
        let dl = downloader(store, root, t)
        _ = try await dl.refreshCatalog()
        let log = EventLog()
        await dl.run { log.append($0) }

        let s = try status(store)
        #expect(s["A"]?.status == 2)
        #expect(s["A"]?.error?.contains("404") == true)
        #expect(s["B"]?.status == 1)
        #expect(log.failed == ["A"])
        #expect(log.done == ["B"])
        #expect(log.finished)
        // Retried three times.
        #expect(t.requests.filter { $0 == GoogleCatalog.manifestURL(for: "A") }.count == 3)
        #expect(!exists(root.appendingPathComponent("A")))
    }

    @Test func fileRetryThenFailCleansTemp() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let store = try makeStore()
        let t = FakeGoogleTransport()
        t.set(GoogleCatalog.catalogURL, catalog([("X", "1")]))
        serve(t, "X", fonts: ["X-Bold.ttf": "bold", "X-Thin.ttf": "thin"])
        let bad = fontURL("X", "static/X-Bold.ttf")
        t.fail(bad, times: 3)
        let dl = downloader(store, root, t)
        _ = try await dl.refreshCatalog()
        let log = EventLog()
        await dl.run { log.append($0) }

        #expect(try status(store)["X"]?.status == 2)
        #expect(log.failed == ["X"])
        #expect(!exists(root.appendingPathComponent("X")))
        #expect(!exists(tmp(root)))
        #expect(t.requests.filter { $0 == bad }.count == 3)

        // Two failures then success: done.
        t.fail(bad, times: 2)
        let log2 = EventLog()
        await dl.run { log2.append($0) }
        #expect(try status(store)["X"]?.status == 1)
        #expect(log2.done == ["X"])
        #expect(contents(root.appendingPathComponent("X/X-Bold.ttf")) == "bold")
        #expect(!exists(tmp(root)))
    }

    @Test func updateReplacesInPlaceAndDropsRemoved() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let store = try makeStore()
        let t = FakeGoogleTransport()
        t.set(GoogleCatalog.catalogURL, catalog([("X", "2024-01-01")]))
        serve(t, "X", fonts: ["X-Bold.ttf": "bold-v1", "X-Thin.ttf": "thin-v1"], files: [("OFL.txt", "licence-v1")])
        let dl = downloader(store, root, t)
        _ = try await dl.refreshCatalog()
        await dl.run { _ in }
        let folder = root.appendingPathComponent("X")
        #expect(contents(folder.appendingPathComponent("X-Thin.ttf")) == "thin-v1")

        // Newer version: Bold changed, Thin removed, licence updated.
        t.set(GoogleCatalog.catalogURL, catalog([("X", "2025-06-01")]))
        t.remove(fontURL("X", "static/X-Thin.ttf"))
        serve(t, "X", fonts: ["X-Bold.ttf": "bold-v2"], files: [("OFL.txt", "licence-v2")])
        let summary = try await dl.refreshCatalog()
        #expect(summary.updated == 1)
        let log = EventLog()
        await dl.run { log.append($0) }

        #expect(log.done == ["X"])
        #expect(contents(folder.appendingPathComponent("X-Bold.ttf")) == "bold-v2")
        #expect(!exists(folder.appendingPathComponent("X-Thin.ttf")))
        #expect(contents(folder.appendingPathComponent("OFL.txt")) == "licence-v2")
        #expect(try status(store)["X"]?.downloaded == "2025-06-01")
        #expect(!exists(tmp(root)))
    }

    @Test func doesNotTouchOtherFolders() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Mine"), withIntermediateDirectories: false)
        try Data("mine".utf8).write(to: root.appendingPathComponent("Mine/keep.ttf"))
        let sibling = root.deletingLastPathComponent().appendingPathComponent("sibling.ttf")
        try Data("sib".utf8).write(to: sibling)
        try Data("loose".utf8).write(to: root.appendingPathComponent("loose.ttf"))

        let store = try makeStore()
        let t = FakeGoogleTransport()
        t.set(GoogleCatalog.catalogURL, catalog([("X", "1"), ("Y", "1")]))
        serve(t, "X", fonts: ["X-Bold.ttf": "a", "X-Thin.ttf": "b"])
        let dl = downloader(store, root, t)
        _ = try await dl.refreshCatalog()
        await dl.run { _ in }
        // Update X with fewer files (deletes inside X only), Y keeps failing.
        t.set(GoogleCatalog.catalogURL, catalog([("X", "2"), ("Y", "1")]))
        t.remove(fontURL("X", "static/X-Thin.ttf"))
        serve(t, "X", fonts: ["X-Bold.ttf": "c"], files: [])
        _ = try await dl.refreshCatalog()
        await dl.run { _ in }

        #expect(contents(root.appendingPathComponent("Mine/keep.ttf")) == "mine")
        #expect(contents(sibling) == "sib")
        #expect(contents(root.appendingPathComponent("loose.ttf")) == "loose")
        #expect(Set(try fm.contentsOfDirectory(atPath: root.path)) == ["Mine", "X", "loose.ttf"])
        #expect(Set(try fm.contentsOfDirectory(atPath: root.deletingLastPathComponent().path)) == ["root", "sibling.ttf"])
    }

    @Test func staleTempRemovedAtStart() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let stale = tmp(root).appendingPathComponent("X")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: stale.appendingPathComponent("partial.ttf"))
        let store = try makeStore()
        let t = FakeGoogleTransport()
        let dl = downloader(store, root, t)
        let log = EventLog()
        await dl.run { log.append($0) }
        #expect(!exists(stale.appendingPathComponent("partial.ttf")))
        #expect(!exists(tmp(root)))
        #expect(log.finished)
    }

    @Test func cancellationStopsEarly() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let store = try makeStore()
        let t = FakeGoogleTransport()
        t.fontDelay = .milliseconds(20)
        let names = (0..<30).map { String(format: "F%02d", $0) }
        t.set(GoogleCatalog.catalogURL, catalog(names.map { ($0, "1") }))
        for n in names { serve(t, n, fonts: ["\(n)-A.ttf": "a", "\(n)-B.ttf": "b"]) }
        let dl = downloader(store, root, t)
        _ = try await dl.refreshCatalog()

        let log = EventLog()
        let holder = TaskHolder()
        let task = Task { await dl.run { e in
            log.append(e)
            if case .familyDone = e { holder.task?.cancel() }
        } }
        holder.task = task
        await task.value

        let s = try status(store)
        let done = s.values.filter { $0.status == 1 }.count
        #expect(done >= 1 && done < 30)
        #expect(!s.values.contains { $0.status == 2 })
        #expect(log.failed.isEmpty)
        #expect(!log.finished)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).count == done + (exists(tmp(root)) ? 1 : 0))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: tmp(root).path))?.isEmpty ?? true)

        let log2 = EventLog()
        await dl.run { log2.append($0) }
        #expect(try status(store).values.allSatisfy { $0.status == 1 })
        #expect(log2.done.count == 30 - done)
        #expect(log2.finished)
        #expect(!exists(tmp(root)))
    }

    @Test func rootVanishingStopsRunWithoutMassFailure() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let store = try makeStore()
        let t = FakeGoogleTransport()
        let names = ["A", "B", "C", "D"]
        t.set(GoogleCatalog.catalogURL, catalog(names.map { ($0, "1") }))
        for n in names { serve(t, n, fonts: ["\(n).ttf": n]) }
        let dl = downloader(store, root, t)
        _ = try await dl.refreshCatalog()
        let log = EventLog()
        await dl.run { e in
            log.append(e)
            if case .familyDone = e { try? FileManager.default.removeItem(at: root) }
        }
        #expect(log.done == ["A"])
        #expect(log.rootUnavailable)
        #expect(log.failed.isEmpty)
        #expect(!log.finished)
        let s = try status(store)
        #expect(!s.values.contains { $0.status == 2 })
        #expect(!exists(root)) // never recreated
    }

    @Test func rootVanishingMidFamilyIsNotAFailure() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let store = try makeStore()
        let t = FakeGoogleTransport()
        t.set(GoogleCatalog.catalogURL, catalog([("A", "1"), ("B", "1")]))
        serve(t, "A", fonts: ["A.ttf": "a"])
        serve(t, "B", fonts: ["B.ttf": "b"])
        let gone = fontURL("A", "static/A.ttf")
        t.onRequest = { url in if url == gone { try? FileManager.default.removeItem(at: root) } }
        let dl = downloader(store, root, t)
        _ = try await dl.refreshCatalog()
        let log = EventLog()
        await dl.run { log.append($0) }
        #expect(log.rootUnavailable)
        #expect(log.done.isEmpty && log.failed.isEmpty && !log.finished)
        #expect(!(try status(store)).values.contains { $0.status == 2 })
        #expect(!exists(root))
    }

    @Test func missingRootAtStartIsUnavailable() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        try FileManager.default.removeItem(at: root)
        let store = try makeStore()
        let t = FakeGoogleTransport()
        t.set(GoogleCatalog.catalogURL, catalog([("A", "1")]))
        serve(t, "A", fonts: ["A.ttf": "a"])
        let dl = downloader(store, root, t)
        _ = try await dl.refreshCatalog()
        let log = EventLog()
        await dl.run { log.append($0) }
        #expect(log.events.count == 1 && log.rootUnavailable)
        #expect(try status(store)["A"]?.status == 0)
        #expect(!exists(root))
        #expect(t.requests == [GoogleCatalog.catalogURL])
    }

    @Test func concurrencyCapRespected() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let store = try makeStore()
        let t = FakeGoogleTransport()
        t.fontDelay = .milliseconds(10)
        t.set(GoogleCatalog.catalogURL, catalog([("X", "1")]))
        var fonts: [String: String] = [:]
        for i in 0..<16 { fonts["X-\(i).ttf"] = "\(i)" }
        serve(t, "X", fonts: fonts)
        let dl = downloader(store, root, t)
        _ = try await dl.refreshCatalog()
        await dl.run { _ in }
        #expect(try status(store)["X"]?.status == 1)
        #expect(t.maxInFlight <= 4)
        #expect(t.maxInFlight >= 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("X").path).count == 17)
    }

    @Test func rejectsNonGstaticFontURL() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let store = try makeStore()
        let t = FakeGoogleTransport()
        t.set(GoogleCatalog.catalogURL, catalog([("A", "1"), ("B", "1"), ("C", "1")]))
        let evil = fontURL("A", "A-Bold.ttf", host: "evil.example")
        let good = fontURL("A", "A-Thin.ttf")
        t.set(GoogleCatalog.manifestURL(for: "A"), manifest([("static/A-Thin.ttf", good), ("static/A-Bold.ttf", evil)]))
        let plain = fontURL("B", "B.ttf", scheme: "http")
        t.set(GoogleCatalog.manifestURL(for: "B"), manifest([("static/B.ttf", plain)]))
        serve(t, "C", fonts: ["C.ttf": "c"])
        let dl = downloader(store, root, t)
        _ = try await dl.refreshCatalog()
        let log = EventLog()
        await dl.run { log.append($0) }

        let s = try status(store)
        #expect(s["A"]?.status == 2)
        #expect(s["A"]?.error?.contains("evil.example") == true)
        #expect(s["B"]?.status == 2)
        #expect(s["C"]?.status == 1)
        #expect(!t.requests.contains(evil) && !t.requests.contains(good) && !t.requests.contains(plain))
        #expect(!exists(root.appendingPathComponent("A")) && !exists(root.appendingPathComponent("B")))
        #expect(log.finished)
    }

    @Test func unsafeAndDuplicateNamesStayInsideFamily() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let store = try makeStore()
        let t = FakeGoogleTransport()
        t.set(GoogleCatalog.catalogURL, catalog([("A", "1")]))
        let first = fontURL("A", "one.ttf"), second = fontURL("A", "two.ttf")
        t.set(first, Data("first".utf8))
        t.set(second, Data("second".utf8))
        // Two refs flatten to the same basename (case-insensitive); a text file tries to escape.
        t.set(GoogleCatalog.manifestURL(for: "A"), manifest(
            [("static/A-Bold.ttf", first), ("static/sub/a-bold.ttf", second)],
            files: [("OFL.txt", "ok"), ("..\\\\escape.txt", "bad"), (".hidden.txt", "bad")]))
        let dl = downloader(store, root, t)
        _ = try await dl.refreshCatalog()
        await dl.run { _ in }
        let folder = root.appendingPathComponent("A")
        #expect(try status(store)["A"]?.status == 1)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["A-Bold.ttf", "OFL.txt"])
        #expect(contents(folder.appendingPathComponent("A-Bold.ttf")) == "first")
        #expect(!t.requests.contains(second))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["A"])
    }
}

final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Task<Void, Never>?
    var task: Task<Void, Never>? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
