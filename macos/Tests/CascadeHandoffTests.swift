import Foundation
import Testing
@testable import Craft

private let appcast = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>Cascade</title>
        <item>
          <title>0.1.1</title>
          <sparkle:version>1001</sparkle:version>
          <enclosure url="https://github.com/example/cascade-mac/releases/download/v0.1.1/Cascade-0.1.1.zip" length="1" type="application/octet-stream" sparkle:edSignature="x"/>
        </item>
        <item>
          <title>0.1.0</title>
          <enclosure url="https://github.com/example/cascade-mac/releases/download/v0.1.0/Cascade-0.1.0.zip" length="1" type="application/octet-stream"/>
        </item>
      </channel>
    </rss>
    """

@Test func theNewestArchiveInCascadesFeedIsTheOneInstalled() {
    let url = CascadeHandoff.archiveURL(inAppcast: Data(appcast.utf8))
    #expect(url?.absoluteString == "https://github.com/example/cascade-mac/releases/download/v0.1.1/Cascade-0.1.1.zip")
}

@Test func aFeedWithNoHttpsArchiveNamesNothing() {
    #expect(CascadeHandoff.archiveURL(inAppcast: Data("<rss><channel></channel></rss>".utf8)) == nil)
    let plain = appcast.replacingOccurrences(of: "https://", with: "http://")
    #expect(CascadeHandoff.archiveURL(inAppcast: Data(plain.utf8)) == nil)
    #expect(CascadeHandoff.archiveURL(inAppcast: Data("not xml".utf8)) == nil)
}

@Test func cascadeMustBeSignedByCraftsOwnTeam() {
    #expect(CascadeHandoff.requirement(team: "ABCDE12345")
        == #"anchor apple generic and identifier "com.alexcding.cascade" and certificate leaf[subject.OU] = "ABCDE12345""#)
}

@Test func anUnsignedBundleIsNotTrustedAsCascade() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let app = folder.appendingPathComponent("Cascade.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: app.appendingPathComponent("Cascade"))
    #expect(throws: HandoffError.self) {
        try CascadeHandoff.verify(folder.appendingPathComponent("Cascade.app"), team: "ABCDE12345")
    }
}

@Test func cascadeInstallsNextToCraftWhenThatFolderIsWritable() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let craft = folder.appendingPathComponent("Craft.app")
    #expect(try CascadeHandoff.installFolder(besides: craft).path == folder.path)
}
