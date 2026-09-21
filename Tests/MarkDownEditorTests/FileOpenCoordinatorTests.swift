import XCTest
import AppKit
@testable import MarkDownEditor

@MainActor final class FileOpenCoordinatorTests: XCTestCase {
    private func document(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("file-open-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(name)
        try Data("# \(name)\n\n文件内容\n".utf8).write(to: file)
        return file
    }

    func testNativeFileEventDecodesMultipleURLs() throws {
        let a = try document("中文 空格 A.md"), b = try document("中文 空格 B.TXT")
        let workspace = TabWorkspace(), window = NSWindow()
        let router = FileOpenCoordinator.shared
        router.register(window, workspace: workspace) { XCTFail("Unexpected extra window") }
        defer { router.unregister(window); window.orderOut(nil) }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let files = NSAppleEventDescriptor.list()
        files.insert(NSAppleEventDescriptor(fileURL: a), at: 1)
        files.insert(NSAppleEventDescriptor(fileURL: b), at: 2)
        event.setParam(files, forKeyword: keyDirectObject)
        FileOpenDelegate().handleOpenDocuments(event, reply: NSAppleEventDescriptor.null())
        XCTAssertEqual(workspace.documents.map(\.url), [a, b])
        XCTAssertTrue(workspace.active.isPlainText)
        XCTAssertEqual(workspace.active.mode, "source")
        XCTAssertEqual(workspace.active.folder, b.deletingLastPathComponent())
        XCTAssertTrue(router.pending.isEmpty)
    }

    func testColdOpenWaitsForWindowAndLoadsFile() throws {
        let router = FileOpenCoordinator(), file = try document("中文 空格.md")
        router.open([file])
        XCTAssertEqual(router.pending, [file])
        let workspace = TabWorkspace(), window = NSWindow()
        defer { window.orderOut(nil) }
        var requests = 0
        router.register(window, workspace: workspace) { requests += 1 }
        XCTAssertEqual(workspace.active.url, file)
        XCTAssertTrue(workspace.active.text.contains("文件内容"))
        XCTAssertEqual(window.title, "中文 空格.md")
        XCTAssertTrue(router.pending.isEmpty)
        XCTAssertEqual(requests, 0)
    }

    func testRepeatedFileActivatesExistingWindow() throws {
        let router = FileOpenCoordinator(), file = try document("已有文件.md")
        let workspace = TabWorkspace(), window = NSWindow()
        defer { window.orderOut(nil) }
        var requests = 0
        router.register(window, workspace: workspace) { requests += 1 }
        router.open([file, file]); router.open([file])
        XCTAssertTrue(router.pending.isEmpty)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(workspace.active.url, file)
    }

    func testSecondFileCreatesTabAndSwitchesFolder() throws {
        let router = FileOpenCoordinator(), a = try document("A.md"), b = try document("B.md")
        let workspace = TabWorkspace(), window = NSWindow()
        defer { window.orderOut(nil) }
        var requests = 0
        router.register(window, workspace: workspace) { requests += 1 }
        router.open([a, b])
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(workspace.documents.count, 2)
        XCTAssertEqual(workspace.active.url, b)
        XCTAssertEqual(workspace.active.folder, b.deletingLastPathComponent())
        router.open([a])
        XCTAssertEqual(workspace.documents.count, 2)
        XCTAssertEqual(workspace.active.url, a)
        XCTAssertEqual(workspace.active.folder, a.deletingLastPathComponent())
        XCTAssertTrue(workspace.active.text.contains("A.md"))
        workspace.close(workspace.active)
        XCTAssertEqual(workspace.documents.count, 1)
        XCTAssertEqual(workspace.active.url, b)
        XCTAssertTrue(router.pending.isEmpty)
    }

    func testUnsavedDocumentIsNotReused() throws {
        let router = FileOpenCoordinator(), file = try document("外部文件.md")
        let workspace = TabWorkspace(), window = NSWindow()
        let draft = workspace.active
        defer { window.orderOut(nil) }
        draft.text = "尚未保存的内容"; draft.dirty = true
        router.register(window, workspace: workspace) { XCTFail("Unexpected window") }
        router.open([file])
        XCTAssertEqual(workspace.documents.count, 2)
        XCTAssertEqual(draft.text, "尚未保存的内容")
        XCTAssertNil(draft.url)
        XCTAssertEqual(workspace.active.url, file)
        workspace.select(draft)
        XCTAssertTrue(workspace.active === draft)
        XCTAssertTrue(router.pending.isEmpty)
    }
}
