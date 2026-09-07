// Renders the MDNotes app icon into an .iconset directory. Driven by scripts/make-icon.sh,
// which packs the result into Resources/AppIcon.icns with iconutil.
//
// The artwork is deliberately simple so it reads at 16 px: a macOS squircle on Apple's
// 1024-point icon grid (the shape fills 824 points, corners at 22.37%) with a bold "M" and a
// down arrow, the markdown mark, in white on a blue gradient.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.iconset>\n".utf8))
    exit(64)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let canvas: CGFloat = 1024

func drawIcon(in context: CGContext) {
    let side: CGFloat = 824
    let inset = (canvas - side) / 2
    let shapeRect = CGRect(x: inset, y: inset, width: side, height: side)
    let radius = side * 0.2237
    let shape = CGPath(
        roundedRect: shapeRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Background: a blue gradient, lighter at the top, clipped to the squircle.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let stops: [CGColor] = [
        CGColor(colorSpace: space, components: [0.36, 0.58, 0.98, 1]) ?? .white,
        CGColor(colorSpace: space, components: [0.11, 0.25, 0.68, 1]) ?? .black,
    ]
    if let gradient = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: canvas / 2, y: shapeRect.maxY),
            end: CGPoint(x: canvas / 2, y: shapeRect.minY),
            options: [])
    }
    context.restoreGState()

    // Glyphs: "M" and a down arrow, laid out as one centred group.
    let font = NSFont.systemFont(ofSize: 520, weight: .heavy)
    let letter = NSAttributedString(
        string: "M", attributes: [.font: font, .foregroundColor: NSColor.white])
    let letterWidth = ceil(letter.size().width)
    let capHeight = font.capHeight

    let stemWidth: CGFloat = 72
    let headWidth: CGFloat = 200
    let headHeight: CGFloat = capHeight * 0.42
    let gap: CGFloat = 56
    let groupWidth = letterWidth + gap + headWidth
    let left = (canvas - groupWidth) / 2
    let baseline = (canvas - capHeight) / 2

    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    // draw(at:) places the line box's origin, whose baseline sits at -descender above it.
    letter.draw(at: CGPoint(x: left, y: baseline + font.descender))
    NSGraphicsContext.restoreGraphicsState()

    let arrowLeft = left + letterWidth + gap
    let arrowCenter = arrowLeft + headWidth / 2
    // One outline polygon, so the stem and head never overlap and the fill has no hole.
    let arrow = CGMutablePath()
    let top = baseline + capHeight
    let shoulder = baseline + headHeight
    arrow.move(to: CGPoint(x: arrowCenter - stemWidth / 2, y: top))
    arrow.addLine(to: CGPoint(x: arrowCenter - stemWidth / 2, y: shoulder))
    arrow.addLine(to: CGPoint(x: arrowLeft, y: shoulder))
    arrow.addLine(to: CGPoint(x: arrowCenter, y: baseline))
    arrow.addLine(to: CGPoint(x: arrowLeft + headWidth, y: shoulder))
    arrow.addLine(to: CGPoint(x: arrowCenter + stemWidth / 2, y: shoulder))
    arrow.addLine(to: CGPoint(x: arrowCenter + stemWidth / 2, y: top))
    arrow.closeSubpath()
    context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1]) ?? .white)
    context.addPath(arrow)
    context.fillPath()
}

func render(pixels: Int) throws -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw IconError.context }
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    let scale = CGFloat(pixels) / canvas
    context.scaleBy(x: scale, y: scale)
    drawIcon(in: context)
    guard let image = context.makeImage() else { throw IconError.image }
    return image
}

enum IconError: Error { case context, image, destination, write }

func writePNG(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError.destination }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.write }
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        let name = "icon_\(points)x\(points)\(suffix).png"
        let image = try render(pixels: points * scale)
        try writePNG(image, to: outputDirectory.appendingPathComponent(name))
    }
}
