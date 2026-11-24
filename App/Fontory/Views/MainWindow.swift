import AppKit
import FontoryCore
import SwiftUI

struct MainWindow: View {
    static let id = "main"

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var presetName = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 380)
        } detail: {
            // The browser stays alive (hidden) under the family page, so Back finds its scroll position and selection.
            let browserHidden = model.detail != nil || model.isShowingDuplicates
            ZStack {
                // Grid and list are the same card view: the list keeps one font per row. Each mode keeps its own size.
                let mode = model.viewMode
                FontGridView(model: model, faceIDs: model.faceIDs, rowsVersion: model.rowsVersion, mode: mode,
                             zoom: model.zoom[mode] ?? AppModel.defaultZoom, preview: model.preview,
                             selection: model.selection, quickCollection: model.quickCollectionIDs, query: model.query,
                             isHidden: browserHidden)
                    .id(mode)
                if model.isShowingDuplicates {
                    DuplicatesView(model: model)
                        .background(.background)
                } else if let detail = model.detail {
                    FamilyDetailView(model: model, detail: detail)
                }
            }
        }
        .navigationTitle(model.isShowingDuplicates ? "Duplicates" : model.detail?.family ?? "Fontory")
        // The browser's font count, which follows the toolbar filters (sidebar counts do not).
        .navigationSubtitle(model.isShowingDuplicates ? duplicatesSubtitle : model.browserCountText)
        .onChange(of: colorScheme, initial: true) { _, scheme in model.isDarkAppearance = scheme == .dark }
        .background(BrowserWindowReader(model: model))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search fonts")
        .toolbar { BrowserToolbar(model: model) }
        .frame(minWidth: 820, minHeight: 480)
        .modelAlert(model, inSettings: false)
        .sheet(isPresented: Binding(get: { model.exportProgress != nil }, set: { _ in })) { ExportSheet() }
        .sheet(item: $model.tagPanel) { TagPanel(model: model, request: $0) }
        .sheet(item: $model.smartTagEditor) { SmartTagEditor(editor: $0, model: model) }
        .alert("Save Preview Text as Preset", isPresented: $model.isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                model.savePreset(named: presetName)
                presetName = ""
            }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text(model.preview.text)
        }
    }

    private var duplicatesSubtitle: String {
        let n = model.duplicateGroups.count
        return "\(n.formatted()) group\(n == 1 ? "" : "s")"
    }
}

/// Records the window it is placed in as the model's browser window, and whether it is key (for menu items).
private struct BrowserWindowReader: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = { [weak model] window in
            if let window { model?.browserWindow = window }
            model?.isBrowserKey = window?.isKeyWindow ?? false
        }
        view.onKeyChange = { [weak model] isKey in
            if model?.isBrowserKey != isKey { model?.isBrowserKey = isKey }
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
            if let window {
                for (name, isKey) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.onKeyChange?(isKey) }
                    })
                }
            }
            onWindow?(window)
        }
    }
}

/// Presents `AppModel.alert` on exactly one window: Settings while it is the key window, the main window otherwise.
private struct ModelAlert: ViewModifier {
    let model: AppModel
    let inSettings: Bool
    /// The smart tag editor sheet presents the alerts while it is shown (the window behind it cannot).
    var inSheet = false

    func body(content: Content) -> some View {
        content.alert(model.alert?.title ?? "", isPresented: presented, presenting: model.alert) { item in
            if let title = item.actionTitle, let action = item.action {
                Button(title, role: item.isDestructive ? .destructive : nil) { action() }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { item in
            Text(item.message)
        }
    }

    private var presented: Binding<Bool> {
        Binding(get: { model.alert != nil && Self.settingsIsKey == inSettings
                        && (inSettings || (model.smartTagEditor != nil) == inSheet) },
                set: { if !$0 { model.alert = nil } })
    }

    private static var settingsIsKey: Bool {
        NSApp.keyWindow?.identifier?.rawValue.contains("Settings") == true
    }
}

extension View {
    func modelAlert(_ model: AppModel, inSettings: Bool, inSheet: Bool = false) -> some View {
        modifier(ModelAlert(model: model, inSettings: inSettings, inSheet: inSheet))
    }
}
