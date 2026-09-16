import SwiftUI
import Combine

@MainActor final class TabWorkspace: ObservableObject {
    @Published private(set) var documents: [DocumentStore] = []
    @Published private(set) var selectedID: UUID
    @Published private(set) var theme = UserDefaults.standard.string(forKey: "theme") ?? "system"
    weak var window: NSWindow?
    private var subscriptions: [UUID: AnyCancellable] = [:]

    init() {
        let initial = DocumentStore()
        selectedID = initial.id
        append(initial)
    }
    var active: DocumentStore { documents.first { $0.id == selectedID } ?? documents[0] }

    private func append(_ document: DocumentStore) {
        document.workspace = self
        documents.append(document)
        subscriptions[document.id] = document.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    func select(_ document: DocumentStore) {
        guard documents.contains(where: { $0 === document }), !active.composing, !active.exporting else { return }
        selectedID = document.id
        DispatchQueue.main.async { [weak document] in
            guard let document, let web = document.web else { return }
            web.window?.makeFirstResponder(web)
            document.call("focus")
        }
    }
    @discardableResult func open(_ url: URL) -> DocumentStore? {
        if active.exporting || active.composing { NSSound.beep(); return nil }
        let normalized = url.standardizedFileURL
        if let existing = documents.first(where: { $0.url?.standardizedFileURL == normalized }) { select(existing); return existing }
        let empty = documents.first { $0.url == nil && !$0.dirty && $0.text.isEmpty }
        let document = empty ?? DocumentStore()
        document.loadFile(normalized)
        guard document.url == normalized else { active.error = document.error; return nil }
        if empty == nil { append(document) }
        document.theme = theme
        select(document)
        return document
    }
    func newDocument() {
        guard !active.composing, !active.exporting else { return }
        let document = DocumentStore()
        document.newDocument()
        document.folder = active.folder
        document.refreshFiles()
        document.theme = theme
        append(document)
        select(document)
    }
    func recover(_ draft: RecoveryDraft) {
        if let existing = documents.first(where: { $0.token == draft.id }) { select(existing); return }
        guard !active.composing, !active.exporting else { return }
        let document = DocumentStore()
        document.recover(draft)
        document.theme = theme
        append(document)
        select(document)
    }
    func close(_ document: DocumentStore) {
        guard !active.composing, !active.exporting else { return }
        if documents.count == 1, let window { window.performClose(nil); return }
        guard document.canLeave(), let index = documents.firstIndex(where: { $0 === document }) else { return }
        documents.remove(at: index)
        subscriptions.removeValue(forKey: document.id)
        document.workspace = nil
        if documents.isEmpty { append(DocumentStore()) }
        if selectedID == document.id { selectedID = documents[min(index, documents.count - 1)].id }
    }
    func canCloseWindow() -> Bool { documents.allSatisfy { $0.canLeave() } }
    func selectAdjacent(_ delta: Int) {
        guard let index = documents.firstIndex(where: { $0.id == selectedID }) else { return }
        select(documents[(index + delta + documents.count) % documents.count])
    }
    func changeTheme(_ value: String) {
        theme = value
        for document in documents { document.changeTheme(value) }
    }
}

struct WorkspaceKey: FocusedValueKey { typealias Value = TabWorkspace }
extension FocusedValues {
    var tabWorkspace: TabWorkspace? { get { self[WorkspaceKey.self] } set { self[WorkspaceKey.self] = newValue } }
}

struct TabbedWindowView: View {
    @StateObject private var workspace = TabWorkspace()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(workspace.documents) { document in
                                DocumentTab(document: document, workspace: workspace)
                                    .id(document.id)
                            }
                        }.padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    Button { workspace.newDocument() } label: { Image(systemName: "plus").frame(width: 28, height: 26) }
                        .buttonStyle(.borderless).help("新建标签页 ⌘T").padding(.trailing, 8)
                }
                .onChange(of: workspace.selectedID) { value in proxy.scrollTo(value) }
            }.frame(height: 38).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            // Keep each editor and sidebar mounted so undo, selection, and scroll survive tab changes.
            ZStack {
                ForEach(workspace.documents) { document in
                    ContentView(store: document, workspace: workspace, isActive: workspace.selectedID == document.id)
                        .opacity(workspace.selectedID == document.id ? 1 : 0)
                        .allowsHitTesting(workspace.selectedID == document.id)
                        .accessibilityHidden(workspace.selectedID != document.id)
                }
            }
        }
        .background(WindowHook(workspace: workspace, createWindow: { openWindow(id: "editor") }).frame(width: 0, height: 0))
        .navigationTitle(workspace.active.title)
        .focusedSceneValue(\.documentStore, workspace.active)
        .focusedSceneValue(\.tabWorkspace, workspace)
        .preferredColorScheme(workspace.theme == "system" ? nil : workspace.theme == "dark" ? .dark : .light)
        .frame(minWidth: 800, minHeight: 618)
    }
}

private struct DocumentTab: View {
    @ObservedObject var document: DocumentStore
    @ObservedObject var workspace: TabWorkspace
    var body: some View {
        HStack(spacing: 7) {
            Button { workspace.select(document) } label: {
                HStack(spacing: 6) {
                    Image(systemName: document.dirty ? "circle.fill" : "doc.text").font(.system(size: document.dirty ? 6 : 11))
                    Text(document.title).font(.system(size: 12)).lineLimit(1)
                }.frame(minWidth: 80, maxWidth: 190, alignment: .leading).padding(.leading, 10).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain).help(document.url?.path ?? "尚未保存")
            Button { workspace.close(document) } label: { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 22, height: 24) }
                .buttonStyle(.plain).help("关闭 \(document.title)").accessibilityLabel("关闭 \(document.title)")
        }
        .background(workspace.selectedID == document.id ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .bottom) { if workspace.selectedID == document.id { Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 8) } }
    }
}
