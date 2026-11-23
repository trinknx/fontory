import AppKit
import FontoryCore
import SwiftUI

struct MainWindow: View {
    static let id = "main"

    @Environment(AppModel.self) private var model
    @State private var presetName = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 380)
        } detail: {
            switch model.viewMode {
            case .grid:
                FontGridView(model: model, faceIDs: model.faceIDs, rowsVersion: model.rowsVersion,
                             zoom: model.zoom[.grid] ?? AppModel.defaultZoom, preview: model.preview,
                             selection: model.selection, query: model.query)
            case .list:
                FontListView(model: model, families: model.families, rowsVersion: model.rowsVersion,
                             zoom: model.zoom[.list] ?? AppModel.defaultZoom, preview: model.preview,
                             selection: model.selection, query: model.query)
            }
        }
        .background(BrowserWindowReader(model: model))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search fonts")
        .toolbar { BrowserToolbar(model: model) }
        .frame(minWidth: 820, minHeight: 480)
        .modelAlert(model, inSettings: false)
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
}

/// Records the window it is placed in as the model's browser window.
private struct BrowserWindowReader: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = { [weak model] window in
            if let window { model?.browserWindow = window }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

/// Presents `AppModel.alert` on exactly one window: Settings while it is the key window, the main window otherwise.
private struct ModelAlert: ViewModifier {
    let model: AppModel
    let inSettings: Bool

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
        Binding(get: { model.alert != nil && Self.settingsIsKey == inSettings },
                set: { if !$0 { model.alert = nil } })
    }

    private static var settingsIsKey: Bool {
        NSApp.keyWindow?.identifier?.rawValue.contains("Settings") == true
    }
}

extension View {
    func modelAlert(_ model: AppModel, inSettings: Bool) -> some View {
        modifier(ModelAlert(model: model, inSettings: inSettings))
    }
}
