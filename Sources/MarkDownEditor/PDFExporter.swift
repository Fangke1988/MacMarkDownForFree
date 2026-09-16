import AppKit
import WebKit
import PDFKit

@MainActor enum PDFExporter {
    static func make(_ web: WKWebView) async throws -> Data {
        _ = try await web.callAsyncJavaScript("await window.EditorAPI.preparePrint();return true", arguments: [:], in: nil, contentWorld: .page)
        let layout = try await web.callAsyncJavaScript("return window.EditorAPI.printLayout()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        guard let width = layout?["width"] as? Double, let height = layout?["height"] as? Double, let cuts = layout?["cuts"] as? [Double], width > 0, height > 0 else { throw CocoaError(.fileWriteUnknown) }
        let configuration = WKPDFConfiguration(); configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        let data = try await web.pdf(configuration: configuration)
        guard let source = CGPDFDocument(CGDataProvider(data: data as CFData)!), let page = source.page(at: 1) else { throw CocoaError(.fileWriteUnknown) }
        let output = NSMutableData()
        var paper = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &paper, nil) else { throw CocoaError(.fileWriteUnknown) }
        let margin = 40.0, scale = (paper.width - margin * 2) / width
        for index in 1..<cuts.count {
            let start = cuts[index - 1], end = cuts[index]
            context.beginPDFPage(nil); context.saveGState()
            context.clip(to: CGRect(x: margin, y: paper.height - margin - (end - start) * scale, width: paper.width - margin * 2, height: (end - start) * scale))
            context.translateBy(x: margin, y: paper.height - margin + start * scale - height * scale)
            context.scaleBy(x: scale, y: scale); context.drawPDFPage(page)
            context.restoreGState(); context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }
}
