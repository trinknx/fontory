import FontoryCore
import Foundation

/// The toolbar Filters (spec §18 "Filters"): ANDed into the browser's query on every sidebar view, in grid and list
/// mode. Sidebar counts stay unfiltered; the browser and the window subtitle's font count follow. Kept for the session
/// only. Typed characters (the Characters field and the followed preview text) reach the query 150 ms after the last
/// keystroke; every other control applies at once.
extension AppModel {
    static let filterTextDelay: Duration = .milliseconds(150)

    /// The tags offered in the popover's feature menu.
    static let commonFeatureTags: [String] = ["liga", "dlig", "smcp", "c2sc", "onum", "lnum", "tnum", "pnum", "frac", "sups",
                                              "subs", "zero", "salt", "swsh", "calt", "case"]
        + (1...20).map { String(format: "ss%02d", $0) }

    /// A typed feature tag, trimmed, when it is exactly 4 printable ASCII characters without spaces (stored tags are
    /// space-separated, so a tag with a space can never match). Case is kept: tags are case-sensitive.
    static func validFeatureTag(_ text: String) -> String? {
        let tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = tag.unicodeScalars
        guard scalars.count == 4, scalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        return tag
    }

    /// The preview shows typed text with something other than whitespace (not Dynamic, not Font Names).
    var canFollowPreviewText: Bool {
        !preview.showsFontNames && preview.text.unicodeScalars.contains { !$0.properties.isWhitespace }
    }

    /// What the query gets: the controls, with the preview text's characters added while they are followed.
    var effectiveFilters: LibraryFilters {
        var f = filters
        if followsPreviewText && canFollowPreviewText { f.requiredCharacters += preview.text }
        return f
    }

    /// Adds a feature tag (validated); false when it is invalid. A tag already chosen is not added twice.
    @discardableResult
    func addFeatureTag(_ text: String) -> Bool {
        guard let tag = Self.validFeatureTag(text) else { return false }
        if !filters.features.contains(tag) { filters.features.append(tag) }
        return true
    }

    func removeFeatureTag(_ tag: String) {
        filters.features.removeAll { $0 == tag }
    }

    /// Clear All: every control back to Any, the preview text no longer followed; applied at once.
    func clearFilters() {
        filters = LibraryFilters()
        followsPreviewText = false
        applyFilters(debounced: false)
    }

    func filtersDidChange(from old: LibraryFilters) {
        var other = filters
        other.requiredCharacters = old.requiredCharacters
        // Only the Characters field changed: typing, debounced.
        applyFilters(debounced: other == old)
    }

    /// Called from `preview`'s observer.
    func previewDidChangeForFilters(from old: PreviewSettings) {
        guard followsPreviewText, preview.text != old.text || preview.showsFontNames != old.showsFontNames else { return }
        if canFollowPreviewText {
            applyFilters(debounced: true)
        } else {
            // Empty, Dynamic or Font Names: the option turns off (its observer applies at once).
            followsPreviewText = false
        }
    }

    /// Hands `effectiveFilters` to the query, now or 150 ms after the last call. An immediate apply cancels a pending
    /// one (it carries the latest text too).
    func applyFilters(debounced: Bool) {
        filterApplyTask?.cancel()
        filterApplyTask = nil
        guard debounced else {
            query.filters = effectiveFilters
            return
        }
        filterApplyTask = Task { [weak self] in
            try? await Task.sleep(for: AppModel.filterTextDelay)
            guard !Task.isCancelled, let self else { return }
            self.filterApplyTask = nil
            self.query.filters = self.effectiveFilters
        }
    }

    /// The window subtitle: how many fonts the browser shows (filtered), and how many filters are in effect.
    var browserCountText: String {
        guard isReady, detail == nil else { return "" }
        let n = faceIDs.count
        let fonts = n == 1 ? "1 font" : "\(n.formatted()) fonts"
        let active = query.filters.activeCount
        guard active > 0 else { return fonts }
        return fonts + (active == 1 ? " · 1 filter" : " · \(active) filters")
    }
}
