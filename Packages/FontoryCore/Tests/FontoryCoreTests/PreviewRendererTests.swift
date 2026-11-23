import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FontoryCore

@Suite struct PreviewRendererTests {
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    func request(_ text: String, size: CGSize = CGSize(width: 600, height: 120), scale: CGFloat = 2) -> PreviewRequest {
        PreviewRequest(text: text, pointSize: 48, foreground: Self.black, background: Self.white, size: size, scale: scale)
    }

    func hasInk(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: px.count, by: 4) where px[i] != 255 || px[i + 1] != 255 || px[i + 2] != 255 { return true }
        return false
    }

    @Test func rendersNonBlankImage() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let url = try t.copy(TempFonts.arialBold)
        let img = try #require(PreviewRenderer().render(fileURL: url, faceIndex: 0, request: request("Hamburgefonstiv")))
        #expect(img.width == 1200 && img.height == 240)
        #expect(hasInk(img))
    }

    @Test func alignmentAndTrackingRender() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let url = try t.copy(TempFonts.arialBold)
        var r = request("Hamburgefonstiv"); r.alignment = .center; r.tracking = 4
        let img = try #require(PreviewRenderer().render(fileURL: url, faceIndex: 0, request: r))
        #expect(hasInk(img))
        r.alignment = .right
        #expect(PreviewRenderer().render(fileURL: url, faceIndex: 0, request: r) != nil)
    }

    @Test func vietnameseText() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let url = try t.copy(TempFonts.arialBold)
        #expect(PreviewRenderer().render(fileURL: url, faceIndex: 0, request: request("Chữ Việt có dấu")) != nil)
    }

    @Test func junkFileReturnsNil() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let url = try t.junk()
        #expect(PreviewRenderer().render(fileURL: url, faceIndex: 0, request: request("Hello")) == nil)
        #expect(PreviewRenderer().render(fileURL: url.appendingPathExtension("missing"), faceIndex: 0, request: request("Hello")) == nil)
    }

    @Test func failedLoadsAreNegativelyCached() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let junk = try t.junk()
        let missing = junk.appendingPathExtension("missing")
        let r = PreviewRenderer()
        for _ in 0..<3 {
            #expect(r.render(fileURL: junk, faceIndex: 0, request: request("Hello")) == nil)
            #expect(r.render(fileURL: missing, faceIndex: 0, request: request("Hello")) == nil)
            #expect(r.inkHeight(fileURL: junk, faceIndex: 0, text: "H", pointSize: 12) == 0)
        }
        #expect(r.fontLoadAttempts == 2)
        r.forgetFailures()
        #expect(r.render(fileURL: junk, faceIndex: 0, request: request("Hello")) == nil)
        #expect(r.fontLoadAttempts == 3)
    }

    @Test func successfulLoadIsAttemptedOnce() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let url = try t.copy(TempFonts.arialBold)
        let r = PreviewRenderer()
        _ = r.render(fileURL: url, faceIndex: 0, request: request("A"))
        _ = r.render(fileURL: url, faceIndex: 0, request: request("B"))
        #expect(r.fontLoadAttempts == 1)
    }

    @Test func forgetFontsUnderDropsOnlyThatTree() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let inside = try t.copy(TempFonts.arialBold, as: "Vol/Arial Bold.ttf")
        let sibling = try t.copy(TempFonts.arialBold, as: "Volume2/Arial Bold.ttf")  // shares the "Vol" prefix as text only
        let junk = try t.junk("Vol/junk.ttf")
        let r = PreviewRenderer()
        _ = r.render(fileURL: inside, faceIndex: 0, request: request("A"))
        _ = r.render(fileURL: sibling, faceIndex: 0, request: request("A"))
        _ = r.render(fileURL: junk, faceIndex: 0, request: request("A"))
        #expect(r.fontLoadAttempts == 3)
        r.forgetFonts(under: t.root.appendingPathComponent("Vol"))
        _ = r.render(fileURL: sibling, faceIndex: 0, request: request("B"))
        #expect(r.fontLoadAttempts == 3)  // still cached
        _ = r.render(fileURL: inside, faceIndex: 0, request: request("B"))
        _ = r.render(fileURL: junk, faceIndex: 0, request: request("B"))
        #expect(r.fontLoadAttempts == 5)  // loaded again, failure retried
        r.forgetAllFonts()
        _ = r.render(fileURL: sibling, faceIndex: 0, request: request("C"))
        #expect(r.fontLoadAttempts == 6)
    }

    @Test func requestHashesByColorComponents() {
        let a = request("x")
        var b = request("x")
        b.foreground = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        #expect(a == b && a.hashValue == b.hashValue)
        b.foreground = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(a != b)
        // A gray color equals the same color expressed in sRGB.
        var c = request("x")
        c.background = CGColor(gray: 1, alpha: 1)
        #expect(c == a && c.hashValue == a.hashValue)
    }

    @Test func inkHeightScalesLinearly() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let url = try t.copy(TempFonts.arialBold)
        let r = PreviewRenderer()
        let h24 = r.inkHeight(fileURL: url, faceIndex: 0, text: "Hxg", pointSize: 24)
        let h48 = r.inkHeight(fileURL: url, faceIndex: 0, text: "Hxg", pointSize: 48)
        #expect(h24 > 0)
        #expect(abs(h48 / h24 - 2) < 0.04)
    }

    @Test func sampleTextPicksScript() {
        let cyr = Int64(1) << 3
        let s = PreviewRenderer.sampleText(for: cyr, fallback: "Fallback")
        #expect(s != "Fallback")
        #expect(s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) })
        #expect(PreviewRenderer.sampleText(for: 1, fallback: "Fallback") == "Fallback")
        #expect(PreviewRenderer.sampleText(for: 0, fallback: "Fallback") == "Fallback")
        #expect(PreviewRenderer.sampleText(for: 1 | cyr, fallback: "Fallback") == "Fallback")
    }
}
