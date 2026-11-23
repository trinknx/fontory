import CoreText
import Foundation

/// The design axes and named instances of a variable font, from its `fvar` table (names from `name`), with
/// `CTFontCopyVariationAxes` as the fallback for the axes when `fvar` is missing or unreadable.
///
/// Parsing is bounds-checked: an inconsistent axis array (past the end, bad version, min > default > max) yields no
/// axes; instance records that do not fit are dropped, the axes kept.
public struct VariationInfo: Sendable, Equatable {
    public struct Axis: Sendable, Hashable, Identifiable {
        public var tag: String
        /// The tag as a big-endian code, the key of `kCTFontVariationAttribute`.
        public var code: UInt32
        public var name: String
        public var minValue: Double
        public var defaultValue: Double
        public var maxValue: Double
        /// The font asks not to show this axis in UIs (`HIDDEN_AXIS` flag).
        public var isHidden: Bool

        public var id: UInt32 { code }

        public init(tag: String, name: String, minValue: Double, defaultValue: Double, maxValue: Double,
                    isHidden: Bool = false) {
            self.tag = tag
            self.code = VariationInfo.code(tag)
            self.name = name
            self.minValue = minValue
            self.defaultValue = defaultValue
            self.maxValue = maxValue
            self.isHidden = isHidden
        }

        public func clamped(_ value: Double) -> Double { Swift.min(maxValue, Swift.max(minValue, value)) }

        /// A slider step that suits the range: 1 for ranges of 100 or more, then 0.1, then 0.01.
        public var step: Double {
            let range = maxValue - minValue
            return range >= 100 ? 1 : range >= 10 ? 0.1 : 0.01
        }
    }

    public struct Instance: Sendable, Hashable, Identifiable {
        /// Position in `fvar`.
        public var index: Int
        public var name: String
        /// Axis code → coordinate, one per axis, clamped to the axis range.
        public var coordinates: [UInt32: Double]
        public var postScriptName: String?

        public var id: Int { index }
    }

    public var axes: [Axis]
    public var instances: [Instance]

    public init(axes: [Axis], instances: [Instance]) {
        self.axes = axes
        self.instances = instances
    }

    public static let empty = VariationInfo(axes: [], instances: [])

    public var isVariable: Bool { !axes.isEmpty }

    /// Every axis at its default.
    public var defaults: [UInt32: Double] {
        Dictionary(uniqueKeysWithValues: axes.map { ($0.code, $0.defaultValue) })
    }

    // MARK: Reading

    /// The axes and instances of a face.
    public static func read(_ font: CTFont) -> VariationInfo {
        let parsed = parse(fvar: SfntReader.table("fvar", of: font), name: SfntReader.table("name", of: font))
        let coreText = coreTextAxes(font)
        guard parsed.isVariable else { return VariationInfo(axes: coreText, instances: []) }
        // Axes whose name the name table lacks take CoreText's (localized) name.
        var out = parsed
        for i in out.axes.indices where out.axes[i].name == out.axes[i].tag {
            if let ct = coreText.first(where: { $0.code == out.axes[i].code }), !ct.name.isEmpty { out.axes[i].name = ct.name }
        }
        return out
    }

