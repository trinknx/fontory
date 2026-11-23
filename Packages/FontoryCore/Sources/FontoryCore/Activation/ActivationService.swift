import Foundation
import os

public struct ActivationReport: Sendable {
    public var changedFaceIDs: [Int64] = []
    public var failures: [Int64: String] = [:]
    /// faceID -> PostScript name already active elsewhere (installed outside Fontory, active from another Fontory
    /// file, or claimed by an earlier file of the same request). Collection siblings held back with a
    /// conflicting face carry that face's name.
    public var conflicts: [Int64: String] = [:]
    public init() {}
}

/// Decides whether activating a file would put a second font with an already-active PostScript name on the system.
/// A name is fine when nothing has it, or when it is active only from the same file. It conflicts when another
/// Fontory file has it on or temporary, when an earlier file of the same batch claimed it, or when the system has it
/// from outside Fontory.
private struct ConflictCheck {
    let system: Set<String>
    var activeOwners: [String: Set<Int64>]

    func conflicts(_ face: FaceRow, fileID: Int64) -> Bool {
        let ps = face.postScriptName
        if let owners = activeOwners[ps] { return owners != [fileID] }
        return system.contains(ps)
    }

    func firstConflict(_ faces: [FaceRow], fileID: Int64) -> String? {
        faces.first { conflicts($0, fileID: fileID) }?.postScriptName
    }

    mutating func claim(_ faces: [FaceRow], fileID: Int64) {
        for f in faces { activeOwners[f.postScriptName, default: []].insert(fileID) }
    }
}

public actor ActivationService {
    private static let log = Logger(subsystem: "local.fontory.core", category: "activation")
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
            var check: ConflictCheck?
            for fileID in order {
                let faces = byFile[fileID]!
                guard let url = faces[0].fileURL else { offline.append(contentsOf: faces); continue }
                if state != .off, !force {
                    if check == nil {
                        check = ConflictCheck(system: registrar.availablePostScriptNames(),
                                              activeOwners: try store.activeFileIDsByPostScriptName())
                    }
                    if let name = check!.firstConflict(faces, fileID: fileID) {
                        // Registration is per file: every face of the file is held back, siblings included.
                        for f in faces {
                            report.conflicts[f.id] = check!.conflicts(f, fileID: fileID) ? f.postScriptName : name
                        }
                        continue
                    }
                    check!.claim(faces, fileID: fileID)
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

    /// For a launch without restore: nothing from the previous run is registered, so temporary faces go off
    /// in the DB without touching the registrar. On faces keep their state.
    public func forgetTemporary() -> ActivationReport {
        var report = ActivationReport()
        do {
            let ids = try store.faceIDs(state: .temporary)
            try store.setActivation(faceIDs: ids, state: .off, at: now())
            report.changedFaceIDs = ids
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

    /// After a rescan moved files that had active faces: unregisters each old URL, then registers the files that are
    /// still on or temporary (and online) at their current URL. DB state is kept; failures are reported per face.
    public func filesMoved(_ moves: [MovedFile]) async -> ActivationReport {
        var report = ActivationReport()
        guard !moves.isEmpty else { return report }
        _ = await registrar.unregister(moves.map(\.oldURL))
        do {
            let moved = Set(moves.map(\.fileID))
            let files = try store.activeFiles(states: [.on, .temporary]).filter { moved.contains($0.fileID) && $0.online }
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

    /// After a rescan removed files that had active faces: unregisters them (their index rows are already gone).
    public func filesRemoved(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        _ = await registrar.unregister(urls)
    }

    /// Idempotent: unregistering an unregistered file is treated as success. DB state is kept.
    public func volumeUnmounted(locationIDs: [Int64]) async {
        let files: [ActiveFile]
        do {
            files = try store.activeFiles(states: [.on, .temporary], locationIDs: locationIDs)
        } catch {
            Self.log.error("volumeUnmounted: active files of locations \(locationIDs, privacy: .public) could not be read: \(String(describing: error), privacy: .public)")
            return
        }
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
