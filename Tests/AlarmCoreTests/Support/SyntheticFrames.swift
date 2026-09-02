// Tests/AlarmCoreTests/Support/SyntheticFrames.swift
import Foundation
import CoreGraphics
@testable import AlarmCore

/// Deterministic, non-periodic test scenes. Periodic patterns (a repeating
/// grid) make translational registration ambiguous and would make these tests
/// meaningless.
enum SyntheticFrames {
    struct Blob { let x: CGFloat, y: CGFloat, size: CGFloat, gray: CGFloat }

    static let width = 320
    static let height = 240

    static func blobs(seed: UInt64 = 42, count: Int = 120) -> [Blob] {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 10_000) / 10_000
        }
        return (0..<count).map { _ in
            Blob(x: CGFloat(next() * 320), y: CGFloat(next() * 240),
                 size: CGFloat(6 + next() * 22), gray: CGFloat(0.2 + next() * 0.7))
        }
    }

    /// `dx`/`dy` move the whole scene (the camera moved).
    /// `occluderAt` moves a foreground bar only (a person walked past).
    /// `brightness` shifts every pixel (the lighting changed).
    static func scene(dx: CGFloat = 0, dy: CGFloat = 0,
                      occluderAt: CGFloat? = nil, brightness: CGFloat = 0,
                      blobs: [Blob] = SyntheticFrames.blobs()) -> GrayscaleFrame {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: max(0, min(1, 0.2 + brightness)), alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for blob in blobs {
                ctx.setFillColor(gray: max(0, min(1, blob.gray + brightness)), alpha: 1)
                ctx.fill(CGRect(x: blob.x + dx, y: blob.y + dy, width: blob.size, height: blob.size))
            }
            if let ox = occluderAt {
                ctx.setFillColor(gray: 0.5, alpha: 1)
                ctx.fill(CGRect(x: ox, y: 0, width: 70, height: CGFloat(height)))
            }
        }
        return GrayscaleFrame(width: width, height: height, pixels: pixels)
    }
}
