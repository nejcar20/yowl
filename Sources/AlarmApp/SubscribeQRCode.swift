import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// The pairing problem this solves: the topic is 32 hex characters, and the
/// clipboard does not cross to a phone unless Universal Clipboard is set up.
/// Pointing a camera at the screen needs neither.
///
/// CoreImage generates this, so there is no dependency to audit -- which matters
/// for a secret that grants access to photographs of the user's home.
public enum SubscribeQRCode {
    /// `nil` for an empty string. A code that scans to nothing is worse than no
    /// code at all: it makes pairing look available when there is no topic yet.
    public static func image(for string: String, scale: CGFloat = 6) -> NSImage? {
        guard !string.isEmpty, let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        // Medium correction: the code is displayed on a clean screen rather than
        // printed, so the extra redundancy would only shrink the modules.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // The generator emits roughly one pixel per module, which renders as a
        // blur at any useful size. Scaling before rasterising keeps the edges
        // sharp enough for a phone camera to lock on.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        // The generator leaves about one module of margin. The spec asks for
        // four, and scanners really do refuse codes that run to the edge, so the
        // rest is added here -- on opaque white, so the code does not have to
        // rely on whatever is behind it in light or dark mode.
        let quietZone = (4 * scale).rounded()
        let side = scaled.extent.width + quietZone * 2
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width,
                                               height: scaled.extent.height))
            .draw(in: NSRect(x: quietZone, y: quietZone,
                             width: scaled.extent.width, height: scaled.extent.height))
        canvas.unlockFocus()
        return canvas
    }
}
