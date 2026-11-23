import CoreText
import Foundation

/// Script coverage table. The index of each entry is its bit in `ParsedFace.scriptsBitmask`;
/// wave-3 filters and preview sample text rely on this order, so only ever append.
enum ScriptCoverage {
    struct Script: Sendable {
        let name: String
        let samples: String
    }

    /// A script's bit is set when at least this share of its sample characters is present.
    static let threshold = 0.8

    static let scripts: [Script] = [
        Script(name: "Latin", samples: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"),
        Script(name: "Latin-Vietnamese", samples: "ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ"),
        Script(name: "Greek", samples: "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩαβγδεζηθικλμνξοπρστυφχψω"),
        Script(name: "Cyrillic", samples: "АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЭЮЯабвгдежзийклмнопрстуфхцчшщэюя"),
        Script(name: "Arabic", samples: "ابتثجحخدذرزسشصضطظعغفقكلمنهوي"),
        Script(name: "Hebrew", samples: "אבגדהוזחטיכלמנסעפצקרשת"),
        Script(name: "Thai", samples: "กขคงจฉชซญดตทนบปผพมยรลวสหอฮ"),
        Script(name: "Devanagari", samples: "अआइईउऊएऐओऔकखगघचछजझटठडढणतथदधनपफबभमयरलवशषसह"),
        Script(name: "Han", samples: "的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但身些与高意进把法此实回二理美点月明其种声全工"),
        Script(name: "Hiragana/Katakana", samples: "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをんアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン"),
        Script(name: "Hangul", samples: "가나다라마바사아자차카타파하한글대한민국서울거너더러머버서어저처커터퍼허"),
        Script(name: "Symbols", samples: "©®™°±×÷€£¥§¶•†‡←↑→↓∞≠≤≥∑√∫"),
    ]

    static func bitmask(for font: CTFont) -> Int64 {
        let set = CTFontCopyCharacterSet(font) as CharacterSet
        var mask: Int64 = 0
        for (bit, script) in scripts.enumerated() {
            let scalars = Array(Set(script.samples.unicodeScalars))
            guard !scalars.isEmpty else { continue }
            let present = scalars.filter { set.contains($0) }.count
            if Double(present) >= threshold * Double(scalars.count) { mask |= Int64(1) << Int64(bit) }
        }
        return mask
    }
}
