import Foundation

public struct ActivationReport: Sendable {
    public var changedFaceIDs: [Int64] = []
    public var failures: [Int64: String] = [:]
    /// faceID -> PostScript name already active elsewhere.
    public var conflicts: [Int64: String] = [:]
    public init() {}
}

public actor ActivationService {
    private let store: FontStore
    private let registrar: FontRegistrar
    private let now: @Sendable () -> Date

    public init(store: FontStore, registrar: FontRegistrar, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.registrar = registrar
        self.now = now
    }

    public func systemActivePostScriptNames() -> Set<String> { registrar.availablePostScriptNames() }

    // MARK: Public operations

    public func set(_ faceIDs: [Int64], to state: ActivationState, force: Bool = false) async -> ActivationReport {
        var report = ActivationReport()
        do {
            let allIDs = try store.faceIDs(inSameFilesAs: faceIDs)
            let rows = try store.rows(ids: allIDs)
            var order: [Int64] = []
            var byFile: [Int64: [FaceRow]] = [:]
            for id in allIDs {
                guard let row = rows[id] else { continue }
                if byFile[row.fileID] == nil { order.append(row.fileID) }
                byFile[row.fileID, default: []].append(row)
            }

            var targets: [(url: URL, faces: [FaceRow])] = []
            var offline: [FaceRow] = []
            var systemNames: Set<String>?
            var fontoryNames: Set<String> = []
            for fileID in order {
                let faces = byFile[fileID]!
                guard let url = faces[0].fileURL else { offline.append(contentsOf: faces); continue }
                if state != .off, !force {
                    if systemNames == nil {
                        systemNames = registrar.availablePostScriptNames()
                        fontoryNames = try store.activePostScriptNames()
                    }
                    let clashing = faces.filter { systemNames!.contains($0.postScriptName) && !fontoryNames.contains($0.postScriptName) }
                    if !clashing.isEmpty {
                        for f in clashing { report.conflicts[f.id] = f.postScriptName }
                        continue
                    }
                }
                targets.append((url, faces))
            }

            var outcomes: [URL: RegistrationOutcome] = [:]
            if !targets.isEmpty {
                let urls = targets.map(\.url)
                outcomes = state == .off ? await registrar.unregister(urls) : await registrar.register(urls)
            }

            var succeeded = offline.map(\.id)
            for (url, faces) in targets {
                switch outcomes[url] ?? .failed("no result from registrar") {
                case .ok, .alreadyRegistered: succeeded.append(contentsOf: faces.map(\.id))
                case .failed(let message): for f in faces { report.failures[f.id] = message }
                }
            }
            try store.setActivation(faceIDs: succeeded, state: state, at: now())
            report.changedFaceIDs = succeeded
        } catch {
            for id in faceIDs { report.failures[id] = "\(error)" }
        }
        return report
    }

    /// On faces are registered; temporary faces did not survive the previous run, so they go off.
    public func restoreOnLaunch() async -> ActivationReport {
        var report = ActivationReport()
        do {
            let files = try store.activeFiles(states: [.on, .temporary])
            let onFiles = files.filter { $0.online && $0.states.contains(.on) }
            let outcomes = await registrar.register(onFiles.map(\.url))
            for f in onFiles {
                if case .failed(let message) = outcomes[f.url] ?? .ok {
                    for id in f.faceIDs { report.failures[id] = message }
                }
            }
            let temp = files.filter { !$0.states.contains(.on) }
            _ = await registrar.unregister(temp.filter(\.online).map(\.url))
            let tempIDs = files.flatMap { f in f.states.contains(.on) ? [] : f.faceIDs }
            // A file mixing on and temporary faces is registered as a whole: normalise it to on.
            let mixedIDs = files.flatMap { f in f.states.contains(.on) && f.states.contains(.temporary) ? f.faceIDs : [] }
            try store.database.transaction {
                try store.setActivation(faceIDs: tempIDs, state: .off, at: now())
                try store.setActivation(faceIDs: mixedIDs, state: .on, at: now())
            }
            report.changedFaceIDs = tempIDs + mixedIDs
        } catch {
            report.failures[-1] = "\(error)"
        }
        return report
    }

    public func clearTemporary() async -> ActivationReport {
        do {
            return await set(try store.faceIDs(state: .temporary), to: .off)
        } catch {
            var r = ActivationReport()
            r.failures[-1] = "\(error)"
            return r
        }
    }

    public func prepareForQuit() async { _ = await clearTemporary() }

    /// Idempotent: unregistering an unregistered file is treated as success. DB state is kept.
    public func volumeUnmounted(locationIDs: [Int64]) async {
        guard let files = try? store.activeFiles(states: [.on, .temporary], locationIDs: locationIDs) else { return }
        _ = await registrar.unregister(files.map(\.url))
    }

    public func volumeMounted(locationIDs: [Int64]) async -> ActivationReport {
        var report = ActivationReport()
        do {
            let files = try store.activeFiles(states: [.on, .temporary], locationIDs: locationIDs)
            let outcomes = await registrar.register(files.map(\.url))
            for f in files {
                if case .failed(let message) = outcomes[f.url] ?? .ok {
                    for id in f.faceIDs { report.failures[id] = message }
                } else {
                    report.changedFaceIDs.append(contentsOf: f.faceIDs)
                }
            }
        } catch {
            report.failures[-1] = "\(error)"
        }
        return report
    }
}
