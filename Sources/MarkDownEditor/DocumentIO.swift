import Foundation

enum DocumentError: LocalizedError {
    case notUTF8, conflict, outsideFolder, invalidImage
    var errorDescription: String? {
        switch self {
        case .notUTF8: return "文件不是 UTF-8 编码。请先转换为 UTF-8 后打开。"
        case .conflict: return "磁盘文件已被其他程序修改，已停止保存以避免覆盖。"
        case .outsideFolder: return "此资源不在已打开的文件夹中。请打开它所在的文件夹后重试。"
        case .invalidImage: return "无法读取这张图片。"
        }
    }
}

enum DocumentIO {
    static let supportedExtensions = ["md", "markdown", "txt"]

    static func read(_ url: URL) throws -> (String, Data) {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw DocumentError.notUTF8 }
        return (text, data)
    }

    static func encoded(_ text: String, matching baseline: Data?) -> Data {
        var value = text
        if let baseline, let original = String(data: baseline, encoding: .utf8) {
            if original.contains("\r\n") { value = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") }
            if baseline.starts(with: [0xEF, 0xBB, 0xBF]) && !value.hasPrefix("\u{feff}") { value = "\u{feff}" + value }
        }
        return Data(value.utf8)
    }

    @discardableResult static func save(_ text: String, to url: URL, baseline: Data?) throws -> Data {
        if let baseline {
            guard let disk = try? Data(contentsOf: url), disk == baseline else { throw DocumentError.conflict }
        }
        let data = encoded(text, matching: baseline)
        try data.write(to: url, options: .atomic)
        return data
    }

    static func importImage(_ data: Data, name: String, beside document: URL) throws -> String {
        let directory = document.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = URL(fileURLWithPath: name).lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let safeExt = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg"].contains(ext) ? ext : "png"
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^\\p{L}\\p{N}_-]", with: "-", options: .regularExpression)
        let base = stem.isEmpty ? "image" : stem
        // Exclusive creation avoids overwriting even when two windows import at once.
        var count = 0
        while true {
            let file = directory.appendingPathComponent("\(base)\(count == 0 ? "" : "-\(count)").\(safeExt)")
            do { try data.write(to: file, options: .withoutOverwriting); return "assets/" + file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }
            catch CocoaError.fileWriteFileExists { count += 1 }
        }
    }

    static func resource(_ path: String, document: URL, root: URL?) throws -> URL {
        let decoded = path.removingPercentEncoding ?? path
        let candidate = document.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
        let url = candidate.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(candidate.lastPathComponent).resolvingSymlinksInPath()
        let scope = (root ?? document.deletingLastPathComponent()).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(scope.path + "/") else { throw DocumentError.outsideFolder }
        return url
    }
}

struct RecoveryDraft: Codable, Identifiable {
    var id: String
    var path: String?
    var text: String
    var baseline: Data?
    var date: Date
    var title: String { path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未命名文档" }
}

enum Drafts {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkDownEditor/Recovery", isDirectory: true)
    }
    static func write(_ draft: RecoveryDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent(draft.id + ".json"), options: .atomic)
    }
    static func remove(_ id: String) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".json")) }
    static func all() -> [RecoveryDraft] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(RecoveryDraft.self, from: $0) } }
            .sorted { $0.date > $1.date }
    }
}

struct FileEntry: Identifiable, Hashable {
    var url: URL
    var directory: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    static func children(_ folder: URL) -> [FileEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { return nil }
            let dir = values?.isDirectory == true
            guard dir || DocumentIO.supportedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return FileEntry(url: url, directory: dir)
        }.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
