# MarkDownEditor 1.0.0

本地 Markdown 编辑器，支持阅读、可视化编辑和源码编辑。

## 本次发布

- 修复 Finder 双击 Markdown 文件时额外出现未命名窗口的问题。
- 支持多文档标签页；切换标签时恢复文档对应文件夹、光标与编辑状态。
- 图片、表格、超链接、Mermaid、公式，深浅主题与 PDF 导出。
- 自动保存、外部修改冲突保护和恢复草稿。

## 下载安装

下载 `MarkDownEditor-1.0.0-macOS-arm64.zip`，解压后将 `MarkDownEditor.app` 拖入“应用程序”。

适用于 Apple Silicon（M 系列芯片），最低系统版本 macOS 13；已在 macOS 26.6.2 验证。当前使用本地临时签名，尚未完成 Developer ID 签名和公证。如 macOS 阻止首次打开，可在系统设置的“隐私与安全性”中确认允许此应用。

快捷键：⌘N 新建文档，⌘T 新建标签，⌘W 关闭标签，⇧⌘N 新建窗口。

12 项原生测试和 24 项编辑器测试通过。`SHA256SUMS.txt` 可用于校验下载包。
