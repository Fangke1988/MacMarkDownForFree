import SwiftUI

@main struct MarkDownEditorApp: App {
    @NSApplicationDelegateAdaptor(FileOpenDelegate.self) private var fileOpenDelegate
    var body: some Scene {
        WindowGroup(id: "editor") { TabbedWindowView() }
            .defaultSize(width: 1120, height: 780)
            .commands { EditorCommands() }
    }
}

struct EditorCommands: Commands {
    @AppStorage("wordWrap") private var wordWrap = true
    @FocusedValue(\.documentStore) private var store
    @FocusedValue(\.tabWorkspace) private var workspace
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建文档") { workspace?.newDocument() }.keyboardShortcut("n")
            Button("新建标签页") { workspace?.newDocument() }.keyboardShortcut("t")
            Button("新建窗口") { openWindow(id: "editor") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("关闭标签页") { if let workspace { workspace.close(workspace.active) } }.keyboardShortcut("w")
            Button("打开文档…") { store?.chooseFile() }.keyboardShortcut("o")
            Button("打开文件夹…") { store?.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Menu("最近打开") { ForEach(store?.recent ?? [], id: \.self) { path in Button(URL(fileURLWithPath: path).lastPathComponent) { store?.open(URL(fileURLWithPath: path)) } } }
            Menu("恢复草稿") { ForEach(Drafts.all()) { draft in Button(draft.title + " · " + draft.date.formatted(date: .abbreviated, time: .shortened)) { store?.recover(draft) } } }
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存") { _ = store?.save() }.keyboardShortcut("s")
            Button("另存为…") { _ = store?.save(copy: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider(); Button("导出 PDF…") { store?.exportPDF() }.keyboardShortcut("p")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { store?.action("undo") }.keyboardShortcut("z")
            Button("重做") { store?.action("redo") }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("查找与替换…") { store?.action("find") }.keyboardShortcut("f")
            Button("替换…") { store?.action("replace") }.keyboardShortcut("f", modifiers: [.command, .option])
            Button("查找下一个") { store?.action("findNext") }.keyboardShortcut("g")
            Button("查找上一个") { store?.action("findPrevious") }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("全文查找并列出结果") { store?.action("findAll") }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("插入链接…") { store?.action("link") }.keyboardShortcut("k").disabled(store?.isPlainText == true)
        }
        CommandMenu("视图") {
            Button("下一个标签页") { workspace?.selectAdjacent(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("上一个标签页") { workspace?.selectAdjacent(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("阅读 / 编辑") { if let store { store.changeMode(store.mode == "reading" ? "visual" : "reading") } }.keyboardShortcut("e")
            Button("源码") { store?.changeMode("source") }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("显示 / 隐藏侧栏") { store?.sidebar.toggle() }.keyboardShortcut("\\")
            Button("文件目录") { store?.sidebar = true; store?.sidebarTab = "files" }
            Button("章节大纲") { store?.sidebar = true; store?.sidebarTab = "outline" }
            Divider()
            Toggle("自动换行（TXT / 源码）", isOn: $wordWrap)
        }
    }
}
