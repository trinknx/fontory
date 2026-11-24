import AppKit
import FontoryCore
import SwiftUI
import UniformTypeIdentifiers

/// The Pairing Studio's candidates under the canvas: each family's name drawn in its own font (rendered off the
/// main thread). A click applies the candidate to the selected block and selects it in the strip; ⌫ removes the
/// selected one. Fonts dragged from the browser are added as candidates.
///
/// Focus: a click does not move the keyboard focus to the strip, so ←/→/↑/↓ keep cycling on the page after
/// picking a candidate. The strip takes focus only when the user focuses it explicitly (Tab / keyboard
/// navigation, or AppKit giving a clicked focusable view focus); while it has focus the arrow keys are forwarded
/// to the same family/style cycling as on the page, and ⌫ removes the selected candidate. The context menu's
/// Remove works either way.
struct CandidatesStrip: View {
    static let pointSize: CGFloat = 18

    let layouts: LayoutsModel
    @State private var selected: FontReference?
    @State private var isTargeted = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if layouts.candidates.isEmpty {
                    Text("No candidates. Press ⌘K in the browser, or drag fonts here.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                ForEach(layouts.candidates, id: \.self) { candidate in
                    CandidateItem(layouts: layouts, candidate: candidate,
                                  isSelected: selected == candidate,
                                  isCurrent: isCurrent(candidate))
                        .onTapGesture {
                            selected = candidate
                            Task { await layouts.applyCandidate(candidate) }
                        }
                        .contextMenu {
                            Button("Apply to All Blocks") { Task { await layouts.applyFamilyToAll(candidate) } }
                            Divider()
                            Button("Remove") { remove(candidate) }
                        }
                }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 52)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onDeleteCommand { if let selected { remove(selected) } }
        .onMoveCommand { direction in
            if let key = Self.cycleKey(direction) { layouts.cycle(key) }
        }
        .onDrop(of: [.fontoryFaceIDs], isTargeted: $isTargeted) { providers in
            FaceDrag.load(providers) { ids in Task { await layouts.addCandidates(faceIDs: ids) } }
        }
        .onChange(of: layouts.candidates) { _, candidates in
            if let selected, !candidates.contains(selected) { self.selected = nil }
        }
        .help("Candidates: click one to apply it to the selected block; ⌫ removes the selected one. ←/→ on the page cycle them.")
    }

    /// The page's arrow mapping (←/→ families, ↑/↓ styles), for arrows pressed while the strip has focus.
    static func cycleKey(_ direction: MoveCommandDirection) -> LayoutsModel.CycleKey? {
        switch direction {
        case .left: .family(-1)
        case .right: .family(1)
        case .up: .style(-1)
        case .down: .style(1)
        @unknown default: nil
        }
    }

    private func isCurrent(_ candidate: FontReference) -> Bool {
        guard let font = layouts.selectedBlock?.font else { return false }
        return font.family.lowercased() == candidate.family.lowercased()
    }

    private func remove(_ candidate: FontReference) {
        layouts.removeCandidate(candidate)
        selected = nil
    }
}

/// One candidate: its family name as a template image in its own font (the plain name until it is drawn).
private struct CandidateItem: View {
    let layouts: LayoutsModel
    let candidate: FontReference
    let isSelected: Bool
    let isCurrent: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .renderingMode(.template)
            } else {
                Text(candidate.family).font(.system(size: CandidatesStrip.pointSize))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(isCurrent ? 0.08 : 0.0001)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .help(candidate.family)
        .task(id: TaskKey(candidate: candidate, scale: displayScale, fontsVersion: layouts.fontsVersion)) {
            image = await layouts.candidateImage(for: candidate, pointSize: CandidatesStrip.pointSize, scale: displayScale)
        }
    }

    private struct TaskKey: Equatable {
        var candidate: FontReference
        var scale: CGFloat
        var fontsVersion: Int
    }
}
