import AppKit

/// File-open Apple Events can arrive before SwiftUI has created a document window.
/// Keep them at application scope until a window is ready to receive them.
@MainActor final class FileOpenCoordinator {
    static let shared = FileOpenCoordinator()

    private struct DocumentWindow {
        weak var window: NSWindow?
        weak var workspace: TabWorkspace?
    }
    private var documents: [DocumentWindow] = []
    private(set) var pending: [URL] = []
    private var requestWindow: (() -> Void)?
    private var requestingWindow = false

    func open(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL
            if !pending.contains(normalized) { pending.append(normalized) }
        }
        deliver()
    }

    func register(_ window: NSWindow, workspace: TabWorkspace, createWindow: @escaping () -> Void) {
        documents.removeAll { $0.window == nil || $0.workspace == nil }
        if !documents.contains(where: { $0.window === window }) {
            documents.append(DocumentWindow(window: window, workspace: workspace))
        }
        workspace.window = window
        requestWindow = createWindow
        requestingWindow = false
        deliver()
    }

    func unregister(_ window: NSWindow) {
        documents.removeAll { $0.window == nil || $0.window === window }
    }

    private func retry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.deliver() }
    }

    private func deliver() {
        documents.removeAll { $0.window == nil || $0.workspace == nil }
        while let url = pending.first {
            if let existing = documents.first(where: { entry in entry.workspace?.documents.contains(where: { $0.url?.standardizedFileURL == url }) == true }),
               let workspace = existing.workspace, let window = existing.window {
                if workspace.active.composing || workspace.active.exporting { retry(); return }
                pending.removeFirst()
                workspace.open(url)
                window.title = workspace.active.title
                window.makeKeyAndOrderFront(nil)
                continue
            }
            if let available = documents.first(where: { $0.window?.isKeyWindow == true }) ?? documents.last,
               let workspace = available.workspace, let window = available.window {
                if workspace.active.composing || workspace.active.exporting { retry(); return }
                pending.removeFirst()
                workspace.open(url)
                window.title = workspace.active.title
                window.representedURL = workspace.active.url
                window.makeKeyAndOrderFront(nil)
                continue
            }
            if !requestingWindow, let requestWindow {
                requestingWindow = true
                requestWindow()
            }
            return
        }
    }
}

@MainActor final class FileOpenDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Consume file events once, before SwiftUI's scene routing creates extra windows.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleOpenDocuments(_:reply:)), forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let items = event.paramDescriptor(forKeyword: keyDirectObject), items.numberOfItems > 0 else { return }
        let urls = (1...items.numberOfItems).compactMap { index -> URL? in
            items.atIndex(index)?.fileURLValue
        }
        FileOpenCoordinator.shared.open(urls)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        FileOpenCoordinator.shared.open(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let files = ProcessInfo.processInfo.arguments.dropFirst().filter {
            DocumentIO.supportedExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }.map { URL(fileURLWithPath: $0) }
        FileOpenCoordinator.shared.open(files)
    }
}
