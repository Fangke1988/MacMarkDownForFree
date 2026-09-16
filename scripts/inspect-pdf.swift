import Foundation
import PDFKit
import AppKit
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let pdf = PDFDocument(url: input)!
print("Pages: \(pdf.pageCount)")
for index in 0..<pdf.pageCount {
    let page = pdf.page(at: index)!
    let image = page.thumbnail(of: NSSize(width: 850, height: 1200), for: .mediaBox)
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: input.deletingLastPathComponent().appendingPathComponent("pdf-page-\(index + 1).png"))
}
