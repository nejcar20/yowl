import Foundation
import AppKit

// Draws the app icon at every size macOS asks for. Generated rather than
// bundled so it lives in the repo as code, and so the shape can be adjusted
// without a design tool.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    let s = size

    // Rounded-square ground, dark so the mark reads at 16pt.
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = s * 0.22
    let ground = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner,
                        transform: nil)
    ctx.saveGState()
    ctx.addPath(ground)
    ctx.clip()
    let colors = [NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.20, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1).cgColor]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s),
                               end: CGPoint(x: 0, y: 0), options: [])
    }
    ctx.restoreGState()

    // A shield: the alarm guards the machine.
    let w = s * 0.46, h = s * 0.54
    let cx = s / 2, top = s * 0.76, bottom = top - h
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: cx, y: top))
    shield.addLine(to: CGPoint(x: cx + w / 2, y: top - h * 0.24))
    shield.addCurve(to: CGPoint(x: cx, y: bottom),
                    control1: CGPoint(x: cx + w / 2, y: bottom + h * 0.34),
                    control2: CGPoint(x: cx + w * 0.30, y: bottom + h * 0.08))
    shield.addCurve(to: CGPoint(x: cx - w / 2, y: top - h * 0.24),
                    control1: CGPoint(x: cx - w * 0.30, y: bottom + h * 0.08),
                    control2: CGPoint(x: cx - w / 2, y: bottom + h * 0.34))
    shield.closeSubpath()
    ctx.addPath(shield)
    ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.16, alpha: 1).cgColor)
    ctx.fillPath()

    // Sound waves, so it reads as an alarm rather than generic security.
    ctx.setStrokeColor(NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).cgColor)
    ctx.setLineWidth(max(1, s * 0.035))
    ctx.setLineCap(.round)
    for i in 0..<3 {
        let r = s * (0.055 + Double(i) * 0.052)
        ctx.addArc(center: CGPoint(x: cx, y: s * 0.50), radius: r,
                   startAngle: -.pi / 3.2, endAngle: .pi / 3.2, clockwise: false)
        ctx.strokePath()
    }
    ctx.fillEllipse(in: CGRect(x: cx - s * 0.035, y: s * 0.50 - s * 0.035,
                               width: s * 0.07, height: s * 0.07))
    image.unlockFocus()
    return image
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for (size, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                     (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                     (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let image = drawIcon(size: CGFloat(size))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outputDir)/icon_\(name).png"))
}
print("wrote \(outputDir)")
