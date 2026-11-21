// Renders the app iconset: green bold "R" on a dark rounded square.
// Uses CoreGraphics/CoreText so it runs headless (no window server needed).
// Usage: swift tools/make_icon.swift <iconset-dir>

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func renderPNG(_ px: Int) -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px)

    // Background: rounded square with a small margin (macOS Big Sur style).
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.addPath(roundedRectPath(rect, radius: rect.width * 0.22))
    ctx.setFillColor(CGColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 1.0))
    ctx.fillPath()

    // Letter "R", green, centered optically by cap height.
    let fontSize = s * 0.66
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1),
    ]
    let attributed = NSAttributedString(string: "R", attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)

    let capHeight = CTFontGetCapHeight(font)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let tx = (s - lineWidth) / 2
    let ty = (s - capHeight) / 2

    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.translateBy(x: tx, y: ty)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// iconutil naming scheme.
let spec: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make_icon.swift <iconset-dir>\n".data(using: .utf8)!)
    exit(2)
}
let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in spec {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    try renderPNG(px).write(to: url)
    print("wrote \(name) (\(px)px)")
}
