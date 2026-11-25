import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing

@testable import FontoryCore

@Suite struct GlyphImageTests {
    private func font(_ path: String) throws -> CTFont {
        try #require(FontFile.font(at: URL(fileURLWithPath: path), faceIndex: 0, size: 12))
    }

    private func glyph(_ font: CTFont, _ s: String) throws -> CGGlyph {
        var chars = Array(s.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        #expect(CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count))
        return glyphs[0]
    }

    /// Decoded RGBA8 premultiplied pixels with width and height.
    private func pixels(_ data: Data) throws -> (px: [UInt8], w: Int, h: Int) {
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (px, w, h)
    }

    /// No COLR or OpenType-SVG font ships in /System/Library/Fonts (searched 2026-11-25), so only sbix and plain
    /// outlines are asserted here.
    @Test func colourFaceDetection() throws {
        let emoji = try font("/System/Library/Fonts/Apple Color Emoji.ttc")
        let newYork = try font(TempFonts.newYork)
        #expect(GlyphImage.isColourFace(emoji))
        #expect(!GlyphImage.isColourFace(newYork))
        let smile = try glyph(emoji, "\u{1F600}")
        #expect(GlyphSVG.exportDocument(font: emoji, glyph: smile) == nil)
        #expect(!GlyphSVG.hasExportableOutline(font: emoji, glyph: smile))
        let g = try glyph(newYork, "g")
        #expect(GlyphSVG.exportDocument(font: newYork, glyph: g) != nil)
        #expect(GlyphSVG.hasExportableOutline(font: newYork, glyph: g))
    }

    @Test func pngIsSharpAndCropped() throws {
        let f = try font(TempFonts.newYork)
        let data = try #require(GlyphImage.png(font: f, glyph: try glyph(f, "g")))
        let (px, w, h) = try pixels(data)
        #expect(Double(h) > 0.5 * 2048 && Double(h) < 1.2 * 2048)
        #expect(w > 0)
        #expect(px[3] == 0)
        var black = false
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] == 255 && px[i] == 0 && px[i + 1] == 0 && px[i + 2] == 0 {
            black = true
            break
        }
        #expect(black)
    }

    @Test func spaceHasNoImage() throws {
        let f = try font(TempFonts.newYork)
        #expect(GlyphImage.png(font: f, glyph: try glyph(f, " ")) == nil)
    }

    @Test func colourGlyphIsInColour() throws {
        let f = try font(TempFonts.emoji)
        let data = try #require(GlyphImage.png(font: f, glyph: try glyph(f, "😀")))
        let (px, _, _) = try pixels(data)
        var coloured = false
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && (px[i] != px[i + 1] || px[i + 1] != px[i + 2]) {
            coloured = true
            break
        }
        #expect(coloured)
    }
}
