// Sources/AlarmCore/Vision/GrayscaleFrame.swift
import Foundation
import CoreGraphics

/// One 8-bit grayscale frame. Downscaled before it reaches here: registration
/// at 320x240 is cheap enough to run at 5 fps without a measurable battery cost.
///
/// Explicitly `nonisolated`: frames are built on the camera's capture queue,
/// not the main actor. The package is main-actor isolated by default, which
/// would otherwise make this initialiser unreachable from the capture callback.
nonisolated public struct GrayscaleFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A vertical slice, used to check that both halves of the frame agree on
    /// the shift.
    public func cropped(x: Int, width sliceWidth: Int) -> GrayscaleFrame? {
        guard x >= 0, sliceWidth > 0, x + sliceWidth <= width else { return nil }
        var slice = [UInt8](); slice.reserveCapacity(sliceWidth * height)
        for row in 0..<height {
            let start = row * width + x
            slice.append(contentsOf: pixels[start..<(start + sliceWidth)])
        }
        return GrayscaleFrame(width: sliceWidth, height: height, pixels: slice)
    }

    public var cgImage: CGImage? {
        guard pixels.count == width * height else { return nil }
        var data = pixels
        return data.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }
}
