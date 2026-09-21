import SwiftUI

struct StoreKey: FocusedValueKey { typealias Value = DocumentStore }
extension FocusedValues { var documentStore: DocumentStore? { get { self[StoreKey.self] } set { self[StoreKey.self] = newValue } } }

struct ContentView: View {
    @ObservedObject var store: DocumentStore
    @ObservedObject var workspace: TabWorkspace
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("wordWrap") private var wordWrap = true
    @State private var filter = ""
    @State private var searchResults: [FileEntry] = []
    @State private var collapsedHeadings = Set<String>()
    var body: some View {
        HSplitView {
            if store.sidebar { sidebar.frame(minWidth: 200, idealWidth: 235, maxWidth: 340) }
            VStack(spacing: 0) {
                if store.conflict {
                    HStack { Image(systemName: "exclamationmark.triangle"); Text("磁盘文件已更改，自动保存已暂停。"); Spacer(); Button("处理版本冲突") { store.showConflict() } }.font(.system(size: 12)).padding(10).background(Color.orange.opacity(0.10))
                    Divider()
                }
                EditorWebView(store: store)
                Divider()
                HStack(spacing: 14) {
                    Text("\(store.words) 字")
                    if store.mode == "source" { Text("第 \(store.line) 行，\(store.column) 列") }
                    Spacer()
                    if store.composing { Text("输入中") } else { Text(store.status) }
                    Text(store.isPlainText ? "TXT · UTF-8" : "Markdown").foregroundStyle(.tertiary)
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 28)
            }.frame(minWidth: 560, minHeight: 480)
        }
        .frame(minWidth: 800, minHeight: 580)
        .disabled(store.exporting)
        .toolbar {
            if isActive {
            ToolbarItem(placement: .navigation) { Button { store.sidebar.toggle() } label: { Image(systemName: "sidebar.left") }.help("显示或隐藏侧栏") }
            ToolbarItem(placement: .principal) {
                if store.isPlainText { Text("纯文本").font(.system(size: 12)).foregroundStyle(.secondary) }
                else {
                Picker("视图", selection: Binding(get: { store.mode }, set: { store.changeMode($0) })) {
                    Text("阅读").tag("reading"); Text("编辑").tag("visual"); Text("源码").tag("source")
                }.pickerStyle(.segmented).frame(width: 210).disabled(store.composing)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if !store.isPlainText {
                    Menu { Button("图片…") { store.action("image") }; Button("表格…") { store.action("table") }; Button("链接…") { store.action("link") }; Divider(); Button("代码块…") { store.action("code") }; Button("Mermaid 图表…") { store.action("mermaid") }; Button("数学公式…") { store.action("math") } } label: { Image(systemName: "plus") }.help("插入内容")
                }
                Button { store.action("find") } label: { Image(systemName: "magnifyingglass") }.help("查找与替换 ⌘F")
                Menu {
                    ForEach([("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")], id: \.0) { item in
                        Button { workspace.changeTheme(item.0) } label: { if store.theme == item.0 { Label(item.1, systemImage: "checkmark") } else { Text(item.1) } }
                    }
                } label: { Image(systemName: "circle.lefthalf.filled") }.help("外观")
                Button { store.exportPDF() } label: { Image(systemName: "square.and.arrow.up") }.help("导出 PDF")
            }
            }
        }
        .onChange(of: colorScheme) { _ in store.call("setTheme", [store.effectiveTheme]) }
        .onChange(of: wordWrap) { store.changeWordWrap($0) }
        .alert("无法完成操作", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("好", role: .cancel) { store.error = nil } } message: { Text(store.error ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("侧栏", selection: $store.sidebarTab) { Text("文件").tag("files"); Text("大纲").tag("outline") }.pickerStyle(.segmented).padding(12)
            ZStack {
                fileSidebar.opacity(store.sidebarTab == "files" ? 1 : 0).allowsHitTesting(store.sidebarTab == "files").accessibilityHidden(store.sidebarTab != "files")
                outlineSidebar.opacity(store.sidebarTab == "outline" ? 1 : 0).allowsHitTesting(store.sidebarTab == "outline").accessibilityHidden(store.sidebarTab != "outline")
            }
            Divider()
            HStack {
                Button { store.chooseFolder() } label: { Image(systemName: "folder.badge.plus") }.help("打开文件夹")
                Button { store.newDocument() } label: { Image(systemName: "square.and.pencil") }.help("新建文档")
                Spacer()
                Button { store.refreshFiles() } label: { Image(systemName: "arrow.clockwise") }.help("刷新目录")
            }.buttonStyle(.borderless).padding(12)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private var fileSidebar: some View {
        VStack(spacing: 0) {
            if let folder = store.folder {
                HStack { Text(folder.lastPathComponent).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1); Spacer() }.padding(.horizontal, 15).padding(.top, 5)
                TextField("查找文件名", text: $filter).textFieldStyle(.roundedBorder).padding(12)
                    .task(id: filter) { await search() }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if filter.isEmpty { ForEach(store.files) { entry in FileRow(entry: entry, store: store) } }
                        else { ForEach(searchResults) { entry in FileRow(entry: entry, store: store) } }
                        if store.files.isEmpty { Text("这个文件夹还没有 Markdown 或 TXT 文档").font(.caption).foregroundStyle(.secondary).padding(16) }
                        else if !filter.isEmpty && searchResults.isEmpty { Text("没有匹配的文件").font(.caption).foregroundStyle(.secondary).padding(16) }
                    }.padding(.horizontal, 8).padding(.bottom, 20)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("你的文档").font(.headline)
                            Text("打开文件或文件夹，\n从阅读开始。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            Button("打开文件…") { store.chooseFile() }
                            Button("打开文件夹…") { store.chooseFolder() }
                        }.padding(.bottom, 14)
                        if !store.recoveries.isEmpty {
                            Text("恢复草稿").font(.caption).foregroundStyle(.secondary)
                            ForEach(store.recoveries) { draft in Button { store.recover(draft) } label: { Label(draft.title, systemImage: "clock.arrow.circlepath").lineLimit(1) }.buttonStyle(.plain) }
                        }
                        if !store.recent.isEmpty {
                            Text("最近打开").font(.caption).foregroundStyle(.secondary)
                            ForEach(store.recent, id: \.self) { path in Button { store.open(URL(fileURLWithPath: path)) } label: { Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc.text").lineLimit(1) }.buttonStyle(.plain).help(path) }
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private var outlineSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if store.headings.isEmpty { Text("使用标题组织文章，\n章节会显示在这里。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).padding(18) }
                ForEach(visibleHeadings) { heading in
                    HStack(spacing: 3) {
                        if hasChildren(heading) {
                            Button { if collapsedHeadings.contains(heading.id) { collapsedHeadings.remove(heading.id) } else { collapsedHeadings.insert(heading.id) } } label: { Image(systemName: collapsedHeadings.contains(heading.id) ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .semibold)).frame(width: 12) }.buttonStyle(.plain)
                        } else { Spacer().frame(width: 12) }
                        Button { store.call("jump", [heading.line]) } label: { Text(heading.title).font(.system(size: 12, weight: heading.level == 1 ? .semibold : .regular)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7) }.buttonStyle(.plain)
                    }.padding(.leading, CGFloat(max(0, heading.level - 1)) * 10 + 6).padding(.trailing, 7)
                        .background(activeHeading == heading.id ? Color.accentColor.opacity(0.12) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }.padding(8)
        }
    }
    private var activeHeading: String? { store.headings.last(where: { $0.line <= store.activeLine })?.id }
    private func hasChildren(_ heading: Heading) -> Bool { guard let index = store.headings.firstIndex(where: { $0.id == heading.id }), index + 1 < store.headings.count else { return false }; return store.headings[index + 1].level > heading.level }
    private var visibleHeadings: [Heading] {
        var hiddenBelow: Int?; var result: [Heading] = []
        for h in store.headings { if let level = hiddenBelow { if h.level > level { continue }; hiddenBelow = nil }; result.append(h); if collapsedHeadings.contains(h.id) { hiddenBelow = h.level } }
        return result
    }
    private func search() async {
        guard !filter.isEmpty, let root = store.folder else { searchResults = []; return }
        let query = filter
        let results = await Task.detached(priority: .userInitiated) {
            var matches: [FileEntry] = []
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return matches }
            while let url = enumerator.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                if DocumentIO.supportedExtensions.contains(url.pathExtension.lowercased()) && url.lastPathComponent.localizedCaseInsensitiveContains(query) { matches.append(FileEntry(url: url, directory: false)) }
            }
            return matches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
        if !Task.isCancelled { searchResults = results }
    }
}

struct FileRow: View {
    let entry: FileEntry
    @ObservedObject var store: DocumentStore
    @State private var expanded = false
    @State private var children: [FileEntry] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if entry.directory { expanded.toggle(); if expanded { children = FileEntry.children(entry.url) } } else { store.open(entry.url) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: entry.directory ? (expanded ? "chevron.down" : "chevron.right") : "doc.text").font(.system(size: entry.directory ? 9 : 12)).foregroundStyle(.secondary).frame(width: 14)
                    if entry.directory { Image(systemName: "folder").foregroundStyle(.secondary) }
                    Text(entry.name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain).background(store.url == entry.url ? Color.accentColor.opacity(0.13) : .clear).clipShape(RoundedRectangle(cornerRadius: 5))
                .contextMenu { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } }.help(entry.url.path)
            if expanded { ForEach(children) { child in FileRow(entry: child, store: store).padding(.leading, 14) } }
        }
    }
}
