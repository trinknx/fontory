import FontoryCore
import SwiftUI

/// A restore's progress (reading, re-adding locations, scanning, applying) with Cancel, then its summary or failure.
struct RestoreSheet: View {
    @Environment(AppModel.self) private var model
    @State private var showsNotFound = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.restoreState {
            case .finished(let result):
                summary(result)
            case .failed(let message):
                Text("The library could not be restored").font(.headline)
                Text(message).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("OK") { model.dismissRestore() }.keyboardShortcut(.defaultAction)
                }
            case let state?:
                progress(state)
            case nil:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func progress(_ state: RestoreState) -> some View {
        Text("Restoring the library").font(.headline)
        switch state {
        case .scanning(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Scanning re-added locations… \(done) of \(total)")
            }
        default:
            ProgressView { Text(label(state)) }.progressViewStyle(.linear)
        }
        HStack {
            Spacer()
            Button("Cancel") { model.cancelRestore() }
                .keyboardShortcut(.cancelAction)
                .disabled(state == .applying)
        }
    }

    private func label(_ state: RestoreState) -> String {
        switch state {
        case .reading: "Reading the backup…"
        case .addingLocations: "Adding locations…"
        case .applying: "Applying…"
        default: ""
        }
    }

    @ViewBuilder
    private func summary(_ result: RestoreResult) -> some View {
        Text("Library restored").font(.headline)
        Text("Restored \(result.tagCount) tags, \(result.restoredFaceCount) fonts with notes or tags. \(result.notFound.count) fonts not found.")
            .fixedSize(horizontal: false, vertical: true)
        if !result.unreachableLocations.isEmpty {
            Text("Not reachable: \(result.unreachableLocations.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if showsNotFound {
            List(result.notFound.indices, id: \.self) { i in
                Text(result.notFound[i]).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            .frame(height: 160)
        }
        HStack {
            if !result.notFound.isEmpty {
                Button(showsNotFound ? "Hide Not Found" : "Show Not Found") { showsNotFound.toggle() }
            }
            Spacer()
            Button("Done") { model.dismissRestore() }.keyboardShortcut(.defaultAction)
        }
    }
}
