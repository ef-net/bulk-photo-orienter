// Renders a 1024×1024 master app icon PNG using only AppKit — no design tools.
// A gradient "squircle" background with the app's photo glyph in white.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// Transparent canvas.
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

// Rounded-rectangle (squircle-ish) following Big Sur icon proportions.
let margin: CGFloat = 100
let rect = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let radius = rect.width * 0.2237
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// Background gradient: sky blue → indigo.
let top = NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.00, alpha: 1.0)
let bottom = NSColor(calibratedRed: 0.43, green: 0.36, blue: 0.98, alpha: 1.0)
ctx.saveGState()
squircle.addClip()
let gradient = NSGradient(starting: top, ending: bottom)!
gradient.draw(in: rect, angle: -90)

// Soft top highlight for depth.
let highlight = NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0.0)])!
highlight.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
ctx.restoreGState()

// Subtle inner border for crispness.
NSColor(white: 1, alpha: 0.18).setStroke()
squircle.lineWidth = 2
squircle.stroke()

// Foreground glyph: the same symbol used in the app header, in white.
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let base = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil),
   let glyph = base.withSymbolConfiguration(cfg) {
    let gs = glyph.size
    let origin = NSPoint(x: (size - gs.width) / 2, y: (size - gs.height) / 2 - 8)

    // Drop shadow under the glyph.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()

    glyph.draw(in: NSRect(origin: origin, size: gs), from: .zero, operation: .sourceOver, fraction: 1.0)
}

image.unlockFocus()

// Write PNG.
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_master.png"
try! png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