    /// The axes from `CTFontCopyVariationAxes` (no instances).
    static func coreTextAxes(_ font: CTFont) -> [Axis] {
        guard let list = CTFontCopyVariationAxes(font) as? [[String: Any]] else { return [] }
        return list.compactMap { axis in
            guard let id = (axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value,
                  let min = (axis[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue,
                  let max = (axis[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue,
                  min <= max
            else { return nil }
            let def = (axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue ?? min
            let tag = tagString(id)
            let name = axis[kCTFontVariationAxisNameKey as String] as? String
            let hidden = (axis[kCTFontVariationAxisHiddenKey as String] as? NSNumber)?.boolValue ?? false
            return Axis(tag: tag, name: name ?? knownName(tag) ?? tag, minValue: min,
                        defaultValue: Swift.min(max, Swift.max(min, def)), maxValue: max, isHidden: hidden)
        }
    }

    /// The axes and instances from raw `fvar` and `name` tables (either may be missing).
    public static func parse(fvar: SfntReader?, name: SfntReader?) -> VariationInfo {
        guard let r = fvar, let major = r.u16(0), major == 1, let axesOffset = r.u16(4), let axisCount = r.u16(8),
              let axisSize = r.u16(10), let instanceCount = r.u16(12), let instanceSize = r.u16(14),
              axisCount > 0, axisSize >= 20, axesOffset >= 16
        else { return .empty }
        let names = name.flatMap(NameTable.init)
        func fixed(_ offset: Int) -> Double? { r.u32(offset).map { Double(Int32(bitPattern: $0)) / 65536 } }

        var axes: [Axis] = []
        for i in 0..<Int(axisCount) {
            let o = Int(axesOffset) + i * Int(axisSize)
            guard let tag = r.tag(o), let min = fixed(o + 4), let def = fixed(o + 8), let max = fixed(o + 12),
                  let flags = r.u16(o + 16), let nameID = r.u16(o + 18), min <= def, def <= max
            else { return .empty }
            let label = names?.string(nameID) ?? knownName(tag) ?? tag
            axes.append(Axis(tag: tag, name: label, minValue: min, defaultValue: def, maxValue: max,
                             isHidden: flags & 1 != 0))
        }
        // Instances follow the axis array. Records too small for the coordinates make the list unusable.
        var instances: [Instance] = []
        let coordsSize = 4 + Int(axisCount) * 4
        if Int(instanceSize) >= coordsSize {
            let hasPSName = Int(instanceSize) >= coordsSize + 2
            let base = Int(axesOffset) + Int(axisCount) * Int(axisSize)
            for i in 0..<Int(instanceCount) {
                let o = base + i * Int(instanceSize)
                guard r.slice(o, Int(instanceSize)) != nil, let subfamilyID = r.u16(o) else { break }
                var coordinates: [UInt32: Double] = [:]
                for (j, axis) in axes.enumerated() {
                    guard let v = fixed(o + 4 + j * 4) else { break }
                    coordinates[axis.code] = axis.clamped(v)
                }
                guard coordinates.count == axes.count else { break }
                var psName: String?
                if hasPSName, let id = r.u16(o + coordsSize), id != 0xFFFF { psName = names?.string(id) }
                let label = names?.string(subfamilyID) ?? "Instance \(i + 1)"
                instances.append(Instance(index: i, name: label, coordinates: coordinates, postScriptName: psName))
            }
        }
        return VariationInfo(axes: axes, instances: instances)
    }

    // MARK: Using the coordinates

    /// The named instance at exactly `values` (every axis within 0.001), if any.
    public func instance(matching values: [UInt32: Double]) -> Instance? {
        instances.first { instance in
            axes.allSatisfy { axis in
                let v = values[axis.code] ?? axis.defaultValue
                let c = instance.coordinates[axis.code] ?? axis.defaultValue
                return abs(v - c) < 0.001
            }
        }
    }

    /// Where Option-drag stops on an axis: its min, default, max and every instance's coordinate, sorted, unique.
    public func stops(for axis: Axis) -> [Double] {
        let values = [axis.minValue, axis.defaultValue, axis.maxValue] + instances.compactMap { $0.coordinates[axis.code] }
        return Array(Set(values)).sorted()
    }

    /// The stop nearest to `value` when it lies within `threshold`, else `value`.
    public static func snap(_ value: Double, to stops: [Double], threshold: Double) -> Double {
        guard let nearest = stops.min(by: { abs($0 - value) < abs($1 - value) }), abs(nearest - value) <= threshold
        else { return value }
        return nearest
    }

    /// `font-variation-settings` for the axes whose value differs from the default, in `fvar` order; `normal` when
    /// none does. Axes in `omitting` are left out (an automatic optical size).
    public func css(values: [UInt32: Double], omitting: Set<UInt32> = []) -> String {
        let parts = axes.compactMap { axis -> String? in
            guard !omitting.contains(axis.code), let v = values[axis.code], abs(v - axis.defaultValue) >= 0.005 else { return nil }
            return "\"\(axis.tag)\" \(Self.format(v))"
        }
        return "font-variation-settings: \(parts.isEmpty ? "normal" : parts.joined(separator: ", "));"
    }

    /// A coordinate as CSS writes it: at most two decimals, no trailing zeros, `.` as the separator.
    public static func format(_ value: Double) -> String {
        var s = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    // MARK: Tags

    public static func code(_ tag: String) -> UInt32 {
        tag.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    public static func tagString(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The registered axes' names.
    static func knownName(_ tag: String) -> String? {
        switch tag {
        case "wght": "Weight"
        case "wdth": "Width"
        case "ital": "Italic"
        case "slnt": "Slant"
        case "opsz": "Optical Size"
        default: nil
        }
    }

    public static let opticalSize = code("opsz")
}
