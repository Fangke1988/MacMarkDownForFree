import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct EditorWebView: NSViewRepresentable {
    @ObservedObject var store: DocumentStore
    func makeCoordinator() -> Coordinator { Coordinator(store) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "editor")
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "mdasset")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        store.web = view
        let resource = Bundle.main.resourceURL!.appendingPathComponent("Web")
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web/dist")
        let root = FileManager.default.fileExists(atPath: resource.appendingPathComponent("index.html").path) ? resource : fallback
        view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "editor")
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler {
        let store: DocumentStore
        init(_ store: DocumentStore) { self.store = store }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            store.receive(body)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other, navigationAction.request.url?.isFileURL == true { decisionHandler(.allow) }
            else { if let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }; decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { store.error = error.localizedDescription }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { store.ready = false; webView.reload() }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            do {
                guard let request = urlSchemeTask.request.url, let document = store.url else { throw DocumentError.outsideFolder }
                let path = String(request.path.dropFirst())
                let file = try DocumentIO.resource(path, document: document, root: store.folder)
                let data = try Data(contentsOf: file)
                let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                guard mime.hasPrefix("image/") else { throw DocumentError.invalidImage }
                urlSchemeTask.didReceive(URLResponse(url: request, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch { urlSchemeTask.didFailWithError(error) }
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { }
    }
}

struct WindowHook: NSViewRepresentable {
    let workspace: TabWorkspace
    let createWindow: () -> Void
    func makeCoordinator() -> Delegate { Delegate(workspace) }
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        let delegate = context.coordinator
        view.attach = { window in
            window.delegate = delegate
            window.setFrameAutosaveName("MarkdownEditorWindow")
            window.title = workspace.active.title
            FileOpenCoordinator.shared.register(window, workspace: workspace, createWindow: createWindow)
        }
        return view
    }
    func updateNSView(_ nsView: AttachmentView, context: Context) {
        nsView.window?.title = workspace.active.title; nsView.window?.isDocumentEdited = workspace.documents.contains { $0.dirty }
        nsView.window?.representedURL = workspace.active.url
    }
    final class AttachmentView: NSView {
        var attach: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.attach?(window)
            }
        }
    }
    @MainActor final class Delegate: NSObject, NSWindowDelegate {
        let workspace: TabWorkspace
        init(_ workspace: TabWorkspace) { self.workspace = workspace }
        func windowShouldClose(_ sender: NSWindow) -> Bool { workspace.canCloseWindow() }
        func windowWillClose(_ notification: Notification) {
            if let window = notification.object as? NSWindow { FileOpenCoordinator.shared.unregister(window) }
        }
    }
}
