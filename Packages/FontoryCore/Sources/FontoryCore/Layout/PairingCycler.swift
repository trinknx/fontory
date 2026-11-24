import Foundation

/// The pure part of cycling a block's font: ←/→ through candidate families, ↑/↓ through a family's styles.
public enum PairingCycler {
    /// The next candidate family, wrapping around. A current font whose family is not a candidate goes to the
    /// first (forward) or last (back) candidate. Nil with no candidates; a single candidate returns itself.
    public static func nextFamily(from current: FontReference, candidates: [FontReference], step: Int) -> FontReference? {
        guard !candidates.isEmpty else { return nil }
        let key = current.family.lowercased()
        guard let i = candidates.firstIndex(where: { $0.family.lowercased() == key }) else {
            return step >= 0 ? candidates.first : candidates.last
        }
        return candidates[wrap(i + step, candidates.count)]
    }

    /// The next style, wrapping around; a single style returns itself, no styles return `current`.
    public static func nextStyle(current: FontReference, styles: [PairingStyle], step: Int) -> FontReference {
        guard !styles.isEmpty else { return current }
        let i = styles.firstIndex { $0.reference == current }
            ?? styles.firstIndex { $0.reference.postScriptName == current.postScriptName && $0.reference.variations == nil }
            ?? styles.firstIndex { $0.reference.postScriptName == current.postScriptName }
        guard let i else { return step >= 0 ? styles[0].reference : styles[styles.count - 1].reference }
        return styles[wrap(i + step, styles.count)].reference
    }

    /// The style nearest `current`: italic match first, then the nearest weight, then the nearest width.
    public static func closestStyle(to current: PairingStyle, in styles: [PairingStyle]) -> FontReference {
        let best = styles.min { a, b in
            score(a, current) < score(b, current)
        }
        return best?.reference ?? current.reference
    }

    /// `existing` plus the families of `adding` it does not have yet (compared lowercased), in order.
    public static func merge(_ existing: [FontReference], adding: [FontReference]) -> [FontReference] {
        var seen = Set(existing.map { $0.family.lowercased() })
        var out = existing
        for ref in adding where seen.insert(ref.family.lowercased()).inserted { out.append(ref) }
        return out
    }

    private static func score(_ s: PairingStyle, _ target: PairingStyle) -> (Int, Double, Double) {
        (s.isItalic == target.isItalic ? 0 : 1, abs(s.weight - target.weight), abs(s.width - target.width))
    }

    private static func wrap(_ i: Int, _ n: Int) -> Int { ((i % n) + n) % n }
}
