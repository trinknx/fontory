import AppKit
import CoreText
import FontoryCore
import Observation
import os

enum ViewMode: String, CaseIterable, Sendable {
    case grid, list
}

/// The family page's tabs. Variables is disabled for styles that are not variable fonts.
enum DetailTab: String, CaseIterable, Sendable {
    case styles, characters, text, features, variables, info

    var title: String {
        switch self {
        case .styles: "Styles"
        case .characters: "Characters"
        case .text: "Text"
        case .features: "Features"
        case .variables: "Variables"
        case .info: "Info"
        }
    }
}

/// The Variables tab's coordinates for one face.
struct VariationState: Equatable, Sendable {
    /// Axis tag code → value, one per axis.
    var values: [UInt32: Double]
    /// `opsz` follows the sample's point size ("Auto (match size)").
    var autoOpticalSize = false
}

/// How the family page lists styles: one big preview per style, or one compact line each.
enum DetailLayout: String, CaseIterable, Sendable {
    case rows, compact
}

/// The family page being shown in place of the browser.
struct FamilyDetail: Equatable, Sendable {
    /// The family as displayed (effective family name).
    var family: String
    /// Its faces in family order.
    var faceIDs: [Int64]
    /// The face the header previews and Info shows while no style is selected.
    var representativeID: Int64
}

/// The Text tab's specimen source: a built-in sample, or the preview text of the browser.
enum TextSample: String, CaseIterable, Sendable {
    case english, vietnamese, previewText

    var title: String {
        switch self {
        case .english: BodyTextSamples.english.name
        case .vietnamese: BodyTextSamples.vietnamese.name
        case .previewText: "Preview Text"
        }
    }
}

/// Alignment of the Text tab's body text; unlike the one-line previews it can justify.
enum BodyTextAlignment: String, CaseIterable, Sendable {
    case left, center, right, justified

    var ctAlignment: CTTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    var title: String {
        switch self {
        case .left: "Align Left"
        case .center: "Align Center"
        case .right: "Align Right"
        case .justified: "Justify"
        }
    }

    var symbol: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify"
        }
    }
}

enum PreviewAlignment: String, CaseIterable, Sendable {
    case left, center, right

    var ctAlignment: CTTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }

    var title: String {
        switch self {
        case .left: "Align Left"
        case .center: "Align Center"
        case .right: "Align Right"
        }
    }

    var symbol: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }
}

/// Everything the preview popover controls, shared by the grid and the list. Persisted in UserDefaults as JSON.
struct PreviewSettings: Equatable {
    /// Custom preview text. Empty means Dynamic: each face shows a sample in a script it covers.
    var text = ""
    var dynamicStyle: PreviewSamples.DynamicStyle = .automatic
    /// Each face previews its own family name (the "Font Names" preset); typing text turns it off.
    var showsFontNames = false
    /// The preset menu item that filled `text` ("sample:…", "language:…", "preset:…"), so only that item is checked
    /// even when another item has the same text. nil for typed text, Dynamic and Font Names.
    var textSource: String?
    var tracking: Double = 0
    var foreground = PreviewSettings.defaultForeground
    var background = PreviewSettings.defaultBackground
    var alignment: PreviewAlignment = .left
    var smoothing = true
    var autoSize = false
    var showGuides = false
    var showMissingGlyphs = false
    var outline = false
    var underline = false
    var ligatures = true
    var discretionaryLigatures = false
    var alternates = false
    var smallCaps = false

    static let defaultForeground = CGColor(gray: 0, alpha: 1)
    static let defaultBackground = CGColor(gray: 1, alpha: 1)

    /// Dark mode's defaults: light text on dark cards.
    static let darkForeground = CGColor(gray: 0.94, alpha: 1)
    static let darkBackground = CGColor(gray: 0.14, alpha: 1)

    static func defaultColors(dark: Bool) -> (foreground: CGColor, background: CGColor) {
        dark ? (darkForeground, darkBackground) : (defaultForeground, defaultBackground)
    }

    private func hasColors(_ colors: (foreground: CGColor, background: CGColor)) -> Bool {
        PreviewRequest.components(foreground) == PreviewRequest.components(colors.foreground)
            && PreviewRequest.components(background) == PreviewRequest.components(colors.background)
    }

    /// The colors are the default pair of either appearance (not ones the user picked).
    var hasDefaultColors: Bool {
        hasColors(Self.defaultColors(dark: false)) || hasColors(Self.defaultColors(dark: true))
    }

    /// Default colors follow the appearance; colors the user picked are kept.
    mutating func adaptDefaultColors(dark: Bool) {
        guard hasDefaultColors, !hasColors(Self.defaultColors(dark: dark)) else { return }
        (foreground, background) = Self.defaultColors(dark: dark)
    }

    var isDynamic: Bool { !showsFontNames && text.isEmpty }

    var features: PreviewFeatures {
        var f: PreviewFeatures = []
        if ligatures { f.insert(.ligatures) }
        if discretionaryLigatures { f.insert(.discretionaryLigatures) }
        if alternates { f.insert(.alternates) }
        if smallCaps { f.insert(.smallCaps) }
        return f
    }

    /// The text a face previews: its family name with Font Names, the typed text when there is any, otherwise
    /// the dynamic sample for the scripts it covers.
    func text(for row: FaceRow) -> String {
        if showsFontNames { return row.family.isEmpty ? row.fullName : row.family }
        if text.isEmpty { return PreviewSamples.dynamicText(scriptsBitmask: row.scriptsBitmask, style: dynamicStyle) }
        return text
    }

    /// The template request for a preview of `size`; per-face text is filled in by the views.
    func request(pointSize: CGFloat, size: CGSize, scale: CGFloat) -> PreviewRequest {
        var request = PreviewRequest(
            text: text,
            pointSize: pointSize,
            tracking: CGFloat(tracking),
            foreground: foreground, background: background,
            alignment: alignment.ctAlignment, smoothing: smoothing,
            size: size, scale: scale)
        request.showGuides = showGuides
        request.showMissingGlyphs = showMissingGlyphs
        request.outline = outline
        request.underline = underline
        request.features = features
        return request
    }
}

extension PreviewSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, dynamicStyle, showsFontNames, textSource, tracking, foreground, background, alignment
        case smoothing, autoSize, showGuides, showMissingGlyphs, outline, underline, ligatures
        case discretionaryLigatures, alternates, smallCaps
    }

    /// Missing or unreadable keys keep their defaults, so settings written by other versions still load.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, into value: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        read(.text, into: &text)
        read(.dynamicStyle, into: &dynamicStyle)
        read(.showsFontNames, into: &showsFontNames)
        textSource = (try? c.decodeIfPresent(String.self, forKey: .textSource)) ?? nil
        read(.tracking, into: &tracking)
        if let rgba = try? c.decodeIfPresent([CGFloat].self, forKey: .foreground), rgba.count == 4 {
            foreground = CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }
        if let rgba = try? c.decodeIfPresent([CGFloat].self, forKey: .background), rgba.count == 4 {
            background = CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }
        if let raw = try? c.decodeIfPresent(String.self, forKey: .alignment), let a = PreviewAlignment(rawValue: raw) {
            alignment = a
        }
        read(.smoothing, into: &smoothing)
        read(.autoSize, into: &autoSize)
        read(.showGuides, into: &showGuides)
        read(.showMissingGlyphs, into: &showMissingGlyphs)
        read(.outline, into: &outline)
        read(.underline, into: &underline)
        read(.ligatures, into: &ligatures)
        read(.discretionaryLigatures, into: &discretionaryLigatures)
        read(.alternates, into: &alternates)
        read(.smallCaps, into: &smallCaps)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(dynamicStyle, forKey: .dynamicStyle)
        try c.encode(showsFontNames, forKey: .showsFontNames)
        try c.encodeIfPresent(textSource, forKey: .textSource)
        try c.encode(tracking, forKey: .tracking)
        try c.encode(Self.rgba(foreground), forKey: .foreground)
        try c.encode(Self.rgba(background), forKey: .background)
        try c.encode(alignment.rawValue, forKey: .alignment)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(autoSize, forKey: .autoSize)
        try c.encode(showGuides, forKey: .showGuides)
        try c.encode(showMissingGlyphs, forKey: .showMissingGlyphs)
        try c.encode(outline, forKey: .outline)
        try c.encode(underline, forKey: .underline)
        try c.encode(ligatures, forKey: .ligatures)
        try c.encode(discretionaryLigatures, forKey: .discretionaryLigatures)
        try c.encode(alternates, forKey: .alternates)
        try c.encode(smallCaps, forKey: .smallCaps)
    }

    private static func rgba(_ color: CGColor) -> [CGFloat] {
        let c = PreviewRequest.components(color)
        switch c.count {
        case 4: return c
        case 2: return [c[0], c[0], c[0], c[1]]   // gray + alpha
        default: return [0, 0, 0, 1]
        }
    }

    static let defaultsKey = "previewSettings"

    static func load(from defaults: UserDefaults = .standard) -> PreviewSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(PreviewSettings.self, from: data) else { return PreviewSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var actionTitle: String?
    var isDestructive = false
    var action: (@MainActor () -> Void)?
}

enum SettingsKey {
    static let keepRunningInMenuBar = "keepRunningInMenuBar"
    static let showSystemFonts = "showSystemFonts"
    static let detailPointSize = "detail.pointSize"
    static let detailLayout = "detail.layout"
    static let glyphCellSize = "detail.glyphCellSize"
    static let glyphOrder = "detail.glyphOrder"
    static let textSample = "detail.text.sample"
    static let textCustom = "detail.text.custom"
    static let textColumns = "detail.text.columns"
    static let textAlignment = "detail.text.alignment"
    static let textPointSize = "detail.text.pointSize"
    static let textLineHeight = "detail.text.lineHeight"
    /// Settings → Duplicates: location ids, highest rank first ("Select Copies to Remove" keeps the higher one).
    static let duplicateLocationRank = "duplicates.locationRank"
    /// Settings → Duplicates: "Skip duplicates on import" (default off).
    static let skipDuplicatesOnImport = "duplicates.skipOnImport"
    /// Google Fonts: the user consented to the download (Settings → "Stop Syncing" clears it).
    static let googleFontsEnabled = "googleFonts.enabled"
    /// Google Fonts: the last successful catalogue check (Date); launch checks at most once per 24 h.
    static let googleFontsLastCheck = "googleFonts.lastCheck"
    /// Google Fonts: downloads paused by the user.
    static let googleFontsPaused = "googleFonts.paused"

