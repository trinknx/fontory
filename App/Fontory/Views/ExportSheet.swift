import SwiftUI

/// A large export's progress with Cancel.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.exportProgress ?? (done: 0, total: 1)
        VStack(alignment: .leading, spacing: 12) {
            Text("Exporting fonts").font(.headline)
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                Text("\(p.done.formatted()) of \(p.total.formatted())").monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelExport() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }
}
