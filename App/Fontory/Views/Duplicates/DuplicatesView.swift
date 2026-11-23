import AppKit
import FontoryCore
import SwiftUI

/// Library → Duplicates, shown in place of the browser: exact groups, then same-font groups, each file a row with
/// its preview, name, version, format, location, size, activation and a checkbox for the copies to remove.
struct DuplicatesView: View {
    @Bindable var model: AppModel

    private var exact: [DuplicateGroup] { model.duplicateGroups.filter { $0.kind == .exact } }
    private var sameFont: [DuplicateGroup] { model.duplicateGroups.filter { $0.kind == .sameFont } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.duplicateGroups.isEmpty {
                if model.isFindingDuplicates {
                    ProgressView(progressText).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Duplicates", systemImage: "doc.on.doc",
                                           description: Text("No two files in the library hold the same font."))
                }
            } else {
                List {
                    if !exact.isEmpty {
                        Section {
                            ForEach(exact) { DuplicateGroupView(model: model, group: $0) }
                        } header: {
                            Text("Exact Copies (\(exact.count.formatted()))")
                        }
                    }
                    if !sameFont.isEmpty {
                        Section {
                            ForEach(sameFont) { DuplicateGroupView(model: model, group: $0) }
                        } header: {
                            Text("Same Font, Different Files (\(sameFont.count.formatted()))")
                        } footer: {
                            Text("Other versions or formats of the same font. They are never selected automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var progressText: String { model.duplicateSearchStatus }

    private var header: some View {
        HStack(spacing: 8) {
            Button("Find Again") { model.findDuplicates() }
                .disabled(model.isFindingDuplicates)
            Button("Select Copies to Remove") { Task { await model.selectCopiesToRemove() } }
                .disabled(exact.isEmpty || model.isRemovingDuplicates)
                .help("Keeps one file per exact group (active, then with tags or notes, then OTF > TTF > …, then the location ranked higher in Settings) and checks the others")
            Spacer(minLength: 8)
            if model.isFindingDuplicates {
                ProgressView().controlSize(.small)
                Text(progressText).font(.caption).foregroundStyle(.secondary)
            } else if !model.checkedRemovableFiles.isEmpty {
                Text("\(model.checkedRemovableFiles.count.formatted()) checked · "
                     + ByteCountFormatter.string(fromByteCount: model.checkedDuplicateSize, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Remove from Library") { Task { await model.removeCheckedFromLibrary() } }
                .disabled(model.checkedRemovableFiles.isEmpty || model.isRemovingDuplicates)
                .help("Removes the checked files from the library; they stay on disk and rescans skip them. Asks first when fonts with tags or notes would lose them.")
            Button("Move to Trash…") { model.moveCheckedToTrash() }
                .disabled(model.checkedRemovableFiles.isEmpty || model.isRemovingDuplicates)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One group: its name, then one row per file.
private struct DuplicateGroupView: View {
    @Bindable var model: AppModel
    let group: DuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            ForEach(Array(zip(group.fileIDs, group.faceIDs)), id: \.0) { fileID, faceID in
                if let row = model.duplicateRows[faceID] {
                    DuplicateRowView(model: model, row: row, file: model.duplicateFiles[fileID])
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        let name = group.faceIDs.first.flatMap { model.duplicateRows[$0]?.postScriptName } ?? group.id
        return "\(name) · \(group.fileIDs.count) files"
    }
}

private struct DuplicateRowView: View {
    @Bindable var model: AppModel
    let row: FaceRow
    let file: FileRecord?

    private var isProtected: Bool { model.isProtectedDuplicate(row.fileID) }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.checkedDuplicateFiles.contains(row.fileID) },
                                     set: { model.setDuplicateChecked(row.fileID, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isProtected)
                .help(isProtected ? "System fonts, installed fonts and fonts active outside Fontory are never removed" : "Remove this copy")
            DuplicatePreview(model: model, row: row, preview: model.preview)
                .frame(width: 180, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.fullName).lineLimit(1)
                Text(row.version ?? "No version").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 170, alignment: .leading)
            Text((file?.format ?? row.format).uppercased())
                .font(.caption.monospaced())
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.location(row.locationID)?.displayName ?? "—").lineLimit(1)
                Text(file?.relativePath ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            .help(row.fileURL?.path ?? "Offline")
            Text(file.map { ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file) } ?? "—")
                .font(.caption).monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Text(activation)
                .font(.caption)
                .foregroundStyle(row.activation != .off || row.externalActive ? Color.green : Color.secondary)
                .frame(width: 110, alignment: .leading)
        }
        .contextMenu {
            if let url = row.fileURL { Button("Reveal in Finder") { model.revealFile(url) } }
        }
    }

    private var activation: String {
        let faces = model.duplicateFacesByFile[row.fileID] ?? [row]
        if faces.contains(where: { $0.locationKind == .system }) { return "System" }
        if faces.contains(where: \.externalActive) { return "Active outside Fontory" }
        if faces.contains(where: { $0.activation == .on }) { return "Active" }
        if faces.contains(where: { $0.activation == .temporary }) { return "Temporary" }
        return row.online ? "Off" : "Offline"
    }
}

/// A one-line preview of a face from the shared pipeline (lane `duplicates`), with the browser's preview settings.
private struct DuplicatePreview: NSViewRepresentable {
    let model: AppModel
    let row: FaceRow
    let preview: PreviewSettings

    func makeNSView(context: Context) -> DuplicatePreviewNSView { DuplicatePreviewNSView(model: model) }

    func updateNSView(_ view: DuplicatePreviewNSView, context: Context) { view.update(row: row, preview: preview) }
}

final class DuplicatePreviewNSView: NSView {
    static let pointSize: CGFloat = 20

    private let model: AppModel
    private let previewLayer = CALayer()
    private var row: FaceRow?
    private var preview = PreviewSettings()
    private var wantedKey: PreviewPipeline.Key?

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.contentsGravity = .resizeAspect
        previewLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        previewLayer.masksToBounds = true
        layer?.addSublayer(previewLayer)
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        model.previewPipeline.addRenderObserver(self) { [weak self] key, image in
            guard let self, key == self.wantedKey else { return }
            self.previewLayer.contents = image
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(row new: FaceRow, preview newPreview: PreviewSettings) {
        guard new != row || newPreview != preview else { return }
        if new.id != row?.id { previewLayer.contents = nil }
        row = new
        preview = newPreview
        setAccessibilityLabel("Preview of \(new.fullName)")
        render()
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    private func render() {
        layer?.backgroundColor = preview.background
        guard let row, bounds.width > 1, bounds.height > 1 else { return }
        let key = DetailPreview.key(for: row, preview: preview, pointSize: Self.pointSize, size: bounds.size,
                                    scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, styleNames: true)
        guard key != wantedKey || previewLayer.contents == nil else { return }
        wantedKey = key
        previewLayer.opacity = row.online ? 1 : 0.4
        if let image = model.previewPipeline.image(for: key) {
            previewLayer.contents = image
        } else if let url = row.fileURL {
            model.previewPipeline.request(key, fileURL: url, faceIndex: row.faceIndex, lane: .duplicates)
        }
    }
}
