import AppKit
import CoreText

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// A real bold italic serif outline keeps the letter crisp at every icon size.
let font = CTFontCreateWithName("TimesNewRomanPS-BoldItalicMT" as CFString, 720, nil)
var character: UniChar = 77
var glyph: CGGlyph = 0
CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
guard let letter = CTFontCreatePathForGlyph(font, glyph, nil) else {
    fatalError("Unable to create M glyph")
}
let bounds = letter.boundingBoxOfPath
let scale = min(590 / bounds.width, 570 / bounds.height)

func render(_ pixels: Int) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setFillColor(NSColor.white.cgColor)
    context.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                           cornerWidth: 184, cornerHeight: 184, transform: nil))
    context.fillPath()
    context.translateBy(x: 512 - bounds.midX * scale, y: 512 - bounds.midY * scale)
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(NSColor.black.cgColor)
    context.addPath(letter)
    context.fillPath()
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to: output.appendingPathComponent("AppIcon.png"))
