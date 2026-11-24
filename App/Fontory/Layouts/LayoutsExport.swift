import AppKit
import FontoryCore
import UniformTypeIdentifiers

/// Pages written so far of a long export.
struct ExportProgress: Equatable {
    var done: Int
    var total: Int
}

enum LayoutExportError: LocalizedError {
    case noLayout
    case noCandidates
    case busy

    var errorDescription: String? {
        switch self {
        case .noLayout: "No layout is open."
        case .noCandidates: "This layout has no candidate fonts."
        case .busy: "Another PDF export is still running."
        }
    }
}

/// File ▸ Export PDF…, Export PDF for Each Candidate… and Print…. PDFs are built and written off the main thread
/// (fonts resolved in one store call first); a per-candidate export of more than 10 pages reports progress and can
/// be cancelled between pages, which writes nothing.
extension LayoutsModel {
    /// Above this many pages the export shows a progress sheet.
    static let progressThreshold = 10

    var canExport: Bool { current != nil }
    var canExportCandidates: Bool { !candidates.isEmpty }

    /// “Poster.pdf”, or “Poster — Candidates.pdf”; path separators become “-”.
    nonisolated static func exportFileName(layoutName: String, forCandidates: Bool) -> String {
        let base = layoutName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return (base.isEmpty ? "Layout" : base) + (forCandidates ? " — Candidates" : "") + ".pdf"
    }

    // MARK: Menu actions (with panels)

    func exportPDFWithPanel() async {
        guard let doc = current else { return }
        guard let url = await chooseExportDestination(name: Self.exportFileName(layoutName: doc.name, forCandidates: false)) else { return }
        await report(try await exportPDF(to: url))
    }

    func exportPDFForEachCandidateWithPanel() async {
        guard let doc = current, canExportCandidates else { return }
        guard let url = await chooseExportDestination(name: Self.exportFileName(layoutName: doc.name, forCandidates: true)) else { return }
        await report(try await exportPDFForEachCandidate(to: url))
    }

    private func report(_ run: @autoclosure () async throws -> Void) async {
        do { try await run() } catch is CancellationError {} catch {
            errorMessage = "The PDF could not be written. \(error.localizedDescription)"
        }
    }

    /// The save panel (a sheet on the Layouts window), or the smoke override. Nil when cancelled.
    private func chooseExportDestination(name: String) async -> URL? {
        if let url = exportDestinationOverride { return url }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if let window {
            return await withCheckedContinuation { cont in
                panel.beginSheetModal(for: window) { cont.resume(returning: $0 == .OK ? panel.url : nil) }
            }
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Export

    /// Writes the open layout as a one-page PDF at its page size.
    func exportPDF(to url: URL) async throws {
        commitPendingText()
        guard let doc = current else { throw LayoutExportError.noLayout }
        try await writePDF(to: url, pages: 1) { _ in [doc] }
    }

    /// Writes one page per candidate family (the blocks in that family's closest styles). Builds the documents and
    /// writes the file off the main thread; more than 10 candidates show a progress sheet with Cancel.
    func exportPDFForEachCandidate(to url: URL) async throws {
        commitPendingText()
        guard let doc = current else { throw LayoutExportError.noLayout }
        guard !doc.candidates.isEmpty else { throw LayoutExportError.noCandidates }
        let pages = Set(doc.candidates.map { $0.family.lowercased() }).count
        try await writePDF(to: url, pages: pages) { store in
            LayoutRenderer.documentsForEachCandidate(doc) { ref in
                guard let store else { return [] }
                return (try? store.styles(ofFamilyOf: ref)) ?? []
            }
        }
    }

    /// Cancels the running export (the progress sheet's button).
    func cancelExport() {
        exportJob?.cancel()
    }

    /// Runs the build, one store call resolving every font the pages use that the cache lacks, and the PDF write
    /// on a detached task. Cancelling (this task or `cancelExport`) stops between pages and writes nothing.
    /// One export at a time: a second one while another runs throws `LayoutExportError.busy`. Progress updates
    /// apply only while their own export is still running (`exportGeneration` moves on when it ends).
    private func writePDF(to url: URL, pages: Int, build: @escaping @Sendable (FontStore?) -> [LayoutDocument]) async throws {
        guard exportJob == nil else { throw LayoutExportError.busy }
        exportGeneration += 1
        let generation = exportGeneration
        let store = fontStore()
        let known = resolved
        let delay = exportPageDelay
        let showsProgress = pages > Self.progressThreshold
        if showsProgress { exportProgress = ExportProgress(done: 0, total: pages) }
        defer {
            exportProgress = nil
            exportJob = nil
            exportGeneration += 1
        }
        let job = Task.detached(priority: .userInitiated) { [weak self] () throws -> Void in
            let docs = build(store)
            try Task.checkCancellation()
            var fonts = known
            let wanted = Set(docs.flatMap { $0.blocks.map(\.font) }).subtracting(known.keys)
            if let store, !wanted.isEmpty, let found = try? store.resolve(Array(wanted)) {
                fonts.merge(found) { _, new in new }
            }
            try LayoutRenderer.pdf(docs, fonts: fonts, to: url) { index, count in
                if Task.isCancelled { return false }
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                if showsProgress {
                    Task { @MainActor in
                        guard let self, self.exportGeneration == generation, self.exportJob != nil else { return }
                        self.exportProgress = ExportProgress(done: index, total: count)
                    }
                }
                return true
            }
        }
        exportJob = job
        try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    // MARK: Print

    /// The print operation for the open layout: the default printer's paper (not forced to the page size), the
    /// orientation from the page's aspect, and the page scaled to fit and centred. The page is drawn through
    /// `LayoutRenderer.draw` (vector) with the fonts already resolved for the canvas. Printing draws on the main
    /// thread (AppKit requires it); it is one page.
    func printOperation() -> NSPrintOperation? {
        commitPendingText()
        guard let doc = current else { return nil }
        let size = NSSize(width: max(1, doc.pageSize.w), height: max(1, doc.pageSize.h))
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = size.width > size.height ? .landscape : .portrait
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        let view = LayoutPrintView(document: doc, fonts: resolved, frame: NSRect(origin: .zero, size: size))
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = doc.name
        return op
    }

    func printLayout() {
        guard let op = printOperation() else { return }
        if let window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }
}

/// Draws one layout page into the current context (the print job's, or a PDF when asked for its data).
final class LayoutPrintView: NSView {
    private let document: LayoutDocument
    private let fonts: [FontReference: ResolvedFont]

    init(document: LayoutDocument, fonts: [FontReference: ResolvedFont], frame: NSRect) {
        self.document = document
        self.fonts = fonts
        super.init(frame: frame)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        LayoutRenderer.draw(document, fonts: fonts, in: ctx, pageRect: bounds)
    }
}
