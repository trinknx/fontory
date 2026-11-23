import Foundation

/// Preview text presets: fixed samples, a pangram or genuine sample sentence per language, and the per-face
/// "dynamic" sample chosen by script coverage.
public enum PreviewSamples {
    public struct Sample: Sendable, Hashable, Identifiable {
        public let name: String
        public let text: String
        public var id: String { name }
        public init(name: String, text: String) { self.name = name; self.text = text }
    }

    public static let hamburgefonstiv = Sample(name: "Hamburgefonstiv", text: "Hamburgefonstiv")
    public static let lowercase = Sample(name: "Lowercase", text: "abcdefghijklmnopqrstuvwxyz")
    public static let uppercase = Sample(name: "Uppercase", text: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    public static let accented = Sample(
        name: "Accented",
        text: "ÀÁÂÃÄÅ Çç ÈÉÊË ÌÍÎÏ Ññ ÒÓÔÕÖØ ÙÚÛÜ Ýÿ àáâãäå èéêë ìíîï òóôõöø ùúûü ăâđêôơư ạảấầẩẫậắằẳẵặ ẹẻẽếềểễệ ỉị ọỏốồổỗộớờởỡợ ụủứừửữự ỳỵỷỹ")
    public static let numbers = Sample(name: "Numbers", text: "0123456789 ½ ¼ ¾ ⅛ ⁰¹²³⁴ ₀₁₂₃₄ +−×÷=%‰")
    public static let punctuation = Sample(name: "Punctuation", text: "! ? ¡ ¿ . , : ; … – — ' \" ‘ ’ “ ” « » ‹ › ( ) [ ] { } / \\ | @ # & * § ¶ † ‡ •")
    public static let currencies = Sample(name: "Currencies", text: "$ € £ ¥ ¢ ₫ ₩ ₹ ₽ ₺ ₪ ₱ ₦ ₴ ₸ ฿ ₿ ¤")

    /// Shown after Font Names in the preset menu.
    public static let letterSets: [Sample] = [hamburgefonstiv, lowercase, uppercase, accented]
    /// The second group of the preset menu.
    public static let symbolSets: [Sample] = [numbers, punctuation, currencies]

    /// One pangram or well-known sample sentence per language, by English name.
    public static let languages: [Sample] = [
        Sample(name: "Arabic", text: "صف خلق خود كمثل الشمس إذ بزغت يحظى الضجيع بها نجلاء معطار"),
        Sample(name: "Chinese (Simplified)", text: "天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。"),
        Sample(name: "Chinese (Traditional)", text: "天地玄黃，宇宙洪荒。日月盈昃，辰宿列張。"),
        Sample(name: "Danish", text: "Høj bly gom vandt fræk sexquiz på wc."),
        Sample(name: "Dutch", text: "Pa's wijze lynx bezag vroom het fikse aquaduct."),
        Sample(name: "English", text: "The quick brown fox jumps over the lazy dog."),
        Sample(name: "Finnish", text: "Wieniläinen sioux'ta puhuva ökyzombie diggaa Åsan roquefort-tacoja."),
        Sample(name: "French", text: "Portez ce vieux whisky au juge blond qui fume."),
        Sample(name: "German", text: "Victor jagt zwölf Boxkämpfer quer über den großen Sylter Deich."),
        Sample(name: "Greek", text: "Ξεσκεπάζω την ψυχοφθόρα βδελυγμία."),
        Sample(name: "Hebrew", text: "דג סקרן שט בים מאוכזב ולפתע מצא חברה"),
        Sample(name: "Hungarian", text: "Árvíztűrő tükörfúrógép."),
        Sample(name: "Italian", text: "Quel vituperabile xenofobo zelante assaggia il whisky ed esclama: alleluja!"),
        Sample(name: "Japanese", text: "いろはにほへと ちりぬるを わかよたれそ つねならむ"),
        Sample(name: "Korean", text: "키스의 고유조건은 입술끼리 만나야 하고 특별한 기술은 필요치 않다."),
        Sample(name: "Norwegian", text: "Vår sære Zulu fra badeøya spilte jo whist og quickstep i min taxi."),
        Sample(name: "Polish", text: "Pchnąć w tę łódź jeża lub ośm skrzyń fig."),
        Sample(name: "Portuguese", text: "Luís argüia à Júlia que «brações, fé, chá, óxido, pôr, zângão» eram palavras do português."),
        Sample(name: "Russian", text: "Съешь же ещё этих мягких французских булок, да выпей чаю."),
        Sample(name: "Spanish", text: "El veloz murciélago hindú comía feliz cardillo y kiwi."),
        Sample(name: "Swedish", text: "Flygande bäckasiner söka hwila på mjuka tuvor."),
        Sample(name: "Thai", text: "เป็นมนุษย์สุดประเสริฐเลิศคุณค่า"),
        Sample(name: "Turkish", text: "Pijamalı hasta yağız şoföre çabucak güvendi."),
        Sample(name: "Vietnamese", text: "Thủy thủ ngồi xếp bằng, khẽ vuốt râu và cười."),
    ]

    public static func language(_ name: String) -> Sample? {
        languages.first { $0.name == name }
    }

    /// What Latin faces show in Dynamic mode; faces without Latin show a phrase in a script they cover.
    public enum DynamicStyle: String, CaseIterable, Sendable, Codable {
        case automatic, pangram, accented

        public var title: String {
            switch self {
            case .automatic: "Automatic"
            case .pangram: "Pangram"
            case .accented: "Accented"
            }
        }

        public var latinText: String {
            switch self {
            case .automatic: "AaBbGg"
            case .pangram: "The quick brown fox jumps over the lazy dog"
            case .accented: "Àà Ćć Ëë Ğğ Ịị Ñń Ơơ Şş Ưư Žž"
            }
        }
    }

    /// The dynamic sample of a face: Latin faces get the style's text; others a phrase in a script they cover.
    public static func dynamicText(scriptsBitmask: Int64, style: DynamicStyle) -> String {
        PreviewRenderer.sampleText(for: scriptsBitmask, fallback: style.latinText)
    }
}
