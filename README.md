# MarkDownEditor

直接编辑本地 Markdown 与 TXT 文件的 macOS 应用。SwiftUI / AppKit 提供窗口、文件操作与菜单；WKWebView 内置 Milkdown、CodeMirror 6、Mermaid 和 KaTeX，核心功能离线运行。

## 下载应用

在 [GitHub Releases](https://github.com/Fangke1988/MacMarkDownForFree/releases) 下载 `MarkDownEditor-1.0.0-macOS-arm64.zip`，解压后将 `MarkDownEditor.app` 拖入“应用程序”。当前发布包适用于 Apple Silicon（M 系列芯片）；最低系统版本 macOS 13。应用为本地临时签名，尚未公证。

## 直接运行

双击 `delivery/MarkDownEditor.app`。本次产物为 Apple Silicon 原生应用，最低部署目标 macOS 13；实际验证环境为 macOS 26.6.2。可以把应用复制到“应用程序”文件夹。

随附 `delivery/欢迎使用.md` 与通过本应用 PDF 导出模块生成的 `delivery/使用说明.pdf`。打开 Markdown 示例即可试用排版、表格、代码、公式和图表。

本地构建使用临时签名，尚未使用 Developer ID 签名、公证或提交 App Store。Intel Mac 可以在对应机器上从源码构建，当前交付不包含 Intel 二进制。

## 功能

- 阅读、可视化编辑、源码三种视图；双击正文开始编辑，保留源码入口。
- 多标签页与多窗口：不同文件夹的文档可在同一窗口打开；切换标签同步恢复对应文件夹、视图、光标与撤销历史。重复打开同一文件会定位到已有标签。
- 文件夹树、文件名递归搜索、章节大纲及折叠，最近文件。
- 图片选择、拖入、粘贴、替代文本修改、替换；本地图片自动写入文档旁的 `assets/`，同名不覆盖。
- 标准 Markdown 表格创建、单元格编辑、增删行列、列对齐及 Tab 导航。
- 网页、相对文件、章节链接；代码高亮与复制；Mermaid 与数学公式，编辑弹窗即时预览。
- TXT 纯文本打开、保存、另存为；TXT / Markdown 源码自动换行开关，记住设置。
- 当前文件全文查找、单次 / 全部替换、大小写选项；底部行列结果列表，可点击定位、折叠、清空；跨视图撤销与重做、任务列表。
- 浅色、深色、跟随系统；A4 多页 PDF 导出，保留文字和矢量内容。
- 约一秒自动保存、原子写入、草稿恢复、外部变更同步和冲突保护。

新建标签页 `⌘T`，关闭当前标签 `⌘W`；`⇧⌘[` / `⇧⌘]` 切换标签，`⇧⌘N` 新建窗口。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 新窗口 | ⌘N |
| 新文档 | ⇧⌘N |
| 打开文件 / 文件夹 | ⌘O / ⇧⌘O |
| 保存 / 另存为 | ⌘S / ⇧⌘S |
| 阅读与编辑 | ⌘E |
| 源码 | ⇧⌘E |
| 链接 / 查找替换 | ⌘K / ⌘F |
| 替换 / 全文结果 | ⌥⌘F / ⇧⌘F |
| 下一个 / 上一个匹配 | ⌘G / ⇧⌘G |
| 撤销 / 重做 | ⌘Z / ⇧⌘Z |
| PDF 导出 | ⌘P |
| 侧栏 | ⌘\ |

## 文件与兼容性

只打开或切换视图不会重新保存文件。可视化编辑后允许规范化 Markdown 空白及分隔符；转换前比较渲染语义，不一致时退回源码。Front Matter、原始 HTML、Wiki 链接、脚注等扩展语法保留原文并使用源码编辑，原始 HTML 在阅读中显示为文本，不执行脚本。

支持 Markdown（`.md` / `.markdown`）与纯文本（`.txt`）；打开 TXT 直接进入纯文本编辑。保存窗口下方可选择格式，Markdown 另存 TXT 会保留原文符号。自动换行位于「视图」菜单，仅改变 TXT / 源码显示，不插入换行。全文查找以当前文件原文为范围，点击结果时在文本 / 源码视图中准确选中对应位置，结果会随编辑和撤销更新。

支持 UTF-8，保存时保留原文件的 BOM 与 CRLF 风格。恢复草稿位于 `~/Library/Application Support/MarkDownEditor/Recovery/`，成功保存后清除对应草稿。未命名文档关闭时可选择保存或保留草稿；文件菜单提供恢复入口。

本地图片资源限制在当前打开文件夹范围内。要引用上级文件夹中的图片，请打开包含文档和图片的共同父文件夹。移动文档时应同时移动其 `assets/`；“另存为”不自动复制原目录附件。

首版表格不支持合并单元格。宽表格可水平滚动；PDF 使用固定 A4 版式。超出一页高度的单个表格单元格仍可能跨页，超大文档的性能上限尚未系统标定。

## 构建与测试

要求 Xcode 命令行环境、Swift 5.9+、Node.js 22+。

```sh
npm ci
npm run typecheck
npm run build
npx playwright install webkit chromium
npm test
swift test
```

产物在 `delivery/MarkDownEditor.app`。`npm run build` 会打包全部前端资源、字体和第三方许可，不需要启动本地服务器。

`swift test` 包含真实 WKWebView 文件编辑、自动保存、图片加载、外部变更、冲突和 PDF 集成测试；测试使用临时目录。Playwright 覆盖浏览器编辑内核交互。PDF 检查脚本：`swift scripts/inspect-pdf.swift delivery/使用说明.pdf`。

## 结构

- `Sources/MarkDownEditor/`：原生视图、文档状态、文件安全、WebKit 桥接和 PDF 导出。
- `web/src/`：可视化与源码编辑器、Markdown 渲染及样式。
- `Tests/`、`web/tests/`：Swift 文件层与原生集成测试、浏览器行为测试。
- `scripts/`：离线打包、许可汇总和 PDF 检查。

WebKit 消息带有文档令牌和递增版本，旧文档的迟到事件不会写入新文档。磁盘保存前比较读取基线；出现冲突时停止覆盖，并支持另存本地副本或读取磁盘版本。PDF 由 WebKit 输出矢量内容，再按正文行、图片和表格行边界分为 A4 页面，避免系统打印接口的无限分页问题。
