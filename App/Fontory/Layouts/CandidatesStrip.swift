import AppKit
import FontoryCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The point size candidate names are drawn at.
let candidateStripPointSize: CGFloat = 18

/// What an arrow key does to the current font: ←/→ the previous/next family, ↑/↓ the previous/next style.
/// `referenceStyle` (Compare's Shift+↑/↓) is handled by the Compare canvas; Layouts ignores it.
enum CycleKey: Equatable, Sendable {
    case family(Int)
    case style(Int)
    case referenceStyle(Int)
}

/// What a candidates strip needs from its owner (the Layouts window, the Compare window).
@MainActor protocol CandidateStripSource: AnyObject {
    var candidates: [FontReference] { get }
    var fontsVersion: Int { get }
    var emptyCandidatesMessage: String { get }
    var stripHelp: String { get }
    func isCurrentCandidate(_ ref: FontReference) -> Bool
    func pickCandidate(_ ref: FontReference) async
    func removeCandidate(_ ref: FontReference)
    func addCandidates(faceIDs: [Int64]) async
    func cycle(_ key: CycleKey)
    func candidateImage(for ref: FontReference, pointSize: CGFloat, scale: CGFloat) async -> CGImage?
    /// Extra context-menu items (Layouts: "Apply to All Blocks"); default none.
    func extraMenuItems(for ref: FontReference) -> [(title: String, action: @MainActor () -> Void)]
}

extension CandidateStripSource {
    func extraMenuItems(for ref: FontReference) -> [(title: String, action: @MainActor () -> Void)] { [] }
}

/// The candidates under the canvas (Pairing Studio, Compare): each family's name drawn in its own font (rendered off the
/// main thread). A click applies the candidate to the selected block and selects it in the strip; ⌫ removes the
/// selected one. Fonts dragged from the browser are added as candidates.
///
/// Focus: a click does not move the keyboard focus to the strip, so ←/→/↑/↓ keep cycling on the page after
/// picking a candidate. The strip takes focus only when the user focuses it explicitly (Tab / keyboard
/// navigation, or AppKit giving a clicked focusable view focus); while it has focus the arrow keys are forwarded
/// to the same family/style cycling as on the page, and ⌫ removes the selected candidate. The context menu's
/// Remove works either way.
struct CandidatesStrip<Source: CandidateStripSource & Observable>: View {
    let source: Source
    @State private var selected: FontReference?
    @State private var isTargeted = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if source.candidates.isEmpty {
                    Text(source.emptyCandidatesMessage)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                ForEach(source.candidates, id: \.self) { candidate in
                    CandidateItem(source: source, candidate: candidate,
                                  isSelected: selected == candidate,
                                  isCurrent: source.isCurrentCandidate(candidate))
                        .onTapGesture {
                            selected = candidate
                            Task { await source.pickCandidate(candidate) }
                        }
                        .contextMenu {
                            let extras = source.extraMenuItems(for: candidate)
                            ForEach(extras.indices, id: \.self) { index in
                                Button(extras[index].title) { extras[index].action() }
                            }
                            if !extras.isEmpty { Divider() }
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
            if let key = Self.cycleKey(direction) { source.cycle(key) }
        }
        .onDrop(of: [.fontoryFaceIDs], isTargeted: $isTargeted) { providers in
            FaceDrag.load(providers) { ids in Task { await source.addCandidates(faceIDs: ids) } }
        }
        .onChange(of: source.candidates) { _, candidates in
            if let selected, !candidates.contains(selected) { self.selected = nil }
        }
        .help(source.stripHelp)
    }

    /// The page's arrow mapping (←/→ families, ↑/↓ styles), for arrows pressed while the strip has focus.
    static func cycleKey(_ direction: MoveCommandDirection) -> CycleKey? {
        switch direction {
        case .left: .family(-1)
        case .right: .family(1)
        case .up: .style(-1)
        case .down: .style(1)
        @unknown default: nil
        }
    }

    private func remove(_ candidate: FontReference) {
        source.removeCandidate(candidate)
        selected = nil
    }
}

/// One candidate: its family name as a template image in its own font (the plain name until it is drawn).
private struct CandidateItem<Source: CandidateStripSource & Observable>: View {
    let source: Source
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
                Text(candidate.family).font(.system(size: candidateStripPointSize))
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
        .task(id: TaskKey(candidate: candidate, scale: displayScale, fontsVersion: source.fontsVersion)) {
            image = await source.candidateImage(for: candidate, pointSize: candidateStripPointSize, scale: displayScale)
        }
    }

    private struct TaskKey: Equatable {
        var candidate: FontReference
        var scale: CGFloat
        var fontsVersion: Int
    }
}