    static func register() {
        UserDefaults.standard.register(defaults: [
            keepRunningInMenuBar: true, showSystemFonts: true,
            "zoom.grid": 0.25, "zoom.list": 0.25,
            detailPointSize: AppModel.defaultDetailPointSize, detailLayout: DetailLayout.rows.rawValue,
            glyphCellSize: AppModel.defaultGlyphCellSize, glyphOrder: GlyphOrder.unicode.rawValue,
            textSample: TextSample.english.rawValue, textColumns: 1, textAlignment: BodyTextAlignment.left.rawValue,
            textPointSize: AppModel.defaultTextPointSize, textLineHeight: AppModel.defaultTextLineHeight,
            skipDuplicatesOnImport: false,
        ])
        // Activation is always restored at launch now; drop the old "restore on launch" switch.
        UserDefaults.standard.removeObject(forKey: "restoreOnLaunch")
    }
}

/// Main-actor façade over the core services. All database, scanning and activation work runs off the main
/// actor (detached tasks or the core actors); this type only publishes results.
@Observable @MainActor
final class AppModel {
    private static let log = Logger(subsystem: "local.fontory.app", category: "model")
    private static let refreshDelay: Duration = .milliseconds(80)
    private static let folderEventDelay: Duration = .seconds(5)
    /// Registered-fonts notifications come in bursts (one per registration batch, from any process).
    private static let inventoryDelay: Duration = .seconds(1)
    /// Fallback re-read of the registered fonts while the app runs (in menu-bar-only mode the app is never
    /// activated, and other apps' changes might not be announced).
    private static let inventoryInterval: Duration = .seconds(60)

    // MARK: Browsing state

    var query: LibraryQuery {
        didSet {
            guard query != oldValue else { return }
            // Searching, choosing another view or sorting leaves the family page for the browser. A filters-only
            // change does not (the preview text it may follow can be edited on the family page).
            var unfiltered = query
            unfiltered.filters = oldValue.filters
            if detail != nil && unfiltered != oldValue { closeFamilyDetail() }
            // The Duplicates view follows Show System Fonts (it searches again); anything else leaves it.
            var browsing = unfiltered
            browsing.includeSystem = oldValue.includeSystem
            if isShowingDuplicates && browsing != oldValue { closeDuplicates() }
            if query.includeSystem != oldValue.includeSystem {
                UserDefaults.standard.set(query.includeSystem, forKey: SettingsKey.showSystemFonts)
                refreshCounts()
                startDuplicateSearch(hashing: false)
            }
            scheduleRefresh()
        }
    }
    var searchText = "" { didSet { if searchText != oldValue { updateSearch() } } }
    var searchScope: Set<SearchText.Field> = Set(SearchText.Field.allCases) { didSet { if searchScope != oldValue { updateSearch() } } }
    var viewMode: ViewMode = .grid {
        didSet {
            guard viewMode != oldValue else { return }
            if detail != nil { closeFamilyDetail() }
            UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode")
        }
    }
    var zoom: [ViewMode: Double] {
        didSet { for mode in ViewMode.allCases { UserDefaults.standard.set(zoom[mode], forKey: "zoom.\(mode.rawValue)") } }
    }
    var preview = PreviewSettings() {
        didSet {
            // Before the color adaptation below, which re-enters this observer with the text already changed.
            previewDidChangeForFilters(from: oldValue)
            // Default colors follow the appearance (e.g. a preset saved in the other one). With @Observable,
            // assigning here runs this observer again, so assign only when something changes: it settles in one step.
            var adapted = preview
            adapted.adaptDefaultColors(dark: isDarkAppearance)
            if adapted != preview { preview = adapted; return }
            if preview != oldValue { schedulePreviewSave() }
        }
    }
    /// Set by the main window from its color scheme; default preview colors follow it.
    var isDarkAppearance = false {
        didSet {
            guard isDarkAppearance != oldValue else { return }
            var adapted = preview
            adapted.adaptDefaultColors(dark: isDarkAppearance)
            if adapted != preview { preview = adapted }
        }
    }
    /// Pending debounced write of `preview` (slider drags and typing change it many times a second).
    @ObservationIgnored private var previewSaveTask: Task<Void, Never>?
    /// Drives the preview popover (toolbar button and View ▸ Preview Options).
    var isShowingPreviewOptions = false
    /// Run once after the preview popover has closed (e.g. to present the preset name prompt).
    @ObservationIgnored var afterPreviewOptionsClose: (@MainActor () -> Void)?
    private(set) var presets: [Preset] = []
    /// Drives the "save preset" name prompt.
    var isNamingPreset = false

    // MARK: Filters (AppModel+Filters.swift)

    /// The Filters popover's controls; `requiredCharacters` is its Characters field. Session only, never persisted.
    /// The query gets `effectiveFilters` (these plus the preview text while it is followed).
    var filters = LibraryFilters() { didSet { if filters != oldValue { filtersDidChange(from: oldValue) } } }
    /// "Supports the preview text": the preview text's characters are required too, following it as it changes.
    var followsPreviewText = false { didSet { if followsPreviewText != oldValue { applyFilters(debounced: false) } } }
    /// Drives the Filters popover (toolbar button).
    var isShowingFilters = false
    /// Pending debounced hand-over of typed characters to `query.filters`.
    @ObservationIgnored var filterApplyTask: Task<Void, Never>?

    // MARK: Results

    /// Matching faces in sort order. Refreshed off-main, debounced 80 ms after any query change.
    private(set) var faceIDs: [Int64] = []
    private(set) var counts = LibraryCounts()
    /// Bumped whenever cached rows change (activation, rescans), so views reading `row(_:)` update.
    private(set) var rowsVersion = 0
    var selection: Set<Int64> = []

    // MARK: Family page

    /// The family page shown in place of the browser; nil shows the browser (kept alive underneath, so its scroll
    /// position and selection survive).
    private(set) var detail: FamilyDetail?
    var detailTab: DetailTab = .styles
    /// Selected styles on the family page (independent of the browser's selection).
    var detailSelection: Set<Int64> = []
    var detailLayout: DetailLayout {
        didSet { if detailLayout != oldValue { UserDefaults.standard.set(detailLayout.rawValue, forKey: SettingsKey.detailLayout) } }
    }
    /// Preview size of the family page's styles, in points (its own slider; persisted).
    var detailPointSize: Double {
        didSet { if detailPointSize != oldValue { UserDefaults.standard.set(detailPointSize, forKey: SettingsKey.detailPointSize) } }
    }
    nonisolated static let defaultDetailPointSize = 48.0
    /// The Variables tab's axis coordinates by face, for this session (not persisted).
    var variationStates: [Int64: VariationState] = [:]
    /// The Variables tab lists the axes a font marks hidden (session only).
    var showsHiddenAxes = false
    /// Point size of the Variables tab's sample (session only); an automatic optical size follows it.
    var variationSamplePointSize = 48.0
    nonisolated static let variationSamplePointSizeRange: ClosedRange<Double> = 12...144
    nonisolated static let detailPointSizeRange: ClosedRange<Double> = 8...200
    @ObservationIgnored private var detailGeneration = 0
    /// A family edit is moving the page to the family's new name: a refresh's `reloadDetail`, which looks the page
    /// up by its old name, must not close it meanwhile.
    @ObservationIgnored private var detailFollowingEdit = 0

    // MARK: Family Editor (see AppModel+FamilyEditor.swift)

    /// Edited families: family key → the original family names of its faces with a custom name (the pencil mark).
    var editedFamilies: [String: [String]] = [:]
    /// The previous `custom_family` of the faces changed by the last family edit (one level of undo, in memory).
    var familyUndo: [Int64: String?]?
    /// The rename / merge / split sheet.
    var familyNameRequest: FamilyNameRequest?

    // MARK: Characters tab

    /// Side of a glyph cell in points (its own slider; persisted).
    var glyphCellSize: Double {
        didSet { if glyphCellSize != oldValue { UserDefaults.standard.set(glyphCellSize, forKey: SettingsKey.glyphCellSize) } }
    }
    nonisolated static let defaultGlyphCellSize = 72.0
    nonisolated static let glyphCellSizeRange: ClosedRange<Double> = 40...200
    var glyphFilter: GlyphFilter = .all
    var glyphSearch = ""
    var glyphOrder: GlyphOrder {
        didSet { if glyphOrder != oldValue { UserDefaults.standard.set(glyphOrder.rawValue, forKey: SettingsKey.glyphOrder) } }
    }
    /// Bumped when rescans may have changed font files, so the Characters tab lists its face again.
    private(set) var glyphsVersion = 0
    /// Inventories of the recently shown faces, computed off the main actor.
    @ObservationIgnored let glyphInventories = GlyphInventoryCache()
    /// Renders and caches the glyph cells.
    @ObservationIgnored let glyphPipeline: GlyphPipeline

    // MARK: Text tab

