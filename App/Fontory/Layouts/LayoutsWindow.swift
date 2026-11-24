import AppKit
import FontoryCore
import SwiftUI

/// Window ▸ Layouts: the user's layouts on the left, the page canvas in the centre, the block inspector on the right.
struct LayoutsWindow: View {
    @Environment(AppModel.self) private var model
    @State private var showsInspector = true

    private var layouts: LayoutsModel { model.layouts }

    var body: some View {
        NavigationSplitView {
            LayoutsList(layouts: layouts)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            LayoutDetail(layouts: layouts)
                .inspector(isPresented: $showsInspector) {
                    LayoutInspector(layouts: layouts)
                        .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
                }
        }
        .navigationTitle(layouts.currentURL?.deletingPathExtension().lastPathComponent ?? "Layouts")
        .toolbar {
            ToolbarItemGroup {
                Button { layouts.addTextBlock() } label: { Label("Text Block", systemImage: "plus.square") }
                    .help("Add a text block at the centre of the page")
                    .disabled(layouts.current == nil)
                Button { layouts.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out")
                    .disabled(layouts.current == nil)
                Button { layouts.zoomToFit() } label: { Text(zoomLabel).monospacedDigit().frame(minWidth: 44) }
                    .help("Zoom to Fit")
                    .disabled(layouts.current == nil)
                Button { layouts.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In")
                    .disabled(layouts.current == nil)
                Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.trailing") }
                    .help(showsInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
        .background(LayoutsWindowReader(layouts: layouts))
        .alert("Layouts", isPresented: Binding(get: { layouts.errorMessage != nil },
                                              set: { if !$0 { layouts.errorMessage = nil } })) {
            Button("OK") { layouts.errorMessage = nil }
        } message: {
            Text(layouts.errorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { layouts.exportProgress != nil }, set: { _ in })) {
            ExportProgressSheet(layouts: layouts)
        }
        .task { await layouts.reloadLists() }
        .onDisappear { Task { await layouts.flush() } }
        .frame(minWidth: 800, minHeight: 500)
    }

    private var zoomLabel: String {
        "\(Int((layouts.effectiveZoom * 100).rounded()))%"
    }
}

/// The layouts, with New Layout (from a template), Rename, Duplicate and Move to Trash.
private struct LayoutsList: View {
    let layouts: LayoutsModel
    @State private var renaming: LayoutLibrary.Item?
    @State private var newName = ""
    @State private var deleting: LayoutLibrary.Item?

    var body: some View {
        List(selection: Binding(get: { layouts.currentURL },
                                set: { url in if let url { Task { await layouts.open(url) } } })) {
            Section("Layouts") {
                ForEach(layouts.items, id: \.url) { item in
                    row(item)
                        .tag(item.url)
                        .selectionDisabled(item.error != nil)
                        .contextMenu {
                            Button("Rename…") { newName = item.name; renaming = item }
                            Button("Duplicate") { Task { await layouts.duplicate(item.url) } }
                                .disabled(item.error != nil)
                            Divider()
                            Button("Move to Trash") { deleting = item }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    ForEach(layouts.templates, id: \.url) { template in
                        Button(template.name) { Task { await layouts.newLayout(from: template.url) } }
                            .disabled(template.error != nil)
                    }
                } label: {
                    Label("New Layout", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(layouts.templates.isEmpty)
                Spacer()
            }
            .padding(8)
        }
        .overlay {
            if layouts.items.isEmpty {
                Text("No layouts yet.\nUse New Layout to start from a template.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .alert("Rename Layout", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let item = renaming { Task { await layouts.rename(item.url, to: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Move “\(deleting?.name ?? "")” to the Trash?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let item = deleting { Task { await layouts.delete(item.url) } }
                deleting = nil
            }
        }
    }

    @ViewBuilder private func row(_ item: LayoutLibrary.Item) -> some View {
        if let error = item.error {
            Label(item.name, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .help("This file can't be read as a layout: \(error)")
        } else {
            Label(item.name, systemImage: "doc.richtext")
        }
    }
}

/// The canvas with the candidates strip under it, or a hint when no layout is open.
private struct LayoutDetail: View {
    let layouts: LayoutsModel

    var body: some View {
        if layouts.current != nil {
            VStack(spacing: 0) {
                LayoutCanvasView(model: layouts, image: layouts.renderedImage, document: layouts.current,
                                 zoom: layouts.effectiveZoom, selection: layouts.selectedBlockID,
                                 missingFontBlocks: layouts.report.missingFontBlockIDs)
                Divider()
                CandidatesStrip(source: layouts)
            }
        } else {
            ContentUnavailableView("No Layout Open", systemImage: "doc.richtext",
                                   description: Text("Choose a layout, or start one with New Layout."))
        }
    }
}

/// Records the Layouts window in the model, and whether it is key (for menu items and shortcuts).
private struct LayoutsWindowReader: NSViewRepresentable {
    let layouts: LayoutsModel

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = { [weak layouts] window in
            if let window { layouts?.window = window }
            layouts?.isKey = window?.isKeyWindow ?? false
        }
        view.onKeyChange = { [weak layouts] isKey in
            guard let layouts else { return }
            if layouts.isKey != isKey { layouts.isKey = isKey }
            // The library may have changed meanwhile (a drive plugged back in): resolve again.
            if isKey { layouts.refreshFonts() }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        var onKeyChange: ((Bool) -> Void)?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        deinit {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            onWindow?(window)
            guard let window else { return }
            for (name, isKey) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onKeyChange?(isKey) }
                })
            }
        }
    }
}

/// Shown while a long PDF export runs.
private struct ExportProgressSheet: View {
    let layouts: LayoutsModel

    var body: some View {
        let progress = layouts.exportProgress ?? ExportProgress(done: 0, total: 1)
        VStack(alignment: .leading, spacing: 12) {
            Text("Exporting PDF").font(.headline)
            ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
            Text("Page \(min(progress.done + 1, progress.total)) of \(progress.total)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack {
                Spacer()
                Button("Cancel") { layouts.cancelExport() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .interactiveDismissDisabled()
    }
}
