// Renders the emvnc app icon (a monitor with a pointer) at 1024×1024.
// Usage: swift scripts/make-icon.swift <output.png>
// scripts/make-icon.sh turns it into App/Assets.xcassets and App/AppIcon.icns.

import AppKit

let size: CGFloat = 1024
let output = URL(fileURLWithPath: CommandLine.arguments[1])

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }

    // macOS icon grid: 824×824 rounded square centred in the 1024 canvas
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(tilePath)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [ NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.45, alpha: 1).cgColor,
                                          NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.70, alpha: 1).cgColor ] as CFArray,
                                locations: [ 0, 1 ])!
    context.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    context.restoreGState()

    // Monitor
    let screen = CGRect(x: 230, y: 380, width: 564, height: 380)
    context.addPath(CGPath(roundedRect: screen, cornerWidth: 34, cornerHeight: 34, transform: nil))
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()

    let glass = screen.insetBy(dx: 26, dy: 26)
    context.addPath(CGPath(roundedRect: glass, cornerWidth: 14, cornerHeight: 14, transform: nil))
    let glassGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [ NSColor(calibratedRed: 0.13, green: 0.30, blue: 0.62, alpha: 1).cgColor,
                                             NSColor(calibratedRed: 0.20, green: 0.68, blue: 0.85, alpha: 1).cgColor ] as CFArray,
                                   locations: [ 0, 1 ])!
    context.saveGState()
    context.clip()
    context.drawLinearGradient(glassGradient, start: CGPoint(x: glass.minX, y: glass.maxY), end: CGPoint(x: glass.maxX, y: glass.minY), options: [])
    context.restoreGState()

    // Stand
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 472, y: 300, width: 80, height: 84))
    context.addPath(CGPath(roundedRect: CGRect(x: 372, y: 268, width: 280, height: 42), cornerWidth: 21, cornerHeight: 21, transform: nil))
    context.fillPath()

    // Pointer, slightly overlapping the screen edge: "remote control"
    let pointer = CGMutablePath()
    pointer.move(to: CGPoint(x: 600, y: 600))
    pointer.addLine(to: CGPoint(x: 600, y: 380))
    pointer.addLine(to: CGPoint(x: 654, y: 432))
    pointer.addLine(to: CGPoint(x: 690, y: 352))
    pointer.addLine(to: CGPoint(x: 726, y: 368))
    pointer.addLine(to: CGPoint(x: 690, y: 446))
    pointer.addLine(to: CGPoint(x: 764, y: 446))
    pointer.closeSubpath()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    context.addPath(pointer)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.restoreGState()

    context.addPath(pointer)
    context.setStrokeColor(NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.36, alpha: 1).cgColor)
    context.setLineWidth(14)
    context.setLineJoin(.round)
    context.strokePath()

    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render the icon")
}

try png.write(to: output)
