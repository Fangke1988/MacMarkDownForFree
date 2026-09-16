import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

struct Heading: Identifiable {
    var id: String
    var title: String
    var level: Int
    var line: Int
}

@MainActor final class DocumentStore: ObservableObject, Identifiable {
    let id = UUID()
    weak var workspace: TabWorkspace?
    @Published var url: URL?
    @Published var folder: URL?
    @Published var mode = "reading"
    @Published var theme = UserDefaults.standard.string(forKey: "theme") ?? "system"
    @Published var status = "本地文档"
    @Published var dirty = false
    @Published var error: String?
    @Published var conflict = false
    @Published var headings: [Heading] = []
    @Published var activeLine = 0
    @Published var words = 0
    @Published var line = 1
    @Published var column = 1
    @Published var sidebar = true
    @Published var sidebarTab = "files"
    @Published var files: [FileEntry] = []
    @Published var recent = UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []
    @Published var recoveries: [RecoveryDraft] = []
    @Published var composing = false
    @Published var exporting = false
    var text = ""
    var token = UUID().uuidString
    var baseline: Data?
    var ready = false
    weak var web: WKWebView?
    private var saveTask: Task<Void, Never>?
    private var poll: Timer?
    private var revision = 0
    private var pendingAnchor: String?

    init() {
        recoveries = Drafts.all()
        poll = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkExternal() }
        }
    }
    deinit { poll?.invalidate() }
    var title: String { url?.lastPathComponent ?? "未命名文档" }
    var effectiveTheme: String {
        theme == "system" ? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light") : theme
    }
    func call(_ method: String, _ args: [Any] = []) {
        guard ready, let data = try? JSONSerialization.data(withJSONObject: args), let json = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("void window.EditorAPI.\(method)(...\(json))", completionHandler: nil)
    }
    func sendDocument() { revision = 0; call("load", [["text": text, "token": token, "mode": mode, "theme": effectiveTheme]]) }
    func changeMode(_ value: String) { if !exporting { call("setMode", [value]) } }
    func changeTheme(_ value: String) {
        theme = value; UserDefaults.standard.set(value, forKey: "theme"); call("setTheme", [effectiveTheme])
    }
    func action(_ value: String) { if !exporting { call("action", [value]) } }

    func receive(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        if type == "ready" { ready = true; sendDocument(); return }
        guard message["token"] as? String == token else { return }
        switch type {
        case "change":
            guard let next = message["text"] as? String, let nextRevision = message["version"] as? Int, nextRevision > revision else { return }
            revision = nextRevision; text = next; dirty = true; status = conflict ? "磁盘版本冲突" : "等待保存"; persistDraft(); scheduleSave()
        case "mode": mode = message["mode"] as? String ?? mode
        case "stats":
            words = message["words"] as? Int ?? 0; line = message["line"] as? Int ?? 1; column = message["col"] as? Int ?? 1
            headings = (message["headings"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String, let title = item["title"] as? String, let level = item["level"] as? Int, let line = item["line"] as? Int else { return nil }
                return Heading(id: id, title: title, level: level, line: line)
            }
            if let anchor = pendingAnchor, let h = headings.first(where: { $0.id == anchor }) { pendingAnchor = nil; call("jump", [h.line]) }
        case "activeHeading": activeLine = message["line"] as? Int ?? 0
        case "composition": composing = message["active"] as? Bool ?? false
        case "save": _ = save()
        case "chooseImage": chooseImage()
        case "importImage":
            if let encoded = message["data"] as? String, let data = Data(base64Encoded: encoded), let name = message["name"] as? String { importImage(data, name: name) }
        case "openLink": if let href = message["href"] as? String { openLink(href) }
        case "copy": if let value = message["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
        case "error": error = message["message"] as? String
        default: break
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, !self.composing, !self.conflict else { return }
            if self.url != nil { _ = self.save(prompt: false) } else { self.status = "草稿已恢复保护" }
        }
    }
    private func persistDraft() {
        guard dirty else { return }
        do { try Drafts.write(RecoveryDraft(id: token, path: url?.path, text: text, baseline: baseline, date: Date())) }
        catch { self.error = "恢复草稿保存失败：\(error.localizedDescription)" }
    }
    @discardableResult func save(prompt: Bool = true, copy: Bool = false) -> Bool {
        guard !composing else { NSSound.beep(); return false }
        if conflict && !copy { if prompt { showConflict() }; return false }
        saveTask?.cancel()
        var target = url
        if target == nil || copy {
            guard prompt else { persistDraft(); return false }
            let panel = NSSavePanel(); panel.title = copy ? "保留本地副本" : "保存 Markdown 文档"
            panel.nameFieldStringValue = copy ? (url?.deletingPathExtension().lastPathComponent ?? "文档") + "-本地副本.md" : title + (title.hasSuffix(".md") ? "" : ".md")
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]; panel.directoryURL = folder ?? url?.deletingLastPathComponent()
            guard panel.runModal() == .OK, let destination = panel.url else { return false }; target = destination
            if copy && target == url { error = "请选择不同的文件名，避免覆盖发生冲突的磁盘版本。"; return false }
        }
        guard let target else { return false }
        if !dirty && !copy && target == url { return true }
        do {
            baseline = try DocumentIO.save(text, to: target, baseline: copy || url == nil ? nil : baseline)
            url = target; dirty = false; conflict = false; status = "已保存"; Drafts.remove(token); addRecent(target); refreshFiles(); return true
        } catch DocumentError.conflict { conflict = true; status = "磁盘版本冲突"; persistDraft(); return false }
        catch { self.error = error.localizedDescription; status = "保存失败 · 草稿已保留"; persistDraft(); return false }
    }
    func canLeave() -> Bool {
        if exporting { NSSound.beep(); return false }
        if composing { NSSound.beep(); return false }
        if conflict { showConflict(); return !conflict }
        if dirty && url != nil { return save() }
        if dirty {
            let alert = NSAlert(); alert.messageText = "保存这份未命名文档？"; alert.informativeText = "也可以保留恢复草稿，稍后从文件菜单继续。"
            alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "保留草稿"); alert.addButton(withTitle: "取消")
            switch alert.runModal() { case .alertFirstButtonReturn: return save(); case .alertSecondButtonReturn: persistDraft(); return true; default: return false }
        }
        return true
    }
    func newDocument() {
        if let workspace { workspace.newDocument(); return }
        guard canLeave() else { return }
        reset(); text = ""; dirty = true; mode = "visual"; status = "未保存"; persistDraft(); sendDocument()
    }
    func reset() { saveTask?.cancel(); token = UUID().uuidString; revision = 0; url = nil; baseline = nil; dirty = false; conflict = false; headings = []; text = "" }
    func chooseFile() {
        let panel = NSOpenPanel(); panel.title = "打开 Markdown 文档"; panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for value in panel.urls { open(value) } }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "打开文档文件夹"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let value = panel.url { folder = value; refreshFiles(); sidebar = true; sidebarTab = "files" }
    }
    func open(_ value: URL) {
        if let workspace { workspace.open(value); return }
        loadFile(value)
    }
    func loadFile(_ value: URL) {
        if value == url { return }
        guard canLeave() else { return }
        do {
            let (content, bytes) = try DocumentIO.read(value)
            reset(); url = value; text = content; baseline = bytes; mode = "reading"; status = "已载入"
            if folder == nil || !value.path.hasPrefix(folder!.path + "/") { folder = value.deletingLastPathComponent() }
            addRecent(value); refreshFiles(); sendDocument()
        } catch { self.error = error.localizedDescription }
    }
    func refreshFiles() { files = folder.map(FileEntry.children) ?? []; recoveries = Drafts.all().filter { $0.id != token } }
    private func addRecent(_ value: URL) { recent = [value.path] + recent.filter { $0 != value.path }; recent = Array(recent.prefix(12)); UserDefaults.standard.set(recent, forKey: "recentFiles"); NSDocumentController.shared.noteNewRecentDocumentURL(value) }
    func recover(_ draft: RecoveryDraft) {
        if let workspace { workspace.recover(draft); return }
        guard canLeave() else { return }; reset(); token = draft.id; text = draft.text; baseline = draft.baseline; url = draft.path.map(URL.init(fileURLWithPath:)); folder = url?.deletingLastPathComponent(); dirty = true; mode = "source"; status = "已恢复草稿"; refreshFiles(); checkExternal(); sendDocument()
    }
    func checkExternal() {
        guard let url, let baseline, !composing, !exporting else { return }
        guard let disk = try? Data(contentsOf: url), disk == baseline else {
            if dirty { conflict = true; status = "磁盘版本冲突"; saveTask?.cancel(); persistDraft() }
            else if let (newText, data) = try? DocumentIO.read(url) {
                self.baseline = data; text = newText; revision = 0; token = UUID().uuidString; status = "已同步外部修改"; sendDocument()
            } else { status = "文件不可用 · 内存内容仍保留" }
            return
        }
    }
    func showConflict() {
        let alert = NSAlert(); alert.messageText = "文档存在两个版本"; alert.informativeText = "其他程序修改了磁盘文件。可以将当前编辑保存为另一份文件，或加载磁盘版本。"
        alert.addButton(withTitle: "保留本地副本"); alert.addButton(withTitle: "加载磁盘版本"); alert.addButton(withTitle: "稍后处理")
        switch alert.runModal() {
        case .alertFirstButtonReturn: _ = save(copy: true)
        case .alertSecondButtonReturn:
            guard let url else { return }
            do { let (content, data) = try DocumentIO.read(url); Drafts.remove(token); text = content; baseline = data; dirty = false; conflict = false; revision = 0; token = UUID().uuidString; status = "已加载磁盘版本"; sendDocument() }
            catch { self.error = error.localizedDescription }
        default: break
        }
    }
    func chooseImage() {
        let panel = NSOpenPanel(); panel.title = "插入图片"; panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let value = panel.url {
            do { importImage(try Data(contentsOf: value), name: value.lastPathComponent) } catch { self.error = error.localizedDescription }
        }
    }
    func importImage(_ data: Data, name: String) {
        guard NSImage(data: data) != nil else { error = DocumentError.invalidImage.localizedDescription; return }
        if url == nil && !save() { return }
        guard let url else { return }
        do { let path = try DocumentIO.importImage(data, name: name, beside: url); call("insertImage", [path]) }
        catch { self.error = error.localizedDescription }
    }
    func openLink(_ href: String) {
        if let link = URL(string: href), ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(link); return }
        guard !href.contains(":"), let url else { return }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        do {
            let target = try DocumentIO.resource(String(parts[0]), document: url, root: folder)
            if ["md", "markdown"].contains(target.pathExtension.lowercased()) {
                let destination: DocumentStore
                if let workspace {
                    guard let opened = workspace.open(target) else { return }
                    destination = opened
                } else { open(target); destination = self }
                destination.pendingAnchor = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : nil
                if let anchor = destination.pendingAnchor, let h = destination.headings.first(where: { $0.id == anchor }) { destination.pendingAnchor = nil; destination.call("jump", [h.line]) }
            }
            else { NSWorkspace.shared.open(target) }
        } catch { self.error = error.localizedDescription }
    }
    func exportPDF() {
        guard !composing, !exporting, let web else { return }
        let previous = mode
        let panel = NSSavePanel(); panel.title = "导出 PDF"; panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (url?.deletingPathExtension().lastPathComponent ?? "文档") + ".pdf"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        status = "正在导出 PDF…"
        exporting = true
        Task {
            defer { call("finishPrint"); exporting = false; changeMode(previous) }
            do {
                let data = try await PDFExporter.make(web)
                try data.write(to: output, options: .atomic)
                status = "PDF 已导出"
            } catch { self.error = error.localizedDescription; status = "PDF 导出失败" }
        }
    }
}
