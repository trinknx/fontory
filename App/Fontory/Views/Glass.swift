import SwiftUI

/// Liquid Glass for Fontory's own controls (macOS 26+). Glass belongs to the control layer only: font previews,
/// glyphs and specimens keep their solid backgrounds. Before macOS 26 the controls keep their flat look.
extension View {
    /// Puts `bar` along the bottom: a floating glass bar over the content on macOS 26+, else a plain bar
    /// under a divider.
    @ViewBuilder
    func glassBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaInset(edge: .bottom, spacing: 0) {
                bar()
                    .padding(.horizontal, 4)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .padding(.top, 6)
            }
        } else {
            VStack(spacing: 0) {
                self
                Divider()
                bar()
            }
        }
    }

    /// Glass behind a small control group in `shape` (macOS 26+), else `fallback` filling it.
    @ViewBuilder
    func glassBackground<S: Shape>(in shape: S, fallback: Color) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(shape.fill(fallback))
        }
    }
}
