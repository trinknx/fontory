import AppKit
import FontoryCore
import SwiftUI

/// Settings → Backups: Back Up Now, Restore from File, the automatic and safety backups with Restore and Show in
/// Finder, and "Also restore activation".
struct BackupsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Back Up Now…") { model.showBackUpPanel() }
                Button("Restore from File…") { model.showRestorePanel() }
                    .disabled(model.restoreState != nil)
                Spacer()
            }
            Text("Backups").font(.headline).padding(.top, 4)
            Text("Fontory backs up tags, notes, the Quick Collection and family names at launch and at quit, one file a day. Backups older than 10 days are deleted.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.backupEntries.isEmpty {
                Text("No backups yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.backupEntries, id: \.url) { entry in
                    BackupRow(entry: entry)
                }
            }
            Toggle("Also restore activation", isOn: $model.restoreActivation)
            Text("Fonts active in the backup are activated, and fonts active now but not in the backup are deactivated.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .task { await model.refreshBackupEntries() }
    }
}

private struct BackupRow: View {
    @Environment(AppModel.self) private var model
    let entry: BackupFiles.Entry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.date.formatted(date: .long, time: entry.isSafety ? .shortened : .omitted))
                    if entry.isSafety {
                        Text("Before restore")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") { model.confirmRestore(from: entry.url, date: entry.date, showsTime: entry.isSafety) }
                .controlSize(.small)
                .disabled(model.restoreState != nil)
            Button("Show in Finder") { model.revealFile(entry.url) }
                .controlSize(.small)
        }
    }
}