    /// The built-in sample the specimen shows while the text has not been edited (persisted).
    var textSample: TextSample {
        didSet { if textSample != oldValue { UserDefaults.standard.set(textSample.rawValue, forKey: SettingsKey.textSample) } }
    }
    /// The edited specimen text, app-wide (not per font); nil shows `textSample`. Persisted.
    var textCustom: String? {
        didSet {
            guard textCustom != oldValue else { return }
            if let textCustom { UserDefaults.standard.set(textCustom, forKey: SettingsKey.textCustom) }
            else { UserDefaults.standard.removeObject(forKey: SettingsKey.textCustom) }
        }
    }
    var textColumns: Int {
        didSet { if textColumns != oldValue { UserDefaults.standard.set(textColumns, forKey: SettingsKey.textColumns) } }
    }
    var textAlignment: BodyTextAlignment {
        didSet { if textAlignment != oldValue { UserDefaults.standard.set(textAlignment.rawValue, forKey: SettingsKey.textAlignment) } }
    }
    /// Body size of the specimen, independent of the header and Styles sizes.
    var textPointSize: Double {
        didSet { if textPointSize != oldValue { UserDefaults.standard.set(textPointSize, forKey: SettingsKey.textPointSize) } }
    }
    /// Baseline-to-baseline distance as a multiple of the point size.
    var textLineHeight: Double {
        didSet { if textLineHeight != oldValue { UserDefaults.standard.set(textLineHeight, forKey: SettingsKey.textLineHeight) } }
    }
    /// Longest specimen text the editor accepts (UTF-16 units): long enough for any specimen, short enough to lay
    /// out quickly.
    nonisolated static let maxTextLength = 50_000
    nonisolated static let defaultTextPointSize = 18.0
    nonisolated static let textPointSizeRange: ClosedRange<Double> = 9...72
    nonisolated static let defaultTextLineHeight = 1.4
    nonisolated static let textLineHeightRange: ClosedRange<Double> = 0.9...2.5

    /// The text of a sample; Preview Text uses the browser's typed text, or what `row` previews.
    func text(of sample: TextSample, row: FaceRow?) -> String {
        switch sample {
        case .english: return BodyTextSamples.english.text
        case .vietnamese: return BodyTextSamples.vietnamese.text
        case .previewText:
            if let row { return preview.text(for: row) }
            return preview.text.isEmpty ? PreviewSamples.dynamicText(scriptsBitmask: 1, style: preview.dynamicStyle) : preview.text
        }
    }

    /// Chooses a sample; another sample replaces any edited text, the current one keeps it (Reset Text restores it).
    func chooseTextSample(_ sample: TextSample) {
        guard sample != textSample else { return }
        textSample = sample
        textCustom = nil
    }

    // MARK: Locations

    private(set) var locations: [LocationRecord] = []
    /// Google Fonts download and sync, created once the library is open (the smoke run sets its own).
    var google: GoogleFontsController?
    var scanProgress: [Int64: ScanProgress] = [:]
    /// Per location: faces with activation, tags or notes that scans removed because their files are gone (or that
    /// Duplicates removed from the library or moved to the Trash), accumulated
    /// until the user dismisses the notice (so a later clean rescan does not hide it).
    var removalNotices: [Int64: Int] = [:]
    var alert: AlertItem?
    private(set) var isReady = false

    // MARK: Tags (actions in AppModel+Tags.swift)

    /// Every tag, plain and smart, in id order (the sidebar builds the tree).
    var tags: [TagRecord] = []
    var organizationCounts = OrganizationCounts()
    /// Smart-tag row counts (`OrganizationCounts.perTag` covers plain tags only).
    var smartTagCounts: [Int64: Int] = [:]
    /// The tag whose sidebar row shows an inline name field.
    var renamingTagID: Int64?
    /// Expanded tag rows in the sidebar tree.
    var expandedTagIDs: Set<Int64> = []
    /// GSUB feature tags whose rules are expanded in the Features tab; kept for the session (across faces and tab
    /// switches), not saved across launches.
    var expandedRuleFeatures: Set<String> = []
    /// The smart tag editor sheet's draft, while it is shown (see `SmartTagEditor`).
    var smartTagEditor: SmartTagEditorState?
    /// Organization reloads (see `reloadOrganization`): the one running, the merged kind of the pending one,
    /// the last request number and the last request number a finished run covers.
    @ObservationIgnored var organizationReloadTask: Task<Void, Never>?
    @ObservationIgnored var organizationReloadPending: OrganizationReload?
    @ObservationIgnored var organizationRequested = 0
    @ObservationIgnored var organizationApplied = 0
    /// Organization reload runs so far (smoke hook).
    @ObservationIgnored var organizationReloadRuns = 0
    /// Bumped by every tag-store write made here; a reload snapshot read before the latest one keeps `tags` as is.
    @ObservationIgnored var tagWriteEpoch = 0
    /// The last ⌥-click applied to a tag row, to apply each click once (see `optionClickTag`).
    @ObservationIgnored var lastOptionClick: (tagID: Int64, time: TimeInterval)?
    /// Bumped after every tag change (assignments included), so views showing a face's tags reload them.
    var tagAssignmentVersion = 0
    /// The ⌘T tag panel, when shown.
    var tagPanel: TagPanelRequest?

    // MARK: Quick Collection and face backfill (actions in AppModel+QuickCollection.swift)

    /// Faces in the Quick Collection, loaded off the main actor at launch and kept in step with every write (set
    /// at once by the actions, then confirmed from the store). Grid cells read it when configured.
    var quickCollectionIDs: Set<Int64> = []
    /// Bumped by every Quick Collection change made here; a store read started before a newer change is dropped.
    @ObservationIgnored var quickCollectionGeneration = 0
    /// The last Quick Collection write; each write waits for the previous one, so they land in order.
    @ObservationIgnored var quickCollectionWriteChain: Task<Void, Never>?
    /// Writes started and not yet confirmed (smoke hook).
    @ObservationIgnored var quickCollectionWritesPending = 0
    /// The running face backfill's progress (style class and v4 metadata); nil when none runs or it has nothing to do.
    var faceBackfillProgress: BackfillProgress?
    /// The running backfill (at most one); it clears itself when it ends.
    @ObservationIgnored var faceBackfillTask: Task<Void, Never>?
    /// A start was asked for while a run was going: run again once it ends.
    @ObservationIgnored var faceBackfillRerun = false
    /// Unmounts being handled (from the first event until their locations are marked offline): no run starts
    /// meanwhile, the store still lists the volume online. The handler starts it when the last one is done.
    @ObservationIgnored var unmountsInProgress = 0
    /// Set when quitting: no new runs.
    @ObservationIgnored var faceBackfillStopped = false
    /// Runs started, and the most that ever ran at once (smoke checks of the coalescing).
    @ObservationIgnored var faceBackfillRuns = 0
    @ObservationIgnored var faceBackfillRunning = 0
    @ObservationIgnored var faceBackfillMaxRunning = 0
    /// Throttle of the Style counts reload while a backfill runs.
    @ObservationIgnored var styleCountsReloadTask: Task<Void, Never>?
    @ObservationIgnored var lastStyleCountsReload: ContinuousClock.Instant?

    // MARK: Duplicates (actions in AppModel+Duplicates.swift)

    /// The Duplicates view is shown in place of the browser (Library → Duplicates).
    var isShowingDuplicates = false
    /// Exact groups first, then same-font groups (`DuplicateFinder.groups`), from the last search.
    var duplicateGroups: [DuplicateGroup] = []
    /// Every face of the listed files, by face id (rows of the view and the keep policy).
    var duplicateRows: [Int64: FaceRow] = [:]
    /// The listed files, by file id (size, format, date added).
    var duplicateFiles: [Int64: FileRecord] = [:]
    /// `duplicateRows` by file (protection and activation are per file).
    var duplicateFacesByFile: [Int64: [FaceRow]] = [:]
    /// Files checked for removal. Protected files (system, user-installed, active outside Fontory) never are.
    var checkedDuplicateFiles: Set<Int64> = []
    /// Hashing progress while a search hashes candidate files.
    var duplicateProgress: BackfillProgress?
    /// A search (hashing, then grouping) is running, or waits for the face backfill.
    var isFindingDuplicates = false
    /// A hashing search waits for the face backfill to be idle ("Waiting for font details…").
    var isWaitingForFaceBackfill = false
    /// Remove from Library or Move to Trash is running.
    var isRemovingDuplicates = false
    /// Settings → Duplicates: excluded files (removed from the library, skipped by rescans).
    var excludedFiles: [ExcludedFile] = []
    /// Settings → Duplicates: location ids, highest rank first. Persisted in `settingsDefaults`.
    var duplicateLocationRank: [Int64] {
        didSet {
            if duplicateLocationRank != oldValue {
                settingsDefaults.set(duplicateLocationRank.map { NSNumber(value: $0) }, forKey: SettingsKey.duplicateLocationRank)
            }
        }
    }
    /// Settings → Duplicates: "Skip duplicates on import". Persisted in `settingsDefaults`, handed to the scanner.
    var skipDuplicatesOnImport: Bool {
        didSet {
            guard skipDuplicatesOnImport != oldValue else { return }
            settingsDefaults.set(skipDuplicatesOnImport, forKey: SettingsKey.skipDuplicatesOnImport)
            let skip = skipDuplicatesOnImport
            if let scanner = backend?.scanner { Task { await scanner.setSkipFingerprintDuplicates(skip) } }
        }
    }
    /// Where the Duplicates settings are written (the smoke run uses its own suite).
    @ObservationIgnored var settingsDefaults: UserDefaults = .standard
    /// The running search (at most one); it clears itself when it ends.
    @ObservationIgnored var duplicateTask: Task<Void, Never>?
    /// A start asked for while a search ran (or an unmount was handled): run again afterwards; true when it must hash.
    @ObservationIgnored var duplicateRerun: Bool?
    /// Set when quitting: no new searches.
    @ObservationIgnored var duplicateSearchStopped = false
    /// Searches started, and searches that ended cancelled (smoke checks).
    @ObservationIgnored var duplicateRuns = 0
    @ObservationIgnored var duplicateRunsCancelled = 0
    /// The last Move to Trash: per-file failures (file id → message) and the files recycled (smoke checks).
    @ObservationIgnored var lastTrashResult: TrashResult?
    /// Moves one file to the Trash (Move to Trash…): its new URL, or an error message. The smoke run replaces it.
    @ObservationIgnored var recycleFile: @MainActor (URL) async -> (trashedURL: URL?, error: String?) = { await AppModel.workspaceRecycle($0) }

