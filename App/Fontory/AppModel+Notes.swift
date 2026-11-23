import FontoryCore
import Foundation

/// Notes typed on the Info tab: kept per face as they are typed, written 0.5 s after typing stops, and at once when
/// the style changes, the page closes or the app quits. Writes run off the main actor, one after another.
extension AppModel {
    static let noteSaveDelay: Duration = .milliseconds(500)

    /// The note to show for `faceID`: typed and not yet written, else written this session, else `stored`.
    func note(for faceID: Int64, stored: String?) -> String {
        pendingNotes[faceID] ?? savedNotes[faceID] ?? stored ?? ""
    }

    /// A keystroke in the note of `faceID` (the face the editor belongs to). Restarts the 0.5 s save timer.
    func editNote(_ text: String, faceID: Int64) {
        pendingNotes[faceID] = text
        noteSaveTask?.cancel()
        noteSaveTask = Task { [weak self] in
            try? await Task.sleep(for: AppModel.noteSaveDelay)
            guard !Task.isCancelled else { return }
            await self?.flushNotes()
        }
    }

    /// Writes every pending note now (one batch) and waits for it. Nothing pending: waits for earlier writes only.
    func flushNotes() async {
        noteSaveTask?.cancel()
        noteSaveTask = nil
        let notes = pendingNotes
        pendingNotes = [:]
        guard !notes.isEmpty, let backend else {
            await noteWriteChain?.value
            return
        }
        for (id, text) in notes { savedNotes[id] = text }
        noteWriteCount += 1
        let previous = noteWriteChain
        let store = backend.store
        let write = Task { [weak self] in
            await previous?.value
            await self?.runBackground({
                for (id, text) in notes { try store.setNote(text, faceID: id) }
            }, failureTitle: "The note could not be saved")
        }
        noteWriteChain = write
        await write.value
        // Notes are searchable and smart tags can test "Has note".
        await reloadOrganization()
        if query.search != nil || !selectedTagPicks.isEmpty { scheduleRefresh() }
    }
}
