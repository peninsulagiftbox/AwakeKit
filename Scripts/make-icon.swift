// Generates Resources/AppIcon.icns: a Big Sur–style squircle with an azure
// gradient and a white crescent moon. Run: swift Scripts/make-icon.swift
// Requires macOS with AppKit; output is committed so this only reruns when
// the design changes.

import AppKit

let canvas: CGFloat = 1024
let box = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 824 * 0.2237  // Big Sur squircle proportion

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let result = NSImage(size: image.size)
    result.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: image.size))
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    result.unlockFocus()
    return result
}

let master = NSImage(size: NSSize(width: canvas, height: canvas))
master.lockFocus()

let squircle = NSBezierPath(roundedRect: box, xRadius: cornerRadius, yRadius: cornerRadius)
// Azure, lit from the top.
NSGradient(
    starting: NSColor(srgbRed: 0.36, green: 0.66, blue: 1.00, alpha: 1),
    ending: NSColor(srgbRed: 0.05, green: 0.38, blue: 0.90, alpha: 1)
)?.draw(in: squircle, angle: -90)

// Hairline highlight along the top edge, like the system icon template.
if let highlight = NSGradient(
    starting: NSColor(white: 1, alpha: 0.25),
    ending: NSColor(white: 1, alpha: 0)
) {
    NSGraphicsContext.current?.saveGraphicsState()
    let band = box.insetBy(dx: 3, dy: 3)
    NSBezierPath(roundedRect: band, xRadius: cornerRadius - 2, yRadius: cornerRadius - 2).addClip()
    highlight.draw(in: NSRect(x: box.minX, y: box.maxY - box.height * 0.08, width: box.width, height: box.height * 0.08), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
}

let symbol = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "AwakeKit")!
    .withSymbolConfiguration(.init(pointSize: 500, weight: .medium))!
let whiteMoon = tinted(symbol, .white)
let moonSize = whiteMoon.size
whiteMoon.draw(
    in: NSRect(
        x: (canvas - moonSize.width) / 2,
        y: (canvas - moonSize.height) / 2,
        width: moonSize.width,
        height: moonSize.height
    )
)
master.unlockFocus()

func export(pixel: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixel, height: pixel)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: pixel, height: pixel))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AwakeKit.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (pixel, name) in sizes {
    try export(pixel: pixel, to: iconset.appendingPathComponent(name))
}

let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Scripts/
    .deletingLastPathComponent()   // project root
let output = projectRoot.appendingPathComponent("Resources/AppIcon.icns")
try? fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try? fm.removeItem(at: output)

let util = Process()
util.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
util.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try util.run()
util.waitUntilExit()
guard util.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(output.path)")