    // MARK: Notes (actions in AppModel+Notes.swift)

    /// Typed notes not yet written, by face.
    @ObservationIgnored var pendingNotes: [Int64: String] = [:]
    /// Notes written (or being written) this session, by face: newer than a `FaceInfo` read before the write.
    @ObservationIgnored var savedNotes: [Int64: String] = [:]
    /// The debounced save of `pendingNotes`.
    @ObservationIgnored var noteSaveTask: Task<Void, Never>?
    /// The last note write; each write waits for the previous one, so they land in order.
    @ObservationIgnored var noteWriteChain: Task<Void, Never>?
    /// Note write batches started (for the smoke check of the debounce).
    @ObservationIgnored var noteWriteCount = 0

    // MARK: Export (actions in AppModel+Export.swift)

    /// The running export's progress, set only for a large export (more than 50 files); `ExportSheet` shows it.
    var exportProgress: (done: Int, total: Int)?
    @ObservationIgnored var exportCancel = ExportCancelFlag()
    /// The last export's outcome (the smoke run reads it).
    @ObservationIgnored var lastExportResult: ExportResult?
    /// Smoke seams: the destination folder and options that replace the folder panel and offline question.
    @ObservationIgnored var exportDestinationOverride: URL?
    /// Smoke seam: answers the offline question (given the offline count) instead of the dialog.
    @ObservationIgnored var exportOfflineAnswer: ((Int) -> Bool)?
    @ObservationIgnored var exportOptionsOverride: (byFamily: Bool, zip: Bool)?

    // MARK: Backups (actions in AppModel+Backup.swift)

    /// Where automatic and safety backups go: `~/Library/Application Support/Fontory/Backups` (the path only; it is
    /// created on the first write). The smoke run points it at its temporary directory.
    @ObservationIgnored var backupDirectory: URL = AppModel.defaultBackupDirectory()
    /// The backups in `backupDirectory`, newest first (Settings → Backups).
    var backupEntries: [BackupFiles.Entry] = []
    /// The running restore's progress; nil when none is shown.
    var restoreState: RestoreState?
    /// Settings → Backups: "Also restore activation" (session only, default off).
    var restoreActivation = false
    /// The Settings tab shown (File ▸ Restore Library… opens Backups).
    var settingsTab: SettingsTab = .general
    /// The running restore, and whether Cancel (or quitting) asked it to stop before applying.
    @ObservationIgnored var restoreTask: Task<Void, Never>?
    @ObservationIgnored var restoreCancelled = false
    #if DEBUG
    /// Set by the smoke run: the restore stays in `.scanning` until it is cancelled or this is cleared.
    @ObservationIgnored var holdsRestoreScanForSmoke = false
    #endif

    // MARK: Layouts

    /// The Layouts window's model. Its folders are fixed at init (the smoke run passes temporary ones).
    let layouts: LayoutsModel

    /// What ⌘K adds as candidates: the family page's family, else the selection (in browser order), else the
    /// Quick Collection.
    var layoutsSourceFaceIDs: [Int64] {
        if let detail { return detail.faceIDs }
        if !selection.isEmpty { return selectionInBrowserOrder }
        return quickCollectionIDs.sorted()
    }

    /// The selected faces in browser order (any not listed, such as filtered out meanwhile, follow sorted).
    private var selectionInBrowserOrder: [Int64] {
        var ordered = faceIDs.filter(selection.contains)
        if ordered.count < selection.count {
            let listed = Set(ordered)
            ordered += selection.filter { !listed.contains($0) }.sorted()
        }
        return ordered
    }

    // MARK: Compare

    /// The Compare window's model (remembered settings in `UserDefaults.standard`).
    let compare = CompareModel()

    /// What ⌥⌘K compares. An open family page wins over any browser selection: A is the style being viewed (the
    /// single face selected on the page, else the family's representative) against the Quick Collection's other
    /// families. Otherwise 2+ selected faces (browser order) → the first against the rest; one selected face
    /// against the Quick Collection's other families; else the Quick Collection's first face against the rest.
    var compareSource: (reference: Int64?, candidates: [Int64]) {
        let quick = quickCollectionIDs.sorted()
        // An open family page wins over any browser selection (as in `layoutsSourceFaceIDs`).
        if selection.count >= 2, detail == nil {
            let ordered = selectionInBrowserOrder
            return (ordered.first, Array(ordered.dropFirst()))
        }
        let single: Int64? = if let detail {
            detailSelection.count == 1 ? detailSelection.first : detail.representativeID
        } else {
            selection.first
        }
        if let single {
            var others = quick.filter { $0 != single }
            if let store = backend?.store, !others.isEmpty,
               let rows = try? store.rows(ids: others + [single]), let family = rows[single]?.family.lowercased() {
                others = others.filter { rows[$0]?.family.lowercased() != family }
            }
            return (single, others)
        }
        if let first = quick.first { return (first, Array(quick.dropFirst())) }
        return (nil, [])
    }

    /// ⌥⌘K (the caller opens or focuses the Compare window).
    func openInCompare() async {
        let source = compareSource
        await compare.open(referenceFaceID: source.reference, candidateFaceIDs: source.candidates)
    }

