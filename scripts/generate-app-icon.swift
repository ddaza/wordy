#!/usr/bin/env swift
import AppKit

// Rasterize a serif W on a purple–blue gradient using the system serif
// (New York on macOS). The font is not copied into the repository.
_ = NSApplication.shared

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let output = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

struct Slot {
    let size: Int
    let scale: Int
    var pixels: Int {
        size * scale
    }

    var filename: String {
        scale == 1 ? "icon_\(size).png" : "icon_\(size)@\(scale)x.png"
    }
}

let slots = [
    Slot(size: 16, scale: 1), Slot(size: 16, scale: 2),
    Slot(size: 32, scale: 1), Slot(size: 32, scale: 2),
    Slot(size: 128, scale: 1), Slot(size: 128, scale: 2),
    Slot(size: 256, scale: 1), Slot(size: 256, scale: 2),
    Slot(size: 512, scale: 1), Slot(size: 512, scale: 2),
]

func serifFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let descriptor = base.fontDescriptor.withDesign(.serif),
       let font = NSFont(descriptor: descriptor, size: size)
    {
        return font
    }
    for name in ["NewYork-Bold", "NewYork-Semibold", "NewYork-Medium"] {
        if let font = NSFont(name: name, size: size) {
            return font
        }
    }
    fputs("error: no system serif font available\n", stderr)
    exit(1)
}

func render(pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0,
    ) else {
        fputs("error: could not create bitmap\n", stderr)
        exit(1)
    }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fputs("error: could not create graphics context\n", stderr)
        exit(1)
    }
    context.shouldAntialias = true
    context.imageInterpolation = .high
    NSGraphicsContext.current = context

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let purple = NSColor(srgbRed: 0.43, green: 0.16, blue: 0.85, alpha: 1)
    let blue = NSColor(srgbRed: 0.14, green: 0.38, blue: 0.92, alpha: 1)
    NSGradient(starting: purple, ending: blue)!.draw(in: rect, angle: 315)
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.20),
        NSColor.white.withAlphaComponent(0),
    ])!.draw(
        fromCenter: NSPoint(x: size * 0.30, y: size * 0.74), radius: 0,
        toCenter: NSPoint(x: size * 0.30, y: size * 0.74), radius: size * 0.72,
        options: [],
    )

    let compact = pixels <= 32
    let font = serifFont(size: size * (compact ? 0.72 : 0.60), weight: compact ? .bold : .semibold)
    let text = NSAttributedString(string: "W", attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
    ])
    let textSize = text.size()
    text.draw(at: NSPoint(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2 + size * 0.015,
    ))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

var written: Set<String> = []
for slot in slots where written.insert(slot.filename).inserted {
    let png = render(pixels: slot.pixels).representation(using: .png, properties: [:])!
    try png.write(to: output.appendingPathComponent(slot.filename))
}

let images = slots.map { slot in
    """
        {
          "filename" : "\(slot.filename)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.size)x\(slot.size)"
        }
    """
}.joined(separator: ",\n")

try """
{
  "images" : [
    \(images)
  ],
  "info" : { "author" : "ddaza", "version" : 1 }
}
""".write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

print("Wrote \(slots.count) app icon slots to \(output.path)")
print("Serif: \(serifFont(size: 64, weight: .semibold).displayName ?? "unknown")")
