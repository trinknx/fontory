import Foundation
import Testing
@testable import FontoryCore

@Suite struct VolumeIdentityTests {
    private func standardized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    @Test func refForTempDirHasUUIDAndRelativePath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = try VolumeIdentity.ref(for: dir)
        #expect(!ref.volumeUUID.isEmpty)
        #expect(!ref.relativePath.hasPrefix("/Volumes"))
        #expect(!ref.relativePath.hasPrefix("/"))
    }

    @Test func tempDirRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = try VolumeIdentity.ref(for: dir)
        let back = try #require(VolumeIdentity.resolve(ref))
        #expect(standardized(back) == standardized(dir))
    }

    @Test func libraryFontsRoundTrips() throws {
        let dir = URL(fileURLWithPath: "/Library/Fonts")
        let ref = try VolumeIdentity.ref(for: dir)
        let back = try #require(VolumeIdentity.resolve(ref))
        #expect(standardized(back) == standardized(dir))
    }

    @Test func resolveFollowsRemount() {
        let a = URL(fileURLWithPath: "/Volumes/Fonts")
        let b = URL(fileURLWithPath: "/Volumes/Fonts 1")
        let uuidOf: (URL) -> String? = { $0 == b ? "U1" : nil }
        let url = VolumeIdentity.resolve(VolumeRef(volumeUUID: "U1", relativePath: "Lib/Fonts"), mountedVolumes: [a, b], uuidOf: uuidOf)
        #expect(url?.path == "/Volumes/Fonts 1/Lib/Fonts")
    }

    @Test func resolveEmptyRelativePathIsVolumeRoot() {
        let b = URL(fileURLWithPath: "/Volumes/Fonts 1")
        let url = VolumeIdentity.resolve(VolumeRef(volumeUUID: "U1", relativePath: ""), mountedVolumes: [b], uuidOf: { _ in "U1" })
        #expect(url?.path == "/Volumes/Fonts 1")
    }

    @Test func resolveUnknownUUIDIsNil() {
        let a = URL(fileURLWithPath: "/Volumes/Fonts")
        #expect(VolumeIdentity.resolve(VolumeRef(volumeUUID: "nope", relativePath: "x"), mountedVolumes: [a], uuidOf: { _ in "other" }) == nil)
    }
}
