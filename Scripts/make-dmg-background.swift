import Foundation
import AppKit

// Draws the disk image background: the dark ground the two icons sit on, and
// the arrow that says what to do with them. Generated rather than bundled, for
// the same reason as the app icon — it lives in the repo as code.
//
// The geometry here and the icon positions in release.sh describe the same
// window. Change one and the arrow points at nothing.
let W: CGFloat = 620, H: CGFloat = 420
// Finder measures icon positions from the top-left of the window; AppKit draws
// from the bottom-left. ICON_TOP is the number release.sh hands Finder, and
// iconY is that same line in drawing coordinates. Getting this backwards points
// the arrow at empty space.
let appX: CGFloat = 165, dropX: CGFloat = 455
let ICON_TOP: CGFloat = 248
let iconY: CGFloat = H - ICON_TOP

let slate = NSColor(calibratedRed: 0.055, green: 0.078, blue: 0.102, alpha: 1)
let panel = NSColor(calibratedRed: 0.086, green: 0.122, blue: 0.157, alpha: 1)
let amber = NSColor(calibratedRed: 1.0, green: 0.722, blue: 0.165, alpha: 1)
let muted = NSColor(calibratedRed: 0.514, green: 0.580, blue: 0.635, alpha: 1)

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let px = { (v: CGFloat) in Int(v * scale) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: px(W), pixelsHigh: px(H),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Ground, lifted very slightly toward the top so the window has a horizon.
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [panel.cgColor, slate.cgColor] as CFArray,
                          locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0),
                               options: [])
    }

    // A soft amber wash behind the app icon: the thing you are dragging is the
    // thing that should catch the eye first.
    if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [amber.withAlphaComponent(0.14).cgColor,
                                      amber.withAlphaComponent(0).cgColor] as CFArray,
                             locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: appX, y: iconY), startRadius: 0,
                               endCenter: CGPoint(x: appX, y: iconY), endRadius: 150,
                               options: [])
    }

    // The arrow. Dashed, because it is an instruction rather than a border, and
    // it stops short of both icons so it never looks like it is touching them.
    let y = iconY
    let from = appX + 78, to = dropX - 78
    ctx.setStrokeColor(amber.withAlphaComponent(0.75).cgColor)
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [9, 9])
    ctx.move(to: CGPoint(x: from, y: y))
    ctx.addLine(to: CGPoint(x: to - 14, y: y))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    let head = CGMutablePath()
    head.move(to: CGPoint(x: to + 4, y: y))
    head.addLine(to: CGPoint(x: to - 18, y: y + 11))
    head.addLine(to: CGPoint(x: to - 18, y: y - 11))
    head.closeSubpath()
    ctx.addPath(head)
    ctx.setFillColor(amber.cgColor)
    ctx.fillPath()

    func write(_ text: String, size: CGFloat, weight: NSFont.Weight,
               color: NSColor, centerX: CGFloat, y: CGFloat, tracking: CGFloat = 0) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .kern: tracking,
            .paragraphStyle: style
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let w = s.size().width + 40
        s.draw(in: NSRect(x: centerX - w / 2, y: y, width: w, height: size * 1.6))
    }

    // Above the icons, where a reader looks before they look at the icons.
    write("Drag Yowl into Applications", size: 17, weight: .semibold,
          color: NSColor(calibratedWhite: 0.91, alpha: 1), centerX: W / 2, y: H - 108)
    write("Free · Open source · MIT", size: 12, weight: .regular,
          color: muted, centerX: W / 2, y: H - 134, tracking: 1.2)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// 2x pixels, 1x logical size: Finder lays it out at 620x420 and it stays sharp.
let rep = draw(scale: 2)
let url = URL(fileURLWithPath: out).appendingPathComponent("bg.png")
try! rep.representation(using: .png, properties: [:])!.write(to: url)
print("wrote \(url.path)")