    /// ⌘K (the caller opens or focuses the Layouts window): with no layout open, a new one from Poster first; then
    /// the source's families become the layout's candidates, or are appended to them. Presses run one after
    /// another: a second ⌘K while the first is still creating the Poster waits for it, then appends to it.
    func openInLayouts() async {
        let ids = layoutsSourceFaceIDs
        let previous = openInLayoutsChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performOpenInLayouts(ids)
        }
        openInLayoutsChain = task
        await task.value
        if openInLayoutsChain == task { openInLayoutsChain = nil }
    }

    private func performOpenInLayouts(_ ids: [Int64]) async {
        if layouts.current == nil {
            if layouts.templates.isEmpty { await layouts.reloadLists() }
            let usable = layouts.templates.filter { $0.error == nil }
            guard let poster = usable.first(where: { $0.name == "Poster" }) ?? usable.first else {
                layouts.errorMessage = "No layout template is available to start from."
                return
            }
            await layouts.newLayout(from: poster.url)
            guard layouts.current != nil else { return }
        }
        await layouts.addCandidates(faceIDs: ids)
    }

    // MARK: Private

    @ObservationIgnored private(set) var backend: LibraryBackend?
    /// The ⌘K in progress; the next one waits for it (see `openInLayouts`).
    @ObservationIgnored private var openInLayoutsChain: Task<Void, Never>?
    @ObservationIgnored private var presetStore: PresetStore?
    @ObservationIgnored private let rowCache = LRUCache<Int64, FaceRow>(limit: 4000)
    /// Ids whose rows are being fetched by `prefetchRows`.
    @ObservationIgnored private var pendingRowIDs: Set<Int64> = []
    /// Shared by every preview in the app; it caches parsed fonts.
    @ObservationIgnored let previewRenderer: PreviewRenderer
    /// The render queue and image cache shared by the grid and the list.
    @ObservationIgnored let previewPipeline: PreviewPipeline
    /// The main browser window, recorded by `MainWindow`; app-wide shortcuts act only while it is key.
    @ObservationIgnored weak var browserWindow: NSWindow?
    /// The browser window is the key window (app-wide shortcuts act only then).
    var browserIsKey: Bool { browserWindow != nil && NSApp.keyWindow === browserWindow }
    /// Observable copy of `browserIsKey`, kept by `MainWindow`, so menu items can enable themselves.
    var isBrowserKey = false
    @ObservationIgnored private var indexByID: [Int64: Int] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    @ObservationIgnored private var scanTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchers: [Int64: FolderWatcher] = [:]
    @ObservationIgnored private var folderEventTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var inventoryTask: Task<Void, Never>?
    @ObservationIgnored private var inventoryObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var inventoryTimer: Task<Void, Never>?
    /// Identifies the run in `scanTasks[id]`, so a finished run clears its entry only if no newer one replaced it.
    @ObservationIgnored private var scanTokens: [Int64: UInt64] = [:]
    @ObservationIgnored private var nextScanToken: UInt64 = 0
    /// Registered files inside scanned locations for which a rescan was already started (rescanned once, so a file
    /// the scan cannot read does not loop).
    @ObservationIgnored private var requestedPendingPaths: Set<String> = []
    @ObservationIgnored private var started = false
    #if DEBUG
    /// Set by the smoke run: preview changes are not written to the user's defaults.
    @ObservationIgnored var suppressesPreviewSaveForSmoke = false
    #endif

    /// `layoutsDirectory` and `templatesDirectory` default to `Layouts/` and `Templates/` in
    /// `~/Library/Application Support/Fontory`; the smoke run passes temporary folders.
    init(layoutsDirectory: URL? = nil, templatesDirectory: URL? = nil) {
        layouts = LayoutsModel(layoutsDirectory: layoutsDirectory ?? LayoutsModel.defaultDirectory("Layouts"),
                               templatesDirectory: templatesDirectory ?? LayoutsModel.defaultDirectory("Templates"))
        SettingsKey.register()
        let renderer = PreviewRenderer()
        previewRenderer = renderer
        previewPipeline = PreviewPipeline(renderer: renderer)
        glyphPipeline = GlyphPipeline(renderer: renderer)
        let defaults = UserDefaults.standard
        query = LibraryQuery(includeSystem: defaults.bool(forKey: SettingsKey.showSystemFonts))
        zoom = [.grid: defaults.double(forKey: "zoom.grid"), .list: defaults.double(forKey: "zoom.list")]
        viewMode = defaults.string(forKey: "viewMode").flatMap(ViewMode.init(rawValue:)) ?? .grid
        preview = PreviewSettings.load(from: defaults)
        detailLayout = defaults.string(forKey: SettingsKey.detailLayout).flatMap(DetailLayout.init(rawValue:)) ?? .rows
        let size = defaults.double(forKey: SettingsKey.detailPointSize)
        detailPointSize = Self.detailPointSizeRange.contains(size) ? size : Self.defaultDetailPointSize
        let cell = defaults.double(forKey: SettingsKey.glyphCellSize)
        glyphCellSize = Self.glyphCellSizeRange.contains(cell) ? cell : Self.defaultGlyphCellSize
        glyphOrder = defaults.string(forKey: SettingsKey.glyphOrder).flatMap(GlyphOrder.init(rawValue:)) ?? .unicode
        textSample = defaults.string(forKey: SettingsKey.textSample).flatMap(TextSample.init(rawValue:)) ?? .english
        textCustom = defaults.string(forKey: SettingsKey.textCustom).map { String($0.prefix(Self.maxTextLength)) }
        textColumns = min(3, max(1, defaults.integer(forKey: SettingsKey.textColumns)))
        textAlignment = defaults.string(forKey: SettingsKey.textAlignment).flatMap(BodyTextAlignment.init(rawValue:)) ?? .left
        let textSize = defaults.double(forKey: SettingsKey.textPointSize)
        textPointSize = Self.textPointSizeRange.contains(textSize) ? textSize : Self.defaultTextPointSize
        let lineHeight = defaults.double(forKey: SettingsKey.textLineHeight)
        textLineHeight = Self.textLineHeightRange.contains(lineHeight) ? lineHeight : Self.defaultTextLineHeight
        duplicateLocationRank = (defaults.array(forKey: SettingsKey.duplicateLocationRank) as? [NSNumber])?.map(\.int64Value) ?? []
        skipDuplicatesOnImport = defaults.bool(forKey: SettingsKey.skipDuplicatesOnImport)
        layouts.fontStore = { [weak self] in self?.backend?.store }
        compare.fontStore = { [weak self] in self?.backend?.store }
    }

    // MARK: Startup

    func start() async {
        guard !started else { return }
        started = true
        // 1. Open the database.
        do {
            let skipDuplicates = skipDuplicatesOnImport
            let (backend, presetStore) = try await Task.detached(priority: .userInitiated) {
                let dir = try LibraryBackend.dataDirectory()
                return (try LibraryBackend(databaseURL: dir.appendingPathComponent("library.sqlite"), skipDuplicatesOnImport: skipDuplicates),
                        PresetStore(url: dir.appendingPathComponent("presets.json")))
            }.value
            self.backend = backend
            self.presetStore = presetStore
            google = GoogleFontsController(model: self, transport: URLSessionGoogleTransport(), defaults: .standard)
            presets = await Task.detached { presetStore.load() }.value
        } catch {
            alert = AlertItem(title: "The font library could not be opened", message: error.localizedDescription)
            return
        }
        guard let backend else { return }

        // The existing index is browsable right away; everything below runs behind it.
        await reloadLocations()
        refreshCounts()
        await refreshNow()
        isReady = true
        // The built-in layout templates, copied once (an existing file is never overwritten).
        Task { await layouts.installBuiltInTemplates() }
        // Today's automatic backup when it is missing, behind the launch.
        scheduleLaunchBackup()

        // 4. Online/offline must be known before anything builds file URLs from last_known_path.
        await runBackground { _ = try backend.refreshOnlineState() }
        // 6. Subscribe to mounts early so none are missed while restoring.
        startVolumeMonitor()
        // 2. System folders are indexed once.
        let newSystem = await runBackground { try backend.ensureSystemLocations() } ?? []
        await reloadLocations()
        // 3. Restore activated fonts, always: Activated must match what is really active. Faces left temporary by an
        // older version are reset to off and never registered.
        let report = await backend.activation.restoreOnLaunch()
        present(report, state: .on, context: "Restoring activated fonts")
        invalidateRows()
        // 3b. What is active on the Mac, then whenever the registered fonts change.
        await reconcileInventory()
        observeRegisteredFonts()
        // 5. Incremental background rescan of the online user locations, the user-installed font folders (small) and
        // the system folder when it was added just now.
        for loc in locations where loc.online && !loc.autoIndexed && (loc.kind != .system || newSystem.contains(loc.id)) {
            rescan(loc.id)
        }
        // 7. Watch online folders.
        updateWatchers()
        // 7b. Google Fonts: the daily update check and any pending downloads, behind the launch.
        if let google { Task { await google.launch() } }
        refreshCounts()
        scheduleRefresh()
        await loadQuickCollection()
        // 8. Classify faces indexed by an older classifier (runs again after every mount and scan).
        startFaceBackfill()
        // 9. The Duplicates row's group count, from the hashes already stored (the view hashes when opened).
        startDuplicateSearch(hashing: false)
    }

    func prepareForQuit() async {
        // The open layout's pending edits, bounded so a slow disk cannot hold up quitting.
        await awaitAtMost(Self.layoutsQuitBudget, Task { await layouts.flush() })
        cancelRestore()
        flushPreviewSave()
        await flushNotes()
        await quickCollectionWriteChain?.value
        await stopFaceBackfill()
        await stopDuplicateSearch()
        // Activation shutdown, then the backup (at most `quitBackupBudget`) with the flushed notes. All of this runs
        // inside the app's overall 5 s quit budget (`FontoryApp`), shared with the layouts flush above.
        google?.stopForQuit()
        await backend?.activation.prepareForQuit()
        await writeAutomaticBackup(within: Self.quitBackupBudget)
    }

    static let layoutsQuitBudget: Duration = .seconds(1)
    private static let previewSaveDelay: Duration = .milliseconds(300)

    private func schedulePreviewSave() {
        #if DEBUG
        // The smoke run shares the app's defaults domain with the user's Fontory.
        if suppressesPreviewSaveForSmoke { return }
        #endif
        previewSaveTask?.cancel()
        previewSaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewSaveDelay)
            guard !Task.isCancelled, let self else { return }
            self.previewSaveTask = nil
            self.preview.save()
        }
    }

    /// Writes a pending preview-settings change now (at quit).
    func flushPreviewSave() {
        #if DEBUG
        if suppressesPreviewSaveForSmoke { return }
        #endif
        guard let task = previewSaveTask else { return }
        task.cancel()
        previewSaveTask = nil
        preview.save()
    }

    // MARK: Registered fonts

    private func observeRegisteredFonts() {
        let center = NotificationCenter.default
        let names = [Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
                     NSApplication.didBecomeActiveNotification]
        for name in names {
            inventoryObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleInventory() }
            })
        }
        inventoryTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.inventoryInterval)
                guard !Task.isCancelled else { return }
                await self?.reconcileInventory()
            }
        }
    }

    /// Re-reads the registered fonts after the next quiet second.
    func scheduleInventory() {
        inventoryTask?.cancel()
        inventoryTask = Task { [weak self] in
            try? await Task.sleep(for: AppModel.inventoryDelay)
            guard !Task.isCancelled else { return }
            await self?.reconcileInventory()
        }
    }

    /// Reads `CTFontManagerCopyAvailableFontURLs` and reconciles the index with it, off the main actor (the inventory
    /// actor serializes passes). Refreshes the views when something changed.
    private func reconcileInventory() async {
        guard let backend else { return }
        let result: InventoryResult
        do {
            result = try await backend.inventory.refresh()
        } catch {
            Self.log.error("registered fonts could not be matched: \(String(describing: error), privacy: .public)")
            return
        }
        // Registered files a scanned location has not indexed yet: rescan it, once per file. A location already
        // scanning is left alone (its scan ends with another pass); paths count as requested only once a rescan started.
        for (id, paths) in result.pendingPaths {
            let fresh = paths.subtracting(requestedPendingPaths)
            guard !fresh.isEmpty, scanTasks[id] == nil else { continue }
            rescan(id)
            if scanTasks[id] != nil { requestedPendingPaths.formUnion(fresh) }
        }
        guard result.changed else { return }
        if result.locationsChanged { await reloadLocations() }
        forgetGlyphs()
        invalidateRows()
        refreshCounts()
        scheduleRefresh()
    }

    // MARK: Query

    private func updateSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        query.search = trimmed.isEmpty ? nil : SearchText(trimmed, scope: searchScope)
    }

    /// Choosing the active sort again inverts the order; random always reshuffles.
    func chooseSort(_ sort: LibraryQuery.Sort) {
        switch (sort, query.sort) {
        case (.random, _):
            query.sort = .random(seed: UInt64.random(in: 1...UInt64(UInt32.max)))
        case let (new, current) where new == current:
            query.ascending.toggle()
        default:
            query.sort = sort
            query.ascending = true
        }
    }

    func scheduleRefresh(delay: Duration = AppModel.refreshDelay) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    private func refreshNow() async {
        guard let backend else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let query = query
        let result = await Task.detached(priority: .userInitiated) { () -> Result<([Int64], [Int64: Int]), Error> in
            Result {
                let ids = try backend.store.faceIDs(for: query)
                var index: [Int64: Int] = [:]
                index.reserveCapacity(ids.count)
                for (i, id) in ids.enumerated() { index[id] = i }
                return (ids, index)
            }
        }.value
        guard generation == refreshGeneration else { return }
        switch result {
        case .success(let (ids, index)):
            // Rows are keyed by face id and do not depend on the query, so the cache survives refreshes;
            // it is dropped only when activation changes or a scan finishes.
            indexByID = index
            if ids != faceIDs { faceIDs = ids }
            let kept = selection.filter { index[$0] != nil }
            if kept.count != selection.count { selection = kept }
            // Rescans and inventory changes may add or remove styles of the family shown.
            if detail != nil { reloadDetail() }
        case .failure(let error):
            Self.log.error("query failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshCounts() {
        guard let backend else { return }
        let includeSystem = query.includeSystem
        countsTask?.cancel()
        countsTask = Task { [weak self] in
            let counts = await Task.detached(priority: .utility) { try? backend.counts(includeSystem: includeSystem) }.value
            guard !Task.isCancelled, let counts else { return }
            self?.counts = counts
        }
        Task { await reloadOrganization() }
        Task { await reloadEditedFamilies() }
    }

    /// The row for a face, from a small cache filled in batches around the requested position.
    func row(_ id: Int64) -> FaceRow? {
        _ = rowsVersion
        if let row = rowCache[id] { return row }
        guard let backend else { return nil }
        var batch = [id]
        if let i = indexByID[id] {
            let lo = max(0, i - 100), hi = min(faceIDs.count, i + 200)
            batch = Array(faceIDs[lo..<hi])
        }
        guard let rows = try? backend.store.rows(ids: batch) else { return nil }
        for (key, value) in rows { rowCache[key] = value }
        return rows[id]
    }

    /// Posted on the main actor after `prefetchRows` stored rows; `userInfo[rowIDsKey]` holds their `[Int64]` ids.
    nonisolated static let rowsLoadedNotification = Notification.Name("FontoryRowsLoaded")
    nonisolated static let rowIDsKey = "ids"

    /// The cached row for a face, without touching the database. Nil until `prefetchRows` has loaded it.
    func cachedRow(_ id: Int64) -> FaceRow? {
        rowCache[id]
    }

    /// Loads the rows for `ids` that are neither cached nor already loading, in one batch on the read
    /// connection off the main actor, then posts `rowsLoadedNotification`. Results that arrive after the rows
    /// were invalidated are dropped (the caller asks again for what it still shows).
    func prefetchRows(_ ids: some Sequence<Int64>) {
        guard let backend else { return }
        let missing = ids.filter { rowCache[$0] == nil && !pendingRowIDs.contains($0) }
        guard !missing.isEmpty else { return }
        pendingRowIDs.formUnion(missing)
        let version = rowsVersion
        Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { try? backend.store.rows(ids: missing) }.value
            guard let self else { return }
            // After an invalidation the pending set was reset; ids pending now belong to newer fetches.
            guard version == self.rowsVersion else { return }
            self.pendingRowIDs.subtract(missing)
            guard let rows, !rows.isEmpty else { return }
            for (key, value) in rows { self.rowCache[key] = value }
            NotificationCenter.default.post(name: Self.rowsLoadedNotification, object: self,
                                            userInfo: [Self.rowIDsKey: Array(rows.keys)])
        }
    }

    /// Index in `faceIDs` of the first face whose family starts with `prefix` (case-insensitive), searched off
    /// the main actor: a binary search when the list is sorted by family ascending, otherwise a linear scan.
    func firstIndex(familyPrefix prefix: String) async -> Int? {
        guard let backend, !prefix.isEmpty else { return nil }
        let ids = faceIDs
        let sortedByFamily = query.sort == .family && query.ascending
        let needle = prefix.lowercased()
        return await Task.detached(priority: .userInitiated) { () -> Int? in
            func family(_ i: Int) -> String? { (try? backend.store.rows(ids: [ids[i]]))?[ids[i]]?.family.lowercased() }
            if sortedByFamily {
                var lo = 0, hi = ids.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    guard let f = family(mid) else { break }
                    if f < needle { lo = mid + 1 } else { hi = mid }
                }
                // SQLite's NOCASE order can differ from Swift's for non-ASCII names; verify, else scan.
                if lo < ids.count, family(lo)?.hasPrefix(needle) == true { return lo }
            }
            var start = 0
            while start < ids.count {
                let end = min(start + 2000, ids.count)
                let chunk = Array(ids[start..<end])
                guard let rows = try? backend.store.rows(ids: chunk) else { return nil }
                for (offset, id) in chunk.enumerated() where rows[id]?.family.lowercased().hasPrefix(needle) == true {
                    return start + offset
                }
                start = end
            }
            return nil
        }.value
    }

    func invalidateRows() {
        rowCache.removeAll()
        // Fetches in flight return rows of the old version and are dropped, so their ids must be requestable again.
        pendingRowIDs.removeAll()
        rowsVersion &+= 1
        // Files may have been replaced by a rescan: let faces that failed to load try again.
        previewRenderer.forgetFailures()
    }

    /// A rescan may have replaced files: glyphs are listed and drawn afresh. (Not on activation changes, which
    /// also invalidate the rows but leave the files alone.)
    func forgetGlyphs() {
        glyphsVersion &+= 1
        glyphInventories.removeAll()
        glyphPipeline.removeAllImages()
    }

    // MARK: Locations

    /// The user's folders and file sets.
    var userLocations: [LocationRecord] { locations.filter { $0.kind != .googleFonts && !$0.kind.isReadOnly && !$0.autoIndexed } }
    /// The standard font folders (System, Computer, User). Auto-indexed folders are not listed: their fonts are in
    /// the System and User views.
    /// Every location but the auto-indexed ones (Settings).
    var listedLocations: [LocationRecord] { locations.filter { !$0.autoIndexed } }

    func location(_ id: Int64) -> LocationRecord? { locations.first { $0.id == id } }

    /// System fonts and fonts active outside Fontory are read-only: their activation cannot be changed here.
    func isActivationLocked(_ row: FaceRow) -> Bool {
        row.isActivationReadOnly
    }

    func reloadLocations() async {
        guard let backend else { return }
        if let locs = await runBackground({ try backend.store.locations() }) { locations = locs }
    }

    func addLocation(url: URL) async {
        guard let backend else { return }
        guard let loc = await runBackground({ try backend.addFolder(url) }, failureTitle: "The folder could not be added") else { return }
        await reloadLocations()
        query.scope = .location(id: loc.id, subfolder: nil)
        rescan(loc.id)
        updateWatchers()
    }

    /// Indexes individual files: one `.fileSet` location per parent folder, or a rescan of the folder location
    /// that already contains them.
    func addFiles(urls: [URL]) async {
        guard let backend else { return }
        let byFolder = Dictionary(grouping: urls) { $0.deletingLastPathComponent().standardizedFileURL }
        for (folder, files) in byFolder {
            guard let target = await runBackground({ try backend.fileTarget(for: folder) },
                                                   failureTitle: "The fonts could not be added") else { continue }
            switch target {
            case .covered(let covering):
                // Added again by the user: an exclusion of one of them (Remove from Library) no longer applies.
                _ = await runBackground { try backend.deleteExclusions(of: files, in: covering) }
                rescan(covering.id)
            case .fileSet(let loc):
                await reloadLocations()
                scanProgress[loc.id] = ScanProgress(locationID: loc.id, phase: .parsing, total: files.count)
                let skip = skipDuplicatesOnImport
                let progress = await runBackground { try backend.importFiles(files, into: loc, skipDuplicates: skip) }
                scanProgress[loc.id] = progress ?? ScanProgress(locationID: loc.id, phase: .aborted(reason: "import failed"))
            }
        }
        query.scope = .recentImport
        await scanFinished()
        await loadExcludedFiles()
    }

    /// Imports whatever was dropped: folders become locations, files are added individually.
    func importDropped(_ urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = urls.filter { !folders.contains($0) }
        Task {
            for folder in folders { await addLocation(url: folder) }
            if !files.isEmpty { await addFiles(urls: files) }
        }
    }

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose font folders or font files. Fonts stay where they are."
        guard panel.runModal() == .OK else { return }
        importDropped(panel.urls)
    }

    func rescan(_ id: Int64) {
        guard let backend, let loc = location(id) else { return }
        guard loc.online else {
            scanProgress[id] = ScanProgress(locationID: id, phase: .aborted(reason: "The location is offline."))
            return
        }
        scanTasks[id]?.cancel()
        nextScanToken &+= 1
        let token = nextScanToken
        scanTokens[id] = token
        // Auto-indexed locations hold only the files the inventory added: refresh those like a file set.
        if loc.kind == .fileSet || loc.autoIndexed {
            scanProgress[id] = ScanProgress(locationID: id, phase: .parsing)
            scanTasks[id] = Task { [weak self] in
                defer { self?.scanEnded(id, token: token) }
                let progress = await Task.detached(priority: .utility) { try? backend.refreshFileSet(loc) }.value
                guard let self, !Task.isCancelled else { return }
                self.scanProgress[id] = progress ?? ScanProgress(locationID: id, phase: .aborted(reason: "rescan failed"))
                self.forgetPreviewFonts(of: id)
                await self.scanFinished()
            }
            return
        }
        scanTasks[id] = Task { [weak self] in
            defer { self?.scanEnded(id, token: token) }
            let stream = await backend.scanner.scan(locationID: id)
            var lastRefresh = ContinuousClock.now
            var last: ScanProgress?
            for await progress in stream {
                guard let self else { return }
                last = progress
                self.scanProgress[id] = progress
                // Let the counts and the browser grow while a large import runs.
                if ContinuousClock.now - lastRefresh > .seconds(1) {
                    lastRefresh = .now
                    self.refreshCounts()
                    self.scheduleRefresh()
                }
            }
            // Registrations follow the files even when the scan was cancelled or aborted after applying moves.
            if let last {
                if last.phase == .done, last.removedWithUserData > 0 { self?.removalNotices[id, default: 0] += last.removedWithUserData }
                await self?.updateRegistrations(after: last)
            }
            guard let self else { return }
            // Changed, moved or removed files must not be previewed from fonts parsed before the scan.
            self.forgetPreviewFonts(of: id)
            guard !Task.isCancelled else { return }
            await self.scanFinished()
        }
    }

    /// A scan run ended: `scanTasks[id]` is empty again unless a newer run replaced it.
    private func scanEnded(_ id: Int64, token: UInt64) {
        guard scanTokens[id] == token else { return }
        scanTokens[id] = nil
        scanTasks[id] = nil
    }

    /// Drops the preview renderer's parsed fonts for a location's files (they may hold the files open).
    func forgetPreviewFonts(of id: Int64) {
        guard let loc = location(id) else { return }
        previewRenderer.forgetFonts(under: URL(fileURLWithPath: loc.lastKnownPath))
    }

    /// Moves the CoreText registration of moved active files to their new URL and drops removed ones, so app font
    /// menus do not keep a stale entry for the old path.
    private func updateRegistrations(after progress: ScanProgress) async {
        guard let backend, !progress.movedActiveFiles.isEmpty || !progress.removedActiveFileURLs.isEmpty else { return }
        await backend.activation.filesRemoved(progress.removedActiveFileURLs)
        let report = await backend.activation.filesMoved(progress.movedActiveFiles)
        present(report, state: .on, context: "Re-activating moved fonts")
    }

    func scanFinished() async {
        forgetGlyphs()
        invalidateRows()
        await reloadLocations()
        refreshCounts()
        scheduleRefresh()
        // Newly indexed files may be active outside Fontory.
        scheduleInventory()
        // Faces whose files are gone left the Quick Collection with them.
        await loadQuickCollection()
        // Moved files keep their face rows (and their old class version).
        startFaceBackfill()
        // Changed files lost their hashes, new ones may be copies: the Duplicates view searches again, else its count
        // follows from the hashes stored.
        startDuplicateSearch(hashing: isShowingDuplicates)
    }

    func relink(_ id: Int64, to url: URL) async {
        guard let backend else { return }
        await backend.scanner.cancel(locationID: id)
        guard await runBackground({ try backend.relink(id, to: url) }, failureTitle: "The location could not be relinked") != nil else { return }
        await reloadLocations()
        let report = await backend.activation.volumeMounted(locationIDs: [id])
        present(report, state: .on, context: "Re-activating fonts")
        rescan(id)
        updateWatchers()
        invalidateRows()
    }

    /// Returns the task that finishes the removal (awaited by the Google Fonts controller).
    @discardableResult
    func removeLocation(_ id: Int64) -> Task<Void, Never> {
        guard let backend else { return Task {} }
        scanTasks[id]?.cancel()
        scanTasks[id] = nil
        watchers.removeValue(forKey: id)?.stop()
        scanProgress[id] = nil
        removalNotices[id] = nil
        forgetPreviewFonts(of: id)
        return Task {
            await backend.scanner.cancel(locationID: id)
            await backend.activation.volumeUnmounted(locationIDs: [id])
            _ = await runBackground({ try backend.store.deleteLocation(id) }, failureTitle: "The location could not be removed")
            if case .location(let loc, _) = query.scope, loc == id { query.scope = .all }
            await scanFinished()
        }
    }

    func dismissRemovalNotice(_ id: Int64) {
        removalNotices[id] = nil
    }

    func confirmRemoveLocation(_ id: Int64) {
        guard let loc = location(id) else { return }
        alert = AlertItem(
            title: "Remove “\(loc.displayName)” from the library?",
            message: "Its fonts are deactivated and forgotten by Fontory. The files on disk are not touched.",
            actionTitle: "Remove", isDestructive: true, action: { [weak self] in self?.removeLocation(id) })
    }

    func subfolders(of locationID: Int64, parent: String?) async -> [String] {
        guard let backend else { return [] }
        return await runBackground { try backend.store.subfolders(locationID: locationID, parent: parent) } ?? []
    }

    func revealLocation(_ id: Int64) {
        guard let loc = location(id), loc.online else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: loc.lastKnownPath)])
    }

    // MARK: Folder watching

    func updateWatchers() {
        let watched = locations.filter { $0.online && !$0.autoIndexed && ($0.kind == .folder || $0.kind == .googleFonts || $0.kind == .userInstalled) }
        let wanted = Dictionary(watched.map { ($0.id, $0.lastKnownPath) },
                                uniquingKeysWith: { a, _ in a })
        for (id, watcher) in watchers where wanted[id] != watcher.path {
            watcher.stop()
            watchers[id] = nil
        }
        for (id, path) in wanted where watchers[id] == nil {
            watchers[id] = FolderWatcher(path: path) { [weak self] in self?.folderChanged(id) }
        }
    }

    private func folderChanged(_ id: Int64) {
        folderEventTasks[id]?.cancel()
        folderEventTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: AppModel.folderEventDelay)
            guard !Task.isCancelled else { return }
            self?.folderEventTasks[id] = nil
            self?.rescan(id)
        }
    }

    // MARK: Volumes

    private func startVolumeMonitor() {
        monitorTask = Task { [weak self] in
            for await event in VolumeMonitor().events {
                await self?.handle(event)
            }
        }
    }

    func handle(_ event: VolumeEvent) async {
        guard let backend else { return }
        switch event {
        case .mounted(_, let uuid):
            let ids: [Int64]
            if let uuid {
                ids = await runBackground { try backend.markMounted(volumeUUID: uuid) } ?? []
            } else {
                ids = await runBackground { try backend.refreshOnlineState() } ?? []
            }
            guard !ids.isEmpty else { return }
            // last_known_path is current now, so volumeMounted builds the right URLs.
            await reloadLocations()
            let report = await backend.activation.volumeMounted(locationIDs: ids)
            present(report, state: .on, context: "Re-activating fonts on the mounted volume")
            for id in ids where location(id)?.kind != .system { rescan(id) }
            google?.volumeMounted(ids)
            updateWatchers()
            invalidateRows()
            refreshCounts()
            scheduleRefresh()
            // Faces on the volume that waited while it was unplugged.
            startFaceBackfill()

        case .unmounted(let volumeURL):
            // Sent twice per unmount (will + did): the first event marks the locations offline locally,
            // so the second finds nothing to do.
            let root = volumeURL.standardizedFileURL.path
            let ids = locations.filter { $0.online && ($0.lastKnownPath == root || $0.lastKnownPath.hasPrefix(root + "/")) }.map(\.id)
            guard !ids.isEmpty else { return }
            // First, before any await: nothing of ours may keep a file on the volume open, or the eject fails
            // with "disk in use". Pending renders are dropped and parsed fonts released, Google downloads stopped.
            google?.volumeUnmounted(ids)
            previewPipeline.cancelAll()
            glyphPipeline.cancelAll()
            // The backfill may be reading from the volume; no run starts until the locations are offline.
            unmountsInProgress += 1
            cancelFaceBackfill()
            // Hashing may be reading from the volume too.
            cancelDuplicateSearch()
            previewRenderer.forgetFonts(under: volumeURL)
            for id in ids { forgetPreviewFonts(of: id) }
            for i in locations.indices where ids.contains(locations[i].id) { locations[i].online = false }
            for id in ids {
                scanTasks.removeValue(forKey: id)?.cancel()
                folderEventTasks.removeValue(forKey: id)?.cancel()
                watchers.removeValue(forKey: id)?.stop()
                await backend.scanner.cancel(locationID: id)
            }
            await backend.activation.volumeUnmounted(locationIDs: ids)
            _ = await runBackground { try backend.markOffline(ids) }
            unmountsInProgress -= 1
            startFaceBackfill()
            duplicateSearchAfterUnmount()
            await reloadLocations()
            invalidateRows()
            refreshCounts()
            scheduleRefresh()
        }
    }

    // MARK: Activation

    func setActivation(_ ids: [Int64], _ state: ActivationState, force: Bool = false) async {
        guard let backend else { return }
        let allowed = await rowsForAction(ids).filter { !isActivationLocked($0) }.map(\.id)
        guard !allowed.isEmpty else { return }
        let report = await backend.activation.set(allowed, to: state, force: force)
        afterActivationChange()
        present(report, state: state, context: nil)
    }

    /// Activates the unlocked faces among `ids`, or deactivates them when none is off. Rows that are not cached
    /// are fetched off the main actor.
    func toggleActivation(_ ids: [Int64]) async {
        let rows = await rowsForAction(ids).filter { !isActivationLocked($0) }
        guard !rows.isEmpty else { return }
        let state: ActivationState = rows.contains { $0.activation == .off } ? .on : .off
        await setActivation(rows.map(\.id), state)
    }

    func afterActivationChange() {
        invalidateRows()
        refreshCounts()
        switch query.scope {
        case .activated, .user, .deactivated: scheduleRefresh()
        // A smart tag may test activation.
        case .tags(let picks) where picks.contains(where: { $0.rule != nil }): scheduleRefresh()
        default: if query.sort == .lastActivated { scheduleRefresh() }
        }
    }

    private func displayName(_ id: Int64) -> String {
        row(id)?.fullName ?? "Font #\(id)"
    }

    /// Turns an activation report into one alert: conflicts (with "Activate Anyway") and failures.
    func present(_ report: ActivationReport, state: ActivationState, context: String?) {
        guard !report.conflicts.isEmpty || !report.failures.isEmpty else { return }
        var lines: [String] = []
        if let general = report.failures[-1] { lines.append("Error: \(general)") }
        let failures = report.failures.filter { $0.key != -1 }.sorted { $0.key < $1.key }
        if !failures.isEmpty {
            lines.append("\(failures.count) font\(failures.count == 1 ? "" : "s") failed:")
            lines += failures.prefix(15).map { "• \(displayName($0.key)): \($0.value)" }
            if failures.count > 15 { lines.append("…and \(failures.count - 15) more") }
        }
        let conflicts = report.conflicts.sorted { $0.key < $1.key }
        if !conflicts.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("\(conflicts.count) font\(conflicts.count == 1 ? " shares" : "s share") a PostScript name with a font that is already installed or active:")
            lines += conflicts.prefix(15).map { displayName($0.key) == $0.value ? "• \($0.value)" : "• \(displayName($0.key)) (\($0.value))" }
            if conflicts.count > 15 { lines.append("…and \(conflicts.count - 15) more") }
        }
        let title = context.map { "\($0): some fonts need attention" }
            ?? (conflicts.isEmpty ? "Some fonts could not be changed" : "Some fonts conflict with active fonts")
        var item = AlertItem(title: title, message: lines.joined(separator: "\n"))
        if !conflicts.isEmpty {
            let ids = conflicts.map(\.key)
            item.actionTitle = "Activate Anyway"
            item.action = { [weak self] in
                Task { await self?.setActivation(ids, state, force: true) }
            }
        }
        alert = item
    }

    // MARK: Actions on faces

    /// Rows for a user action on `ids`, in order: cached ones directly, the rest fetched off the main actor.
    func rowsForAction(_ ids: [Int64]) async -> [FaceRow] {
        var rows: [Int64: FaceRow] = [:]
        var missing: [Int64] = []
        for id in ids {
            if let row = rowCache[id] { rows[id] = row } else { missing.append(id) }
        }
        let toFetch = missing
        if !toFetch.isEmpty, let backend, let fetched = await runBackground({ try backend.store.rows(ids: toFetch) }) {
            rows.merge(fetched) { cached, _ in cached }
        }
        return ids.compactMap { rows[$0] }
    }

    func revealInFinder(_ ids: [Int64]) {
        Task {
            let urls = await rowsForAction(ids).compactMap(\.fileURL)
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(Array(Set(urls)))
        }
    }

    func copyDetails(_ ids: [Int64]) {
        Task {
            let text = await rowsForAction(ids).map { r in
                [r.postScriptName, r.family, r.style, r.version ?? "", r.fileURL?.path ?? "(offline)"].joined(separator: "\t")
            }.joined(separator: "\n")
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Makes the face the one shown for its family in the list view.
    func setFamilyRepresentative(_ id: Int64) {
        guard let backend else { return }
        Task {
            guard let row = await rowsForAction([id]).first else { return }
            let key = row.family.lowercased()
            await runBackground({ try backend.store.setRepresentative(familyKey: key, faceID: id) },
                                failureTitle: "The family representative could not be set")
            if viewMode == .list { scheduleRefresh(delay: .zero) }
            // The family page's header previews the representative.
            if detail != nil { reloadDetail() }
        }
    }

    // MARK: Family page

    /// The face whose family "Show Family" opens: the first selected face in browser order.
    var firstSelectedFace: Int64? {
        selection.min { (indexByID[$0] ?? .max, $0) < (indexByID[$1] ?? .max, $1) }
    }

    /// Opens the family page of `faceID`'s family, with that face selected. The family's faces are read off the
    /// main actor.
    func openFamilyDetail(faceID: Int64) {
        guard let backend else { return }
        detailGeneration += 1
        let generation = detailGeneration
        let includeSystem = query.includeSystem
        Task {
            guard let row = await rowsForAction([faceID]).first else { return }
            let name = row.family
            let group = await runBackground { try backend.store.family(named: name, includeSystem: includeSystem) } ?? nil
            guard generation == detailGeneration else { return }
            let ids = group?.faceIDs ?? [faceID]
            if isShowingDuplicates { closeDuplicates() }
            detail = FamilyDetail(family: group?.name ?? name, faceIDs: ids, representativeID: group?.representativeID ?? faceID)
            detailTab = .styles
            detailSelection = ids.contains(faceID) ? [faceID] : []
            prefetchRows(ids)
        }
    }

    /// The styles' preview size as drawn: compact rows cap it (see `StyleCellView.compactMaxPointSize`).
    var effectiveDetailPointSize: Int {
        Int(detailLayout == .compact ? min(detailPointSize, Self.compactMaxPointSize) : detailPointSize)
    }
    nonisolated static let compactMaxPointSize = 36.0

    /// ⌘1 / ⌘3: the browser in `mode`, leaving the family page if it is open.
    func showBrowser(as mode: ViewMode) {
        closeFamilyDetail()
        viewMode = mode
    }

    /// ⌘I / ⌘↓ / Return: the family page of the selection; on the family page ⌘I shows Info.
    func showFamilyDetailForSelection() {
        if detail != nil {
            detailTab = .info
        } else if let id = firstSelectedFace {
            openFamilyDetail(faceID: id)
        }
    }

    /// Back to the browser, as it was.
    func closeFamilyDetail() {
        detailGeneration += 1
        if isShowingDuplicates { closeDuplicates() }
        guard detail != nil else { return }
        detail = nil
        detailSelection = []
        previewPipeline.cancelAll(lane: .detailHeader)
        previewPipeline.cancelAll(lane: .detailStyles)
        glyphPipeline.cancelAll()
    }

    /// Runs a family edit (the store write through the page's re-open): a refresh's `reloadDetail` finishing
    /// meanwhile would look the page up by its old name and close it, so it is ignored.
    func whileFollowingFamilyEdit(_ body: () async -> Void) async {
        detailFollowingEdit += 1
        defer { detailFollowingEdit -= 1 }
        await body()
    }

    /// After a family edit: shows the family `faceID` now belongs to (the page follows a rename), or leaves the page
    /// when that family is gone. Only acts while a family page is open.
    func reopenFamilyDetail(following faceID: Int64) async {
        guard let backend, detail != nil else { return }
        detailGeneration += 1
        let generation = detailGeneration
        let includeSystem = query.includeSystem
        let group = await runBackground { () -> FamilyGroup? in
            guard let name = try backend.store.rows(ids: [faceID])[faceID]?.family else { return nil }
            return try backend.store.family(named: name, includeSystem: includeSystem)
        } ?? nil
        guard generation == detailGeneration, detail != nil else { return }
        guard let group else { return closeFamilyDetail() }
        detail = FamilyDetail(family: group.name, faceIDs: group.faceIDs, representativeID: group.representativeID)
        let kept = detailSelection.filter(group.faceIDs.contains)
        if kept != detailSelection { detailSelection = kept }
        prefetchRows(group.faceIDs)
    }

    /// Re-reads the shown family's faces (after a refresh); leaves the page when none is left.
    private func reloadDetail() {
        guard let backend, let current = detail else { return }
        let generation = detailGeneration
        let includeSystem = query.includeSystem
        Task {
            let group = await runBackground { try backend.store.family(named: current.family, includeSystem: includeSystem) } ?? nil
            guard generation == detailGeneration, detail == current, detailFollowingEdit == 0 else { return }
            guard let group else { return closeFamilyDetail() }
            let updated = FamilyDetail(family: group.name, faceIDs: group.faceIDs, representativeID: group.representativeID)
            guard updated != current else { return }
            detail = updated
            let kept = detailSelection.filter(group.faceIDs.contains)
            if kept != detailSelection { detailSelection = kept }
            prefetchRows(group.faceIDs)
        }
    }

    /// Everything the index knows about a face, read off the main actor.
    func faceInfo(_ id: Int64) async -> FaceInfo? {
        guard let backend else { return nil }
        return await runBackground { try backend.store.faceInfo(id: id) } ?? nil
    }

    func revealFile(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Zoom

    static let defaultZoom = 0.25

    /// True when the latest zoom change came from the keyboard, so the grid anchors it on the pointer
    /// (slider and menu clicks anchor on the selection or the first visible item). The showing view resets it.
    @ObservationIgnored var zoomAnchorsOnPointer = false

    func adjustZoom(by delta: Double) {
        if detail != nil, detailTab == .characters {
            // On the Characters tab the zoom commands change the cell size (8 pt per step).
            let r = Self.glyphCellSizeRange
            glyphCellSize = min(r.upperBound, max(r.lowerBound, (glyphCellSize + delta * 80).rounded()))
            return
        }
        if detail != nil, detailTab == .text {
            // On the Text tab the zoom commands change the body size (1 pt per step).
            let r = Self.textPointSizeRange
            textPointSize = min(r.upperBound, max(r.lowerBound, (textPointSize + delta * 10).rounded()))
            return
        }
        if detail != nil {
            // On the family page the zoom commands change its own preview size (8 pt per step).
            let r = Self.detailPointSizeRange
            detailPointSize = min(r.upperBound, max(r.lowerBound, (detailPointSize + delta * 80).rounded()))
            return
        }
        let current = zoom[viewMode] ?? Self.defaultZoom
        setZoomFromCommand(min(1, max(0, ((current + delta) * 100).rounded() / 100)))
    }

    func resetZoom() {
        if detail != nil, detailTab == .characters {
            glyphCellSize = Self.defaultGlyphCellSize
            return
        }
        if detail != nil, detailTab == .text {
            textPointSize = Self.defaultTextPointSize
            return
        }
        if detail != nil {
            detailPointSize = Self.defaultDetailPointSize
            return
        }
        setZoomFromCommand(Self.defaultZoom)
    }

    private func setZoomFromCommand(_ value: Double) {
        zoomAnchorsOnPointer = NSApp.currentEvent?.type == .keyDown
        zoom[viewMode] = value
    }

    // MARK: Presets

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presets = PresetStore.upserting(Preset(name: trimmed, text: preview.text), into: presets)
        preview.textSource = "preset:" + trimmed
        persistPresets()
    }

    func deletePreset(_ preset: Preset) {
        presets.removeAll { $0.name == preset.name }
        persistPresets()
    }

    private func persistPresets() {
        guard let presetStore else { return }
        let presets = presets
        Task {
            await runBackground({ try presetStore.save(presets) }, failureTitle: "Presets could not be saved")
        }
    }

    #if DEBUG
    /// Debug smoke hooks: use a backend opened elsewhere (a temporary library) without the launch sequence.
    func attachBackendForSmoke(_ backend: LibraryBackend) async {
        self.backend = backend
        await reloadLocations()
        await loadQuickCollection()
        isReady = true
    }

    func refreshNowForSmoke() async { await refreshNow() }

    func setDetailForSmoke(_ value: FamilyDetail?, selection ids: Set<Int64> = []) {
        detail = value
        detailSelection = ids
    }

    /// Waits until no scan runs.
    func waitForScansForSmoke() async {
        while let task = scanTasks.values.first { await task.value }
    }
    #endif

    /// A scan of the location is running.
    func isScanning(_ id: Int64) -> Bool { scanTasks[id] != nil }

    // MARK: Helpers

    /// Runs `work` off the main actor. On error, logs it and (with a title) shows an alert; returns nil.
    @discardableResult
    func runBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T, failureTitle: String? = nil) async -> T? {
        let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            Self.log.error("\(failureTitle ?? "background work", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if let failureTitle { alert = AlertItem(title: failureTitle, message: error.localizedDescription) }
            return nil
        }
    }
}
