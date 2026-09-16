import XCTest
import WebKit
import PDFKit
@testable import MarkDownEditor

@MainActor final class NativeEditorTests: XCTestCase {
    private func js(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("Timed out waiting for native editor")
    }
    func testRealWebKitEditingSaveConflictAndPDF() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("编辑器 实测 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("中文 测试.md")
        let original = "# 原生测试\n\n正文\n\n## 公式\n\n$$\nx^2\n$$\n\n```mermaid\nflowchart LR\n A[开始] --> B[完成]\n```\n"
        try Data(original.utf8).write(to: file)
        let store = DocumentStore(); store.open(file)
        let coordinator = EditorWebView.Coordinator(store)
        let config = WKWebViewConfiguration(); config.userContentController.add(coordinator, name: "editor"); config.setURLSchemeHandler(coordinator, forURLScheme: "mdasset")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1000), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; window.orderFront(nil); store.web = web
        defer { window.orderOut(nil); config.userContentController.removeScriptMessageHandler(forName: "editor"); Drafts.remove(store.token) }
        let webRoot = root.appendingPathComponent("web/dist")
        web.loadFileURL(webRoot.appendingPathComponent("index.html"), allowingReadAccessTo: webRoot)
        try await waitUntil { store.ready && store.headings.count == 2 }
        _ = try await js(web, "await window.EditorAPI.setMode('visual'); return window.EditorAPI.snapshot().mode")
        XCTAssertEqual(store.mode, "visual")
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
        _ = try await js(web, "const p=document.querySelector('.ProseMirror p');p.focus();const r=document.createRange();r.selectNodeContents(p);const s=window.getSelection();s.removeAllRanges();s.addRange(r);document.execCommand('insertText',false,'原生编辑成功');return true")
        try await waitUntil { store.text.contains("原生编辑成功") }
        try await waitUntil { !store.dirty }
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("原生编辑成功"))
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=")!
        store.importImage(png, name: "截图.png")
        try await waitUntil { store.text.contains("assets/") }
        XCTAssertFalse(store.text.contains("mdasset:"))
        _ = try await js(web, "await window.EditorAPI.setMode('reading');return true")
        let imageLoaded = try await js(web, "const img=document.querySelector('#reading img');await new Promise(r=>{if(img.complete)r();else {img.onload=r;img.onerror=r;setTimeout(r,2000)}});return img.naturalWidth > 0")
        XCTAssertEqual(imageLoaded as? Bool, true)
        try await waitUntil { !store.dirty }
        _ = try await js(web, "await window.EditorAPI.setMode('source');return true")
        let disk = Data("# 外部修改\n".utf8); try disk.write(to: file)
        store.checkExternal()
        try await waitUntil { store.text == "# 外部修改\n" }
        let token = store.token
        store.receive(["type": "change", "token": token, "version": 1, "text": "# 本地修改\n"])
        try Data("# 再次外部修改\n".utf8).write(to: file); store.checkExternal()
        XCTAssertTrue(store.conflict); XCTAssertFalse(store.save(prompt: false))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# 再次外部修改\n")
        XCTAssertTrue(Drafts.all().contains { $0.id == token && $0.text == "# 本地修改\n" })
        let sample = try String(contentsOf: root.appendingPathComponent("delivery/欢迎使用.md"), encoding: .utf8)
        let json = String(data: try JSONSerialization.data(withJSONObject: ["text": sample, "token": store.token, "mode": "reading", "theme": "light"]), encoding: .utf8)!
        _ = try await js(web, "await window.EditorAPI.load(\(json));await window.EditorAPI.preparePrint();return true")
        let pdf = try await web.pdf(configuration: WKPDFConfiguration())
        XCTAssertGreaterThan(pdf.count, 1000)
        XCTAssertNotNil(PDFDocument(data: pdf))
        try pdf.write(to: root.appendingPathComponent("delivery/native-webkit.pdf"))
        let output = root.appendingPathComponent("delivery/使用说明.pdf")
        let paginated = try await PDFExporter.make(web)
        try paginated.write(to: output)
        let printed = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertGreaterThanOrEqual(printed.pageCount, 2)
        XCTAssertTrue(printed.string?.contains("适合你的外观") == true)
    }
}
