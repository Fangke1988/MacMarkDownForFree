import XCTest
@testable import MarkDownEditor

final class DocumentIOTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("Markdown 测试 " + UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func testChinesePathAndCRLFPreservation() throws {
        let file = directory.appendingPathComponent("中文 文档.md"), original = Data("\u{feff}# 标题\r\n\r\n正文\r\n".utf8)
        try original.write(to: file)
        let (_, baseline) = try DocumentIO.read(file)
        let saved = try DocumentIO.save("# 标题\n\n修改\n", to: file, baseline: baseline)
        XCTAssertEqual(saved, Data("\u{feff}# 标题\r\n\r\n修改\r\n".utf8))
    }
    func testExternalConflictNeverOverwrites() throws {
        let file = directory.appendingPathComponent("文档.md"), baseline = Data("original".utf8)
        try baseline.write(to: file); try Data("external".utf8).write(to: file)
        XCTAssertThrowsError(try DocumentIO.save("local", to: file, baseline: baseline))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external")
    }
    func testDeletedFileIsConflict() throws {
        let file = directory.appendingPathComponent("missing.md")
        XCTAssertThrowsError(try DocumentIO.save("local", to: file, baseline: Data("original".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testImageImportCollisionAndRelocation() throws {
        let doc = directory.appendingPathComponent("笔记.md"), a = Data([1, 2, 3]), b = Data([4, 5])
        let first = try DocumentIO.importImage(a, name: "截图.png", beside: doc)
        let second = try DocumentIO.importImage(b, name: "截图.png", beside: doc)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: DocumentIO.resource(first, document: doc, root: nil)), a)
        let moved = directory.appendingPathComponent("移动后")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory.appendingPathComponent("assets"), to: moved.appendingPathComponent("assets"))
        XCTAssertEqual(try Data(contentsOf: DocumentIO.resource(second, document: moved.appendingPathComponent("笔记.md"), root: nil)), b)
    }
    func testResourceCannotEscapeThroughTraversalOrSymlink() throws {
        let doc = directory.appendingPathComponent("笔记.md")
        XCTAssertThrowsError(try DocumentIO.resource("../secret.png", document: doc, root: nil))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(try DocumentIO.resource("link/secret.png", document: doc, root: nil))
    }
    func testDirectoryFiltersHiddenFilesAndOtherFormats() throws {
        for name in ["a.md", "中文.markdown", "image.png", ".hidden.md"] { try Data().write(to: directory.appendingPathComponent(name)) }
        XCTAssertEqual(Set(FileEntry.children(directory).map(\.name)), ["a.md", "中文.markdown"])
    }
}
