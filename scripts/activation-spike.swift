import Foundation
import CoreText

// Usage: swift scripts/activation-spike.swift /path/to/font.otf
// Registers the font with .session scope, waits, unregisters, waits, exits.

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: activation-spike.swift <font-path>\n".utf8))
    exit(2)
}
let path = CommandLine.arguments[1]
guard FileManager.default.fileExists(atPath: path) else {
    FileHandle.standardError.write(Data("error: no such file: \(path)\n".utf8))
    exit(1)
}
let url = URL(fileURLWithPath: path)

if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
    for d in descs {
        if let n = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String { print("PostScript name: \(n)") }
    }
}

CTFontManagerRegisterFontURLs([url] as CFArray, .session, true, { errors, done in
    for e in errors as? [Error] ?? [] { print("register error: \(e)") }
    return true
})
print("register requested. Check each app's font menu, then press Enter to unregister.")
_ = readLine()

CTFontManagerUnregisterFontURLs([url] as CFArray, .session, { errors, done in
    for e in errors as? [Error] ?? [] { print("unregister error: \(e)") }
    return true
})
print("unregistered. Check fonts disappeared, then press Enter to exit.")
_ = readLine()
